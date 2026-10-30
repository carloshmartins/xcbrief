import XCTest
@testable import XCBriefCore

final class ParserTests: XCTestCase {
    private func parse(_ fixture: String, exitCode: Int32? = nil) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "log", subdirectory: "Fixtures"))
        let parser = XcodebuildParser(options: .init(root: "/Users/dev/App"))
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .forEach { parser.consume(String($0)) }
        return parser.finish(exitCode: exitCode)
    }

    func testCompileAndLinkErrors() throws {
        let r = try parse("build_failed")
        XCTAssertEqual(r.statusLine, "BUILD FAILED")
        XCTAssertEqual(r.errors.map(\.message), [
            "cannot find 'trainerr' in scope",
            "Undefined symbol: _OBJC_CLASS_$_TCXSensor",
            "linker command failed with exit code 1 (use -v to see invocation)",
        ])
        XCTAssertEqual(r.errors.first?.location, "Sources/Workout/WorkoutView.swift:12:5")
        XCTAssertEqual(r.failedCommands.count, 2)
        XCTAssertTrue(r.tail.isEmpty, "tail is only for unexplained failures")
        XCTAssertTrue(r.hasFailures)
    }

    func testTestFailuresAndCounts() throws {
        let r = try parse("test_failed")
        XCTAssertEqual(r.statusLine, "TEST FAILED")
        XCTAssertEqual(r.testsPassed, 3)   // testZone1, testReconnect (deduped), cadence()
        XCTAssertEqual(r.testsFailed, 2)   // testZone5, resistance()
        XCTAssertEqual(r.testsSkipped, 1)  // testFTP
        XCTAssertEqual(r.warnings.count, 3) // duplicate 'power' warning collapsed

        XCTAssertEqual(r.testFailures.count, 2)
        XCTAssertEqual(r.testFailures[0].test, "WorkoutTests.PowerZoneTests.testZone5")
        XCTAssertEqual(r.testFailures[0].location, "Tests/WorkoutTests/PowerZoneTests.swift:27")
        XCTAssertEqual(r.testFailures[1].test, "resistance()")
        XCTAssertEqual(r.testFailures[1].message, "Expectation failed: (level → 3) == 4")
    }

    func testSwiftTestingIssuesAndCounts() throws {
        let r = try parse("swift_testing_failed")
        XCTAssertEqual(r.statusLine, "TEST FAILED")
        XCTAssertEqual(r.testFailures.count, 1)
        XCTAssertEqual(r.testFailures[0].test, "addition()")
        XCTAssertEqual(r.testFailures[0].location, "MathTests.swift:8")
        XCTAssertEqual(r.testFailures[0].message, "Expectation failed: (1 + 1) == 3")
        XCTAssertEqual(r.testsPassed, 1)
        XCTAssertEqual(r.testsFailed, 1)
        XCTAssertEqual(r.testsSkipped, 1)
    }

    func testFailingTestsSummaryBlockIsNotDoubleCounted() throws {
        // End-of-run "Failing tests:" / "Testing failed:" blocks repeat info already reported above.
        let parser = XcodebuildParser()
        for fixture in ["swift_testing_failed", "failing_tests_block"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "log", subdirectory: "Fixtures"))
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").forEach { parser.consume(String($0)) }
        }
        let r = parser.finish()
        XCTAssertEqual(r.testFailures.count, 1)
        XCTAssertEqual(r.testsFailed, 1)
        XCTAssertTrue(r.errors.isEmpty)
    }

    func testUnexplainedFailureFallsBackToTail() throws {
        let r = try parse("script_failed")
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertTrue(r.tail.contains("swiftlint: command not found"))
    }

    func testNonZeroExitWithoutSummaryIsFailure() {
        let parser = XcodebuildParser()
        parser.consume("xcodebuild: error: Unable to find a destination matching the provided destination specifier")
        let r = parser.finish(exitCode: 70)
        XCTAssertTrue(r.hasFailures)
        XCTAssertEqual(r.errors.count, 1)
    }

    func testTextOutputCapsLists() throws {
        let parser = XcodebuildParser()
        for i in 1...5 { parser.consume("/a/F.swift:\(i):1: error: boom \(i)") }
        let text = Renderer.render(parser.finish(), options: .init(maxItems: 2))
        XCTAssertTrue(text.hasPrefix("FAILED | errors: 5 | warnings: 0"))
        XCTAssertTrue(text.contains("... 3 more not shown"))
    }

    func testTextGroupsByFileAndSuggestsRerun() throws {
        let text = Renderer.render(try parse("test_failed"), options: .init())
        XCTAssertTrue(text.contains("rerun failed: -only-testing:WorkoutTests/PowerZoneTests/testZone5"))
        XCTAssertTrue(text.contains("warnings by message"))
        XCTAssertFalse(text.contains("Sources/Workout/WorkoutView.swift:42"), "warnings collapsed by default")

        let build = Renderer.render(try parse("build_failed"), options: .init())
        XCTAssertTrue(build.contains("Sources/Workout/WorkoutView.swift\n  12:5 error: cannot find 'trainerr' in scope"))
    }

    func testGitHubAnnotations() throws {
        let out = Renderer.render(try parse("build_failed"), options: .init(format: .github))
        XCTAssertTrue(out.contains("::error file=Sources/Workout/WorkoutView.swift,line=12,col=5::cannot find 'trainerr' in scope"))
    }

    func testGitHubAnnotationsRespectMax() {
        let parser = XcodebuildParser()
        for i in 1...5 { parser.consume("/a/F.swift:\(i):1: error: boom \(i)") }
        let out = Renderer.render(parser.finish(), options: .init(format: .github, maxItems: 2))
        XCTAssertEqual(out.split(separator: "\n").filter { $0.hasPrefix("::error") }.count, 2)
        XCTAssertTrue(out.contains("errors: 5"), "summary keeps the real total")
    }

    func testGitHubEscapesPropertiesAndData() {
        let parser = XcodebuildParser()
        parser.consume("/a/My,Dir:1/F.swift:3:1: error: 100% broken")
        let out = Renderer.render(parser.finish(), options: .init(format: .github))
        XCTAssertTrue(out.contains("::error file=/a/My%2CDir%3A1/F.swift,line=3,col=1::100%25 broken"))
    }

    func testGitHubSummaryIncludesSkippedTests() throws {
        let out = Renderer.render(try parse("test_failed"), options: .init(format: .github))
        XCTAssertTrue(out.hasSuffix("tests: 3 passed, 2 failed, 1 skipped"))
    }

    func testRootStripsPrivateSymlinkSpelling() {
        let parser = XcodebuildParser(options: .init(root: "/var/folders/x/App"))
        parser.consume("/private/var/folders/x/App/F.swift:1:1: error: a")
        parser.consume("/var/folders/x/App/G.swift:2:1: error: b")
        let r = parser.finish()
        XCTAssertEqual(r.errors.map(\.file), ["F.swift", "G.swift"])

        let reversed = XcodebuildParser(options: .init(root: "/private/tmp/App"))
        reversed.consume("/tmp/App/H.swift:3:1: error: c")
        XCTAssertEqual(reversed.finish().errors.first?.file, "H.swift")
    }

    func testOnlyTestingArgument() {
        XCTAssertEqual(Renderer.onlyTestingArgument("Mod.FooTests.testBar"), "-only-testing:Mod/FooTests/testBar")
        XCTAssertNil(Renderer.onlyTestingArgument("resistance()"))
    }

    func testJSONOmitsEmptyFields() throws {
        let parser = XcodebuildParser()
        parser.consume("** BUILD SUCCEEDED **")
        let json = Renderer.render(parser.finish(), options: .init(format: .json))
        XCTAssertEqual(json, #"{"status":"BUILD SUCCEEDED"}"#)
    }

    func testTestNameNormalization() {
        XCTAssertEqual(XcodebuildParser.normalizeTestName("-[Mod.FooTests testBar]"), "Mod.FooTests.testBar")
        XCTAssertEqual(XcodebuildParser.normalizeTestName("FooTests.testBar()"), "FooTests.testBar")
    }
}

import XCTest
@testable import XCBriefCore

final class CLITests: XCTestCase {
    private func options(_ args: [String], root: String? = "/cwd") throws -> CLIOptions {
        guard case .run(let o) = try CLI.parse(args, defaultRoot: root) else {
            XCTFail("expected .run")
            return CLIOptions()
        }
        return o
    }

    func testDefaults() throws {
        let o = try options([])
        XCTAssertEqual(o.render.format, .text)
        XCTAssertEqual(o.render.maxItems, 30)
        XCTAssertFalse(o.render.includeWarnings)
        XCTAssertEqual(o.root, "/cwd")
        XCTAssertNil(o.teePath)
        XCTAssertTrue(o.command.isEmpty)
    }

    func testFlagsAndValues() throws {
        let o = try options(["--github", "--warnings", "--max", "5", "--tee", "/tmp/a.log", "--root", "/r"])
        XCTAssertEqual(o.render.format, .github)
        XCTAssertTrue(o.render.includeWarnings)
        XCTAssertEqual(o.render.maxItems, 5)
        XCTAssertEqual(o.teePath, "/tmp/a.log")
        XCTAssertEqual(o.root, "/r")
    }

    func testEqualsSyntax() throws {
        let o = try options(["--max=7", "--tee=/tmp/b.log", "--root=/x"])
        XCTAssertEqual(o.render.maxItems, 7)
        XCTAssertEqual(o.teePath, "/tmp/b.log")
        XCTAssertEqual(o.root, "/x")
    }

    func testCommandAfterDoubleDashIsNotParsed() throws {
        let o = try options(["--json", "--", "xcodebuild", "build", "--max=3", "-scheme", "App"])
        XCTAssertEqual(o.render.format, .json)
        XCTAssertEqual(o.command, ["xcodebuild", "build", "--max=3", "-scheme", "App"])
    }

    func testErrors() {
        XCTAssertThrowsError(try CLI.parse(["--max", "0"])) { XCTAssertEqual($0 as? CLIError, CLIError(message: "--max needs a positive number")) }
        XCTAssertThrowsError(try CLI.parse(["--max"]))
        XCTAssertThrowsError(try CLI.parse(["--tee"]))
        XCTAssertThrowsError(try CLI.parse(["--root"]))
        XCTAssertThrowsError(try CLI.parse(["--json=1"])) { XCTAssertEqual($0 as? CLIError, CLIError(message: "unknown option '--json=1'")) }
        XCTAssertThrowsError(try CLI.parse(["--bogus"]))
    }

    func testHelpAndVersion() throws {
        guard case .help = try CLI.parse(["-h"]) else { return XCTFail() }
        guard case .help = try CLI.parse(["--help"]) else { return XCTFail() }
        guard case .version = try CLI.parse(["--version"]) else { return XCTFail() }
    }
}

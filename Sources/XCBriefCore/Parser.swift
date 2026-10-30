import Foundation

/// Streaming parser: feed it xcodebuild output one line at a time, then call `finish()`.
public final class XcodebuildParser {
    public struct Options {
        /// Absolute path prefix stripped from file paths (usually the current directory).
        public var root: String?
        /// How many raw lines to keep as a fallback when a failure can't be explained.
        public var tailSize = 25

        public init(root: String? = nil, tailSize: Int = 25) {
            self.root = root
            self.tailSize = tailSize
        }
    }

    private let options: Options
    private let rootPrefixes: [String]
    private var report = Report()

    // De-duplication: xcodebuild repeats the same diagnostic per target/arch/retry.
    private var seenErrors = Set<String>()
    private var seenWarnings = Set<String>()
    private var seenFailures = Set<String>()
    // Last status per test wins, so retries and repeated lines don't inflate counts.
    private var testStatus: [String: String] = [:]

    private var inFailedCommands = false
    // A global error ending in ":" (e.g. package resolution) is followed by indented detail lines.
    private var continuationIndex: Int?
    private var continuationLines = 0
    private static let maxContinuationLines = 3
    private var tail: [String] = []

    public init(options: Options = Options()) {
        self.options = options
        self.rootPrefixes = Self.prefixes(for: options.root)
    }

    // MARK: - Patterns

    // /path/FooTests.swift:33: error: -[FooTests testBar] : XCTAssertEqual failed ...
    // /path/FooTests.swift:33: error: FooTests.testBar() : failed - ...
    private static let xctestFailure = Pattern(#"^(.+?):(\d+): error: (-\[\S+ \S+\]|\S+\(\)) : (.*)$"#)

    // Test Case '-[FooTests testBar]' passed (0.001 seconds).
    // Test case 'FooTests.testBar()' failed on 'Clone 1 of iPhone 16' (0.003 seconds)
    private static let xctestCase = Pattern(#"^Test [Cc]ase '(.+?)' (passed|failed|skipped)"#)

    // Swift Testing (prefixed by an SF Symbol or ✔/✘ glyph):
    // ✘ Test addition() recorded an issue at MathTests.swift:8:3: Expectation failed: 1 == 2
    private static let swiftTestingIssue = Pattern(#"(?:^|\s)Test (.+?) recorded an issue at (.+?):(\d+):(\d+): (.*)$"#)
    // ✔ Test addition() passed after 0.001 seconds.
    private static let swiftTestingResult = Pattern(#"(?:^|\s)Test (.+?) (passed|failed|skipped)(?: after|\.|:|$)"#)
    // ✔ Test run with 12 tests in 3 suites passed after 0.02 seconds.  (summary, ignored)
    private static let swiftTestingRun = Pattern(#"(?:^|\s)Test run with \d+ tests?"#)

    // Restarting after unexpected exit, crash, or test timeout in PowerZoneTests/testZone5(); summary will ...
    private static let crashRestart = Pattern(#"^Restarting after unexpected exit, crash, or test timeout in (.+?);"#)

    // /path/File.swift:12:5: error: cannot find 'x' in scope
    private static let compilerDiagnostic = Pattern(#"^(.+?):(\d+):(\d+): (error|warning|fatal error): (.*)$"#)

    // error: ..., ld: warning: ..., clang: error: ..., xcodebuild: error: ...
    private static let globalDiagnostic = Pattern(#"^(?:[\w.-]+: )?(error|warning|fatal error): (.*)$"#)

    //   "_OBJC_CLASS_$_Foo", referenced from:
    private static let undefinedSymbol = Pattern(#"^\s+"(.+)", referenced from:"#)

    // ** BUILD FAILED **  /  ** TEST SUCCEEDED **
    private static let summary = Pattern(#"^\*\* ([A-Z ]+?) (SUCCEEDED|FAILED|INTERRUPTED) \*\*"#)

    // MARK: - Feeding

    public func consume(_ rawLine: String) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        remember(line)

        // "The following build commands failed:" block, terminated by "(N failures)".
        if line.hasPrefix("The following build commands failed:") {
            inFailedCommands = true
            return
        }
        if inFailedCommands {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
                inFailedCommands = false
            } else {
                report.failedCommands.append(trimmed)
            }
            return
        }

        if let index = continuationIndex {
            if line.first == " " || line.first == "\t", continuationLines < Self.maxContinuationLines {
                report.errors[index].message += " " + line.trimmingCharacters(in: .whitespaces)
                continuationLines += 1
                return
            }
            continuationIndex = nil
        }

        if let m = Self.summary.match(line) {
            report.action = m[0]
            report.result = m[1]
            return
        }

        if let m = Self.xctestFailure.match(line) {
            // Crashes and timeouts have no source location: Xcode reports "<unknown>:0".
            let located = m[0] != "<unknown>"
            let name = Self.normalizeTestName(m[2]!)
            // A crashed test never prints "failed", so count it here.
            if !located { testStatus[name] = "failed" }
            addFailure(TestFailure(
                test: name,
                file: located ? shorten(m[0]!) : nil,
                line: located ? Int(m[1]!) : nil,
                message: m[3]!
            ))
            return
        }

        if let m = Self.crashRestart.match(line) {
            let test = Self.normalizeTestName(m[0]!.replacingOccurrences(of: "/", with: "."))
            // Usually preceded by the crash error for the same test (which has the module name).
            if report.testFailures.contains(where: { $0.test == test || $0.test.hasSuffix("." + test) }) { return }
            addFailure(TestFailure(test: test, file: nil, line: nil,
                                   message: "test runner crashed or timed out and was restarted"))
            return
        }

        if let m = Self.xctestCase.match(line) {
            testStatus[Self.normalizeTestName(m[0]!)] = m[1]!
            return
        }

        if let m = Self.swiftTestingIssue.match(line) {
            addFailure(TestFailure(
                test: m[0]!,
                file: shorten(m[1]!),
                line: Int(m[2]!),
                message: m[4]!
            ))
            return
        }

        if Self.swiftTestingRun.match(line) != nil { return }

        if let m = Self.swiftTestingResult.match(line) {
            testStatus["swift-testing:" + m[0]!] = m[1]!
            return
        }

        if let m = Self.compilerDiagnostic.match(line) {
            addDiagnostic(Diagnostic(
                severity: m[3] == "warning" ? .warning : .error,
                file: shorten(m[0]!),
                line: Int(m[1]!),
                column: Int(m[2]!),
                message: m[4]!
            ))
            return
        }

        if let m = Self.globalDiagnostic.match(line) {
            let isError = m[0] != "warning"
            let before = report.errors.count
            addDiagnostic(Diagnostic(
                severity: isError ? .error : .warning,
                file: nil, line: nil, column: nil,
                message: m[1]!
            ))
            if isError, report.errors.count > before, m[1]!.hasSuffix(":") {
                continuationIndex = report.errors.count - 1
                continuationLines = 0
            }
            return
        }

        if let m = Self.undefinedSymbol.match(line) {
            addDiagnostic(Diagnostic(
                severity: .error, file: nil, line: nil, column: nil,
                message: "Undefined symbol: \(m[0]!)"
            ))
            return
        }
    }

    public func finish(exitCode: Int32? = nil) -> Report {
        var result = report
        result.exitCode = exitCode
        for status in testStatus.values {
            switch status {
            case "passed": result.testsPassed += 1
            case "failed": result.testsFailed += 1
            default: result.testsSkipped += 1
            }
        }
        // Failure with nothing to show (e.g. a script phase died): give the agent raw context.
        if result.hasFailures && result.errors.isEmpty && result.testFailures.isEmpty {
            result.tail = tail
        }
        return result
    }

    // MARK: - Helpers

    private func remember(_ line: String) {
        tail.append(line)
        if tail.count > options.tailSize { tail.removeFirst(tail.count - options.tailSize) }
    }

    private func addDiagnostic(_ d: Diagnostic) {
        let key = "\(d.location ?? ""): \(d.message)"
        switch d.severity {
        case .error:
            if seenErrors.insert(key).inserted { report.errors.append(d) }
        case .warning:
            if seenWarnings.insert(key).inserted { report.warnings.append(d) }
        }
    }

    private func addFailure(_ f: TestFailure) {
        let key = "\(f.test)|\(f.file ?? ""):\(f.line ?? 0)|\(f.message)"
        if seenFailures.insert(key).inserted { report.testFailures.append(f) }
    }

    private func shorten(_ path: String) -> String {
        for prefix in rootPrefixes where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// The root with a trailing slash, plus its /private twin: macOS temp dirs are symlinks
    /// (/var -> /private/var, /tmp -> /private/tmp) and tools report either spelling.
    private static func prefixes(for root: String?) -> [String] {
        guard let root, !root.isEmpty else { return [] }
        let base = root.hasSuffix("/") ? root : root + "/"
        if base.hasPrefix("/private/") { return [base, String(base.dropFirst("/private".count))] }
        return [base, "/private" + base]
    }

    /// "-[FooTests testBar]" -> "FooTests.testBar", "FooTests.testBar()" -> "FooTests.testBar"
    static func normalizeTestName(_ name: String) -> String {
        var n = name
        if n.hasPrefix("-[") && n.hasSuffix("]") {
            n = String(n.dropFirst(2).dropLast())
            n = n.replacingOccurrences(of: " ", with: ".")
        }
        if n.hasSuffix("()") { n = String(n.dropLast(2)) }
        return n
    }
}

/// Thin NSRegularExpression wrapper returning capture groups (nil for groups that didn't participate).
struct Pattern {
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are compile-time constants; a bad one is a programmer error.
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func match(_ s: String) -> [String?]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
    }
}

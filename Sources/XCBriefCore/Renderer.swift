import Foundation

public enum OutputFormat: String {
    /// Agent/human default: grouped by file, errors first, warnings collapsed.
    case text
    /// Compact JSON for scripts.
    case json
    /// GitHub Actions workflow commands, rendered as PR annotations in CI.
    case github
}

public struct RenderOptions {
    public var format: OutputFormat = .text
    /// List individual warnings with locations (otherwise collapsed into counts per message).
    public var includeWarnings = false
    /// Cap per list so a broken module with 500 errors doesn't flood the context window.
    public var maxItems = 30
    /// Text format only: header, errors and test failures, without the warnings summary or failed commands.
    public var quiet = false

    public init(format: OutputFormat = .text, includeWarnings: Bool = false, maxItems: Int = 30, quiet: Bool = false) {
        self.format = format
        self.includeWarnings = includeWarnings
        self.maxItems = maxItems
        self.quiet = quiet
    }
}

public enum Renderer {
    public static func render(_ report: Report, options: RenderOptions) -> String {
        switch options.format {
        case .text: return text(report, options: options)
        case .json: return json(report, options: options)
        case .github: return github(report, options: options)
        }
    }

    // MARK: - Text

    private static func text(_ r: Report, options: RenderOptions) -> String {
        var out: [String] = []

        var header = [r.statusLine, "errors: \(r.errors.count)", "warnings: \(r.warnings.count)"]
        if let t = testsSummary(r) { header.append(t) }
        if let code = r.exitCode { header.append("exit: \(code)") }
        out.append(header.joined(separator: " | "))

        // Errors (and warnings when asked), grouped by file so each path is printed once.
        var diagnostics = r.errors
        if options.includeWarnings { diagnostics += r.warnings }
        let shown = Array(diagnostics.prefix(options.maxItems))
        out += grouped(shown)
        if diagnostics.count > shown.count {
            out.append("... \(diagnostics.count - shown.count) more not shown (fix these first, or rerun with --max \(diagnostics.count))")
        }

        if !r.testFailures.isEmpty {
            out.append("test failures:")
            for f in r.testFailures.prefix(options.maxItems) {
                let loc = f.location.map { " (\($0))" } ?? ""
                out.append("  \(f.test)\(loc): \(f.message)")
            }
            if r.testFailures.count > options.maxItems {
                out.append("  ... \(r.testFailures.count - options.maxItems) more")
            }
            let rerun = r.testFailures.compactMap { onlyTestingArgument($0.test) }
            if !rerun.isEmpty {
                out.append("rerun failed: " + Array(Set(rerun)).sorted().joined(separator: " "))
            }
        }

        // Warnings collapsed by message: enough to triage, a fraction of the tokens.
        if !options.quiet && !options.includeWarnings && !r.warnings.isEmpty {
            out += collapsedWarnings(r.warnings)
        }

        if !options.quiet && !r.failedCommands.isEmpty {
            out.append("failed commands:")
            out += r.failedCommands.map { "  " + $0 }
        }
        if !r.tail.isEmpty {
            out.append("last output lines:")
            out += r.tail.map { "  " + $0 }
        }
        return out.joined(separator: "\n")
    }

    /// "tests: 3 passed, 2 failed, 1 skipped", or nil when no tests ran.
    private static func testsSummary(_ r: Report) -> String? {
        guard r.testsPassed + r.testsFailed + r.testsSkipped > 0 else { return nil }
        var t = "tests: \(r.testsPassed) passed, \(r.testsFailed) failed"
        if r.testsSkipped > 0 { t += ", \(r.testsSkipped) skipped" }
        return t
    }

    /// Groups diagnostics under their file (in order of first appearance), sorted by line.
    /// Mirrors `rg --heading`-style output, which models read reliably.
    private static func grouped(_ diagnostics: [Diagnostic]) -> [String] {
        var order: [String] = []
        var byFile: [String: [Diagnostic]] = [:]
        var unlocated: [Diagnostic] = []
        for d in diagnostics {
            guard let file = d.file else { unlocated.append(d); continue }
            if byFile[file] == nil { order.append(file) }
            byFile[file, default: []].append(d)
        }

        var out: [String] = []
        for file in order {
            out.append(file)
            let sorted = byFile[file]!.sorted { ($0.line ?? 0, $0.column ?? 0) < ($1.line ?? 0, $1.column ?? 0) }
            for d in sorted {
                var pos = d.line.map(String.init) ?? "?"
                if let c = d.column { pos += ":\(c)" }
                out.append("  \(pos) \(d.severity.rawValue): \(d.message)")
            }
        }
        for d in unlocated {
            out.append("\(d.severity.rawValue): \(d.message)")
        }
        return out
    }

    private static func collapsedWarnings(_ warnings: [Diagnostic], top: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for w in warnings {
            if counts[w.message] == nil { order.append(w.message) }
            counts[w.message, default: 0] += 1
        }
        let ranked = order.sorted { counts[$0]! > counts[$1]! }
        var out = ["warnings by message (--warnings for locations):"]
        out += ranked.prefix(top).map { "  \(counts[$0]!)x \($0)" }
        if ranked.count > top { out.append("  ... \(ranked.count - top) other messages") }
        return out
    }

    /// "WorkoutTests.PowerZoneTests.testZone5" -> "-only-testing:WorkoutTests/PowerZoneTests/testZone5".
    /// Only for fully-qualified XCTest names; Swift Testing output doesn't include the target.
    static func onlyTestingArgument(_ test: String) -> String? {
        let parts = test.split(separator: ".")
        guard parts.count == 3, !test.contains("(") else { return nil }
        return "-only-testing:" + parts.joined(separator: "/")
    }

    // MARK: - JSON

    private static func json(_ report: Report, options: RenderOptions) -> String {
        var r = report
        r.errors = Array(r.errors.prefix(options.maxItems))
        r.testFailures = Array(r.testFailures.prefix(options.maxItems))
        r.warnings = options.includeWarnings ? Array(r.warnings.prefix(options.maxItems)) : []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(r) else { return #"{"status":"encoding error"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - GitHub Actions

    private static func github(_ r: Report, options: RenderOptions) -> String {
        // Workflow command escaping: data and property values differ (properties also escape ':' and ',').
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "\r", with: "%0D")
                .replacingOccurrences(of: "\n", with: "%0A")
        }
        func escapeProperty(_ s: String) -> String {
            escape(s)
                .replacingOccurrences(of: ":", with: "%3A")
                .replacingOccurrences(of: ",", with: "%2C")
        }
        func command(_ kind: String, file: String?, line: Int?, col: Int?, title: String? = nil, _ message: String) -> String {
            var props: [String] = []
            if let file { props.append("file=\(escapeProperty(file))") }
            if let line { props.append("line=\(line)") }
            if let col { props.append("col=\(col)") }
            if let title { props.append("title=\(escapeProperty(title))") }
            let p = props.isEmpty ? "" : " " + props.joined(separator: ",")
            return "::\(kind)\(p)::\(escape(message))"
        }
        var out: [String] = []
        out += r.errors.prefix(options.maxItems).map { command("error", file: $0.file, line: $0.line, col: $0.column, $0.message) }
        out += r.testFailures.prefix(options.maxItems).map { command("error", file: $0.file, line: $0.line, col: nil, title: $0.test, $0.message) }
        out += r.warnings.prefix(options.maxItems).map { command("warning", file: $0.file, line: $0.line, col: $0.column, $0.message) }
        out.append(([r.statusLine, "errors: \(r.errors.count)", "warnings: \(r.warnings.count)"]
                    + [testsSummary(r)].compactMap { $0 }).joined(separator: " | "))
        return out.joined(separator: "\n")
    }
}

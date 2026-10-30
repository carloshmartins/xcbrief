import Foundation

public struct Diagnostic: Hashable, Encodable {
    public enum Severity: String, Encodable { case error, warning }

    public var severity: Severity
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var message: String
    /// Compiler `note:` lines that followed an error ("message (file:line)"), shown with --notes.
    public var notes: [String] = []

    /// "path:line:col" or nil when the diagnostic has no location (linker, xcodebuild).
    public var location: String? {
        guard let file else { return nil }
        var s = file
        if let line { s += ":\(line)" }
        if let column { s += ":\(column)" }
        return s
    }

    // Severity is implied by which array it's in; location is collapsed to one string.
    enum CodingKeys: String, CodingKey { case location, message, notes }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(message, forKey: .message)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
    }
}

public struct TestFailure: Hashable, Encodable {
    public var test: String
    public var file: String?
    public var line: Int?
    public var message: String

    public var location: String? {
        guard let file else { return nil }
        return line.map { "\(file):\($0)" } ?? file
    }

    enum CodingKeys: String, CodingKey { case test, location, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(test, forKey: .test)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(message, forKey: .message)
    }
}

public struct Report: Encodable {
    /// Bumped when the JSON shape changes in a way scripts could notice.
    public static let jsonSchemaVersion = 1

    /// e.g. "BUILD", "TEST", "ARCHIVE" — taken from the `** X SUCCEEDED **` line.
    public var action: String?
    /// "SUCCEEDED", "FAILED", "INTERRUPTED" or nil if xcodebuild never printed a summary line.
    public var result: String?
    public var errors: [Diagnostic] = []
    public var warnings: [Diagnostic] = []
    public var testFailures: [TestFailure] = []
    public var testsPassed = 0
    public var testsFailed = 0
    public var testsSkipped = 0
    public var failedCommands: [String] = []
    /// Last raw lines, only filled when the build failed but nothing parseable explained why.
    public var tail: [String] = []
    /// Exit code of the wrapped command (only in `xcbrief -- <command>` mode).
    public var exitCode: Int32?

    public var hasFailures: Bool {
        result == "FAILED" || result == "INTERRUPTED"
            || !errors.isEmpty || !testFailures.isEmpty
            || (exitCode.map { $0 != 0 } ?? false)
    }

    public var statusLine: String {
        if let action, let result { return "\(action) \(result)" }
        return hasFailures ? "FAILED" : "DONE"
    }

    // Compact JSON: skip empty collections and zero counts so agents read fewer tokens.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, status, errors, warnings, testFailures, tests, failedCommands, tail, exitCode
    }

    struct TestCounts: Encodable { var passed: Int; var failed: Int; var skipped: Int }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.jsonSchemaVersion, forKey: .schemaVersion)
        try c.encode(statusLine, forKey: .status)
        if !errors.isEmpty { try c.encode(errors, forKey: .errors) }
        if !warnings.isEmpty { try c.encode(warnings, forKey: .warnings) }
        if !testFailures.isEmpty { try c.encode(testFailures, forKey: .testFailures) }
        if testsPassed + testsFailed + testsSkipped > 0 {
            try c.encode(TestCounts(passed: testsPassed, failed: testsFailed, skipped: testsSkipped), forKey: .tests)
        }
        if !failedCommands.isEmpty { try c.encode(failedCommands, forKey: .failedCommands) }
        if !tail.isEmpty { try c.encode(tail, forKey: .tail) }
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
    }
}

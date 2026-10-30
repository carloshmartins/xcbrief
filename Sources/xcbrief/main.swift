import Foundation
import XCBriefCore

let usage = """
USAGE:
  xcodebuild ... 2>&1 | xcbrief [options]
  xcbrief [options] -- xcodebuild ...      (runs the command, keeps its exit code)

OPTIONS:
  --json           Print compact JSON instead of text (for scripts)
  --github         Print GitHub Actions annotations (for CI)
  --warnings       List warnings with locations (default: counts per message)
  --max <n>        Max items per list (default: 30)
  --tee <file>     Also write the full raw log to <file>
  --root <path>    Path prefix to strip from file paths (default: current directory)
  --version        Print the version
  -h, --help       Show this help

Options taking a value also accept --opt=value.

EXIT CODE:
  0 when nothing failed, 1 on errors/test failures, or the wrapped command's
  exit code when it failed without anything parseable.
"""

let version = "0.1.0"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("xcbrief: \(message)\n\n\(usage)\n".utf8))
    exit(64)
}

// MARK: - Arguments

var renderOptions = RenderOptions()
var teePath: String?
var root: String? = FileManager.default.currentDirectoryPath
var command: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    var arg = args.removeFirst()
    // Accept --opt=value (value-taking options only) by splitting it into "--opt", "value".
    if let eq = arg.firstIndex(of: "="), ["--max", "--tee", "--root"].contains(String(arg[..<eq])) {
        args.insert(String(arg[arg.index(after: eq)...]), at: 0)
        arg = String(arg[..<eq])
    }
    switch arg {
    case "--json": renderOptions.format = .json
    case "--github": renderOptions.format = .github
    case "--warnings": renderOptions.includeWarnings = true
    case "--max":
        guard let v = args.first, let n = Int(v), n > 0 else { fail("--max needs a positive number") }
        renderOptions.maxItems = n
        args.removeFirst()
    case "--tee":
        guard let v = args.first else { fail("--tee needs a file path") }
        teePath = v
        args.removeFirst()
    case "--root":
        guard let v = args.first else { fail("--root needs a path") }
        root = v
        args.removeFirst()
    case "--version":
        print("xcbrief \(version)")
        exit(0)
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--":
        command = args
        args = []
    default:
        fail("unknown option '\(arg)'")
    }
}

// MARK: - Input

let parser = XcodebuildParser(options: .init(root: root))

var tee: FileHandle?
if let teePath {
    FileManager.default.createFile(atPath: teePath, contents: nil)
    tee = FileHandle(forWritingAtPath: teePath)
    if tee == nil { fail("cannot write to \(teePath)") }
}

func handle(_ line: String) {
    tee?.write(Data((line + "\n").utf8))
    parser.consume(line)
}

var exitCode: Int32?

if command.isEmpty {
    while let line = readLine(strippingNewline: true) {
        handle(line)
    }
} else {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe  // xcodebuild splits diagnostics across both streams
    do {
        try process.run()
    } catch {
        fail("could not run \(command.joined(separator: " ")): \(error.localizedDescription)")
    }

    let reader = pipe.fileHandleForReading
    var buffer = Data()
    while true {
        let chunk = reader.availableData
        if chunk.isEmpty { break }  // EOF
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            handle(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }
    if !buffer.isEmpty { handle(String(decoding: buffer, as: UTF8.self)) }
    process.waitUntilExit()
    exitCode = process.terminationStatus
}

try? tee?.close()

// MARK: - Output

let report = parser.finish(exitCode: exitCode)
print(Renderer.render(report, options: renderOptions))

if let code = exitCode, code != 0 {
    exit(code)
}
exit(report.hasFailures ? 1 : 0)

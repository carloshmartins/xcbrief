import Foundation
import XCBriefCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("xcbrief: \(message)\n\n\(CLI.usage)\n".utf8))
    exit(64)
}

// MARK: - Arguments

let cli: CLIOptions
do {
    switch try CLI.parse(Array(CommandLine.arguments.dropFirst()), defaultRoot: FileManager.default.currentDirectoryPath) {
    case .help:
        print(CLI.usage)
        exit(0)
    case .version:
        print("xcbrief \(CLI.version)")
        exit(0)
    case .run(let options):
        cli = options
    }
} catch let error as CLIError {
    fail(error.message)
}

let renderOptions = cli.render
let teePath = cli.teePath
let command = cli.command
let root = cli.root

// MARK: - Input

let parser = XcodebuildParser(options: .init(root: root))

var tee: FileHandle?
if let teePath {
    FileManager.default.createFile(atPath: teePath, contents: nil)
    tee = FileHandle(forWritingAtPath: teePath)
    if tee == nil { fail("cannot write to \(teePath)") }
}

// Buffer tee writes: one syscall per line is wasteful on 100k-line logs.
var teeBuffer = Data()

func flushTee() {
    guard !teeBuffer.isEmpty else { return }
    tee?.write(teeBuffer)
    teeBuffer.removeAll(keepingCapacity: true)
}

func handle(_ line: String) {
    if tee != nil {
        teeBuffer.append(Data((line + "\n").utf8))
        if teeBuffer.count >= 64 * 1024 { flushTee() }
    }
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

    // Ctrl-C reaches the child through the terminal's process group, so ignore SIGINT here and keep
    // reading until the child exits (we still print the summary). SIGTERM is sent to us alone, so forward it.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "xcbrief.signals"))
    termSource.setEventHandler {
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
    }
    termSource.resume()

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
    // A signal-killed child reports the bare signal number; use the shell convention 128 + n.
    exitCode = process.terminationReason == .uncaughtSignal
        ? 128 + process.terminationStatus
        : process.terminationStatus
}

flushTee()
try? tee?.close()

// MARK: - Output

let report = parser.finish(exitCode: exitCode)
print(Renderer.render(report, options: renderOptions))

if let junitPath = cli.junitPath {
    do {
        try Renderer.junit(report).write(toFile: junitPath, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("xcbrief: cannot write \(junitPath): \(error.localizedDescription)\n".utf8))
    }
}

if let code = exitCode, code != 0 {
    exit(code)
}
exit(report.hasFailures ? 1 : 0)

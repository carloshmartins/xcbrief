import Foundation

public struct CLIOptions {
    public var render = RenderOptions()
    public var teePath: String?
    public var root: String?
    /// Command to run and wrap (everything after `--`); empty means read the log from stdin.
    public var command: [String] = []

    public init() {}
}

public enum CLIAction {
    case run(CLIOptions)
    case help
    case version
}

public struct CLIError: Error, Equatable {
    public let message: String
}

public enum CLI {
    public static let version = "0.1.0"

    public static let usage = """
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

    private static let valueOptions: Set<String> = ["--max", "--tee", "--root"]

    /// Parses command-line arguments (without the program name).
    public static func parse(_ arguments: [String], defaultRoot: String? = nil) throws -> CLIAction {
        var options = CLIOptions()
        options.root = defaultRoot
        var args = arguments

        while !args.isEmpty {
            var arg = args.removeFirst()
            // Accept --opt=value (value-taking options only) by splitting it into "--opt", "value".
            if let eq = arg.firstIndex(of: "="), valueOptions.contains(String(arg[..<eq])) {
                args.insert(String(arg[arg.index(after: eq)...]), at: 0)
                arg = String(arg[..<eq])
            }
            switch arg {
            case "--json": options.render.format = .json
            case "--github": options.render.format = .github
            case "--warnings": options.render.includeWarnings = true
            case "--max":
                guard let v = args.first, let n = Int(v), n > 0 else {
                    throw CLIError(message: "--max needs a positive number")
                }
                options.render.maxItems = n
                args.removeFirst()
            case "--tee":
                guard let v = args.first else { throw CLIError(message: "--tee needs a file path") }
                options.teePath = v
                args.removeFirst()
            case "--root":
                guard let v = args.first else { throw CLIError(message: "--root needs a path") }
                options.root = v
                args.removeFirst()
            case "--version":
                return .version
            case "-h", "--help":
                return .help
            case "--":
                options.command = args
                args = []
            default:
                throw CLIError(message: "unknown option '\(arg)'")
            }
        }
        return .run(options)
    }
}

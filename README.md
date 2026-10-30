<p align="center">
  <img src="assets/logo.svg" alt="xcbrief" width="320">
</p>

<p align="center">
  Turn thousands of lines of <code>xcodebuild</code> output into a short summary,<br>
  for people and for coding agents.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="Swift 5.9+" src="https://img.shields.io/badge/swift-5.9%2B-F05138.svg">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-lightgrey.svg">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen.svg">
</p>

---

A full build or test run prints thousands of lines. You need about ten of them: did it pass, what
broke, where. `xcbrief` reads the raw output and keeps only the status, errors, test failures and
counts.

```console
$ xcbrief -- xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'
TEST FAILED | errors: 0 | warnings: 3 | tests: 3 passed, 2 failed, 1 skipped | exit: 65
test failures:
  WorkoutTests.PowerZoneTests.testZone5 (Tests/WorkoutTests/PowerZoneTests.swift:27): XCTAssertEqual failed: ("4") is not equal to ("5")
  resistance() (ResistanceTests.swift:14): Expectation failed: (level → 3) == 4
rerun failed: -only-testing:WorkoutTests/PowerZoneTests/testZone5
warnings by message (--warnings for locations):
  1x variable 'power' was never mutated; consider changing to 'let' constant
  1x 'connect()' is deprecated: use connect(timeout:)
  1x object file (...Legacy.a(x.o)) was built for newer iOS Simulator version (17.0) than being linked (16.0)
```

When a build fails, errors are grouped under each file, so long module paths are printed once:

```console
BUILD FAILED | errors: 3 | warnings: 0
Packages/Workout/Sources/WorkoutUI/WorkoutView.swift
  12:5 error: cannot find 'trainerSession' in scope
  57:9 error: missing argument for parameter 'timeout' in call
error: Undefined symbol: _OBJC_CLASS_$_TCXSensor
```

## Install

**Download a binary** (universal, arm64 + x86_64) from the [latest release](https://github.com/carloshmartins/xcbrief/releases/latest):

```sh
tar -xzf xcbrief-*-macos-universal.tar.gz
xattr -d com.apple.quarantine xcbrief 2>/dev/null || true
install -m 755 xcbrief ~/.local/bin/xcbrief
```

**Or build from source.** Needs Xcode 15+ / Swift 5.9+. There are no third-party dependencies, so it builds offline:

```sh
git clone https://github.com/carloshmartins/xcbrief.git
cd xcbrief
make install     # release build → ~/.local/bin/xcbrief
```

`make test` runs the tests and `make universal` builds a binary you can copy to another Mac.
If `~/.local/bin` isn't on your `PATH`, add it or run `make install PREFIX=/usr/local`.
Setting it up on a new machine, or asking an AI agent to do it? Follow [SETUP.md](SETUP.md).

## Usage

```sh
# Wrap mode (preferred): merges stderr, keeps xcodebuild's exit code
xcbrief -- xcodebuild build -scheme App -destination 'generic/platform=iOS Simulator'

# Pipe mode
set -o pipefail
xcodebuild test -scheme App 2>&1 | xcbrief

# Keep the full log in case you need to dig deeper
xcbrief --tee /tmp/xcodebuild.log -- xcodebuild test -scheme App

# Read a saved log (CI artifact, fastlane buildlog)
xcbrief < xcodebuild.log
```

Run it from the repo root so paths come out relative, or pass `--root`.

### Options

| Option | Meaning |
|---|---|
| `--json` | Compact JSON, empty fields omitted (for scripts) |
| `--github` | GitHub Actions annotations (for CI) |
| `--junit <file>` | Also write JUnit XML to `<file>` (test failures and build errors; passing tests are only counted) |
| `--warnings` | List warnings with locations (default: counts per message) |
| `--notes` | Show compiler `note:` lines under each error (default: omitted, they cost tokens) |
| `-q`, `--quiet` | Text only: header, errors and test failures, no warnings summary |
| `--max <n>` | Max items per list (default 30) |
| `--tee <file>` | Also write the full raw log |
| `--root <path>` | Prefix stripped from paths (default: current directory) |
| `--version` | Print the version |

Options that take a value also accept `--opt=value`. Options go before `--`; everything after it is the command.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Nothing failed |
| `1` | Errors or test failures |
| other | The wrapped command's own exit code, when it failed without anything parseable (`128+n` if it was killed by signal `n`) |
| `64` | Bad `xcbrief` arguments |

## What it recognizes

- Compiler diagnostics: `file:line:col: error|warning|fatal error: msg`, and `note:` lines (with `--notes`)
- Global ones: `error:`, `ld: warning:`, `clang: error:`, `xcodebuild: error:`, including multi-line ones such as `Could not resolve package dependencies:` (first 3 detail lines kept)
- Undefined symbols from the linker
- XCTest failures and per-test results, including parallel `Test case '...' passed on 'Clone 1 ...'`
- Swift Testing: `Test x() recorded an issue at file:line:col: msg` and pass/fail/skip lines
- Test crashes and runner restarts, reported as failed tests with the `Fatal error:` message
- `** BUILD|TEST|ARCHIVE SUCCEEDED|FAILED **` and the "The following build commands failed:" block

Duplicates (the same diagnostic per architecture, target or retry) are collapsed. If a build fails
and none of the above explains why (a script phase crashed, say), the last 25 raw lines are included instead.

## JSON output

`--json` prints one object; empty fields are omitted. `schemaVersion` only changes when the shape
changes in a way scripts could notice (currently `1`).

```json
{"schemaVersion":1,"status":"TEST FAILED",
 "errors":[{"location":"A.swift:12:5","message":"..."}],
 "testFailures":[{"test":"Mod.Class.method","location":"T.swift:27","message":"..."}],
 "tests":{"passed":3,"failed":2,"skipped":1},
 "failedCommands":["..."],"tail":["..."],"exitCode":65}
```

`warnings` only appears with `--warnings`, and `notes` (per error) only with `--notes`.

## Using it with agents

Add this to `CLAUDE.md` (Claude Code) or `.github/copilot-instructions.md` (Copilot):

```md
## Building and testing
Always run xcodebuild through xcbrief, never raw:
  xcbrief --tee /tmp/xcodebuild.log -- xcodebuild <args>
Read the summary first. Only open /tmp/xcodebuild.log if the summary is not enough.
To re-run failed tests, append the `rerun failed:` arguments to the same test command.
```

The `rerun failed:` line works for XCTest. Swift Testing output has no target name, so no hint is printed for it.

### Why this output format

Measured on an 18-error / 42-warning build in a modular app, the default text output is about 11%
of the tokens of pretty-printed JSON. Most of the savings come from what is left out, not from the
syntax: relative paths, each path printed once, duplicates collapsed, and warnings summarized unless
asked for. Swapping JSON for a token-optimized format like TOON saved only about 8% on the same data,
because paths and messages dominate.

## Limits

- It needs raw `xcodebuild` output. Don't put `xcpretty` or `xcbeautify` in front of it.
- In pipe mode the exit code is `xcbrief`'s, not `xcodebuild`'s, unless you use `set -o pipefail`. Wrap mode avoids this.
- It parses text, so a new Xcode release can change a format. If something is missed, the `last output lines:` fallback and the `--tee` log still have it. Please open an issue with the log.

## Development

```sh
make test     # swift test
make build    # debug build
```

The parser is a streaming line matcher in `Sources/XCBriefCore/Parser.swift`; output formats are in
`Renderer.swift`. Tests run against sanitized logs in `Tests/XCBriefCoreTests/Fixtures`, including
real `xcodebuild` output (`real_*.log`). To add a case, drop in a log and assert on the `Report`.

## License

MIT, see [LICENSE](LICENSE).

# xcbrief

Turns `xcodebuild` output into a short summary for a person or a coding agent:
just the status, errors, test failures and counts, without the thousands of lines of build noise.

```
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

A failing build groups errors under each file, so long module paths are printed once:

```
BUILD FAILED | errors: 3 | warnings: 0
Packages/Workout/Sources/WorkoutUI/WorkoutView.swift
  12:5 error: cannot find 'trainerSession' in scope
  57:9 error: missing argument for parameter 'timeout' in call
error: Undefined symbol: _OBJC_CLASS_$_TCXSensor
```

## Install

```sh
make test        # run the parser tests
make install     # release build → ~/.local/bin/xcbrief
make universal   # arm64 + x86_64 binary to copy to another Mac
```

No third-party dependencies: it builds offline with the Swift toolchain alone.

**Setting up on a new machine, or asking an AI agent to do it? Follow [SETUP.md](SETUP.md).**

## Usage

```sh
# Wrap mode (preferred): merges stderr, keeps xcodebuild's exit code
xcbrief -- xcodebuild build -scheme App -destination 'generic/platform=iOS Simulator'

# Pipe mode
set -o pipefail
xcodebuild test -scheme App 2>&1 | xcbrief --json

# Keep the full log around in case you need to dig deeper
xcbrief --tee /tmp/xcodebuild.log -- xcodebuild test -scheme App
```

| Option | Meaning |
|---|---|
| `--json` | Compact JSON (empty fields omitted), for scripts |
| `--github` | GitHub Actions annotations, for CI |
| `--warnings` | List warnings with locations (default: counts per message) |
| `--max <n>` | Max items per list (default 30) |
| `--tee <file>` | Also write the full raw log |
| `--root <path>` | Prefix stripped from paths (default: current directory) |

## What it recognizes

- Compiler diagnostics: `file:line:col: error|warning|fatal error: msg`
- Global ones: `error:`, `ld: warning:`, `clang: error:`, `xcodebuild: error:`
- Undefined symbols from the linker
- XCTest: failures (`file:line: error: -[Class test] : msg`), per-test results, including parallel `Test case '...' passed on 'Clone 1 ...'`
- Swift Testing: `Test x() recorded an issue at file:line:col: msg` and pass/fail/skip lines
- `** BUILD|TEST|ARCHIVE SUCCEEDED|FAILED **`, and the "The following build commands failed:" block

Duplicates (same diagnostic per arch/target/retry) are collapsed. When a build fails and none of
the above explains why (e.g. a script phase crashed), the last 25 raw lines are included instead.

## Why this output format

Measured on an 18-error / 42-warning build in a modular app, the default text output is
about 11% of the tokens of pretty-printed JSON. Most of the savings come from what's left
out, not from the syntax: relative paths, each path printed once, duplicates collapsed, and
warnings summarized unless asked for. Swapping JSON for a token-optimized format like TOON saved
only ~8% on the same data, because paths and messages dominate.

## Using it with agents

Add to `CLAUDE.md` (Claude Code) or `.github/copilot-instructions.md` (Copilot):

```md
## Building and testing
Always run xcodebuild through xcbrief, never raw:
  xcbrief --tee /tmp/xcodebuild.log -- xcodebuild <args>
Only read /tmp/xcodebuild.log if the summary isn't enough to fix the problem.
```

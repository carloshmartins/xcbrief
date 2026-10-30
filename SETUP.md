# xcbrief setup guide (for humans and AI agents)

Follow the steps in order. Each step has a check: run it and confirm the expected result before continuing.

xcbrief has **no third-party dependencies**: it builds with only the Swift toolchain, offline.

---

## 0. Prerequisites

```bash
xcodebuild -version        # Xcode 15 or newer
swift --version            # Swift 5.9 or newer
```

---

## 1. Build and install

```bash
cd xcbrief
make test            # all ParserTests pass
make install         # release build → ~/.local/bin/xcbrief
xcbrief --help       # prints usage
```

If `~/.local/bin` is not on `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`, or install elsewhere with `make install PREFIX=/usr/local`.

To use it on another Mac without building there, run `make universal` and copy `.build/apple/Products/Release/xcbrief` to the other machine. Then:

```bash
chmod +x ~/.local/bin/xcbrief
xattr -d com.apple.quarantine ~/.local/bin/xcbrief 2>/dev/null || true
```

### Check it with the bundled fixtures (no project needed)

```bash
xcbrief < Tests/XCBriefCoreTests/Fixtures/build_failed.log
```

Expected: a first line starting with `BUILD FAILED | errors:`, the errors grouped under `…/WorkoutView.swift`, and an `Undefined symbol` line.

```bash
xcbrief < Tests/XCBriefCoreTests/Fixtures/test_failed.log    # → TEST FAILED … test failures: … rerun failed: …
xcbrief < Tests/XCBriefCoreTests/Fixtures/script_failed.log  # → last output lines: (fallback when nothing is parseable)
```

---

## 2. Use it in a project

Run from the **repo root**, so paths in the output are relative to it (or pass `--root <path>`).

### Wrap mode (preferred)

```bash
xcbrief --tee /tmp/xcodebuild.log -- xcodebuild build \
  -scheme <Scheme> -destination 'generic/platform=iOS Simulator'

xcbrief --tee /tmp/xcodebuild.log -- xcodebuild test \
  -scheme <Scheme> -destination 'platform=iOS Simulator,name=<Device>'
```

- Runs the command, merges stdout and stderr, and keeps the command's exit code.
- `--tee` keeps the full raw log for the rare case the summary isn't enough.

To find valid values:

```bash
xcodebuild -list                                   # schemes (add -workspace X.xcworkspace if there is one)
xcrun simctl list devices available | grep iPhone  # simulator names
```

### Pipe mode

```bash
set -o pipefail
xcodebuild … 2>&1 | xcbrief
```

Without `pipefail`, the pipeline's exit code is xcbrief's, not xcodebuild's. Always include `2>&1`: xcodebuild writes diagnostics to both streams.

### Re-running only the failed tests

The text output ends with a `rerun failed:` line such as `-only-testing:WorkoutTests/PowerZoneTests/testZone5`. Append it to the same `xcodebuild test …` command. This only works for XCTest; Swift Testing output doesn't include the target name.

### Existing logs (fastlane, CI artifacts)

xcbrief also reads a saved log:

```bash
xcbrief < path/to/xcodebuild.log
```

With fastlane `scan`/`gym`, set `buildlog_path` and feed the raw log (not the xcpretty/xcbeautify output) to xcbrief.

---

## 3. Options

| Option | Use |
|---|---|
| *(none)* | Text summary, the default for agents and humans |
| `--warnings` | List warnings with file and line (default: counts per message) |
| `--max <n>` | Items per list (default 30) |
| `--json` | Compact JSON for scripts |
| `--github` | GitHub Actions annotations for CI |
| `--tee <file>` | Also save the raw log |
| `--root <path>` | Prefix stripped from paths (default: current directory) |
| `--version` | Print the version |

Exit codes: `0` = success; `1` = errors or test failures; otherwise the wrapped command's own exit code when it failed with nothing parseable; `64` = bad xcbrief arguments.

---

## 4. Agent instructions

Add to `.github/copilot-instructions.md` (Copilot) or `CLAUDE.md` (Claude Code):

```md
## Building and testing
Always run xcodebuild through xcbrief, never raw:
  xcbrief --tee /tmp/xcodebuild.log -- xcodebuild <args>
Read the summary first. Only open /tmp/xcodebuild.log if the summary is not enough.
To re-run failed tests, append the `rerun failed:` arguments to the same test command.
Use --warnings only when asked to fix warnings.
```

With parallel agents, give each one its own log path, e.g. `/tmp/xcodebuild-<branch>.log`, so they don't overwrite each other.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `DONE` but the build clearly failed | Pipe mode without `set -o pipefail` and `2>&1`. Use wrap mode instead. |
| Absolute paths in output | Not run from the repo root. Pass `--root "$PWD"` or `cd` first. |
| `last output lines:` only | The failure wasn't a compiler/test/linker message (e.g. a script phase). Read those lines, or the `--tee` log. |
| Output is xcpretty/xcbeautify-styled and nothing is detected | xcbrief needs raw xcodebuild output. Don't put another formatter in front of it. |
| `xcbrief: unknown option` | Options go **before** `--`; everything after `--` is the command. |
| `could not run …` | The command isn't on `PATH` inside the wrapper. Use `xcrun xcodebuild …` or an absolute path. |

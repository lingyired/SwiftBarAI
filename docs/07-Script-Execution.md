# Script Execution

This document covers the three core pieces that turn a plugin into a live process: `runScript(...)`, the `Environment` injected into the child, and the various wrappers around Apple Shortcuts and terminals.

## `runScript(to:args:runInBash:env:)` — the workhorse

[RunScript.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Utility/RunScript.swift) is the single function that SwiftBar uses to spawn a child process.

```swift
func runScript(to executable: String,
               args: [String] = [],
               env: [String: String] = [:],
               runInBash: Bool = true,
               maxRunTime: TimeInterval? = 30,
               pipeStdErr: Bool = false) -> (out: String?, error: Error?, exitCode: Int32)
```

It returns `nil` for `out` only when the process could not be launched or exceeded `maxRunTime`; otherwise it returns the full stdout (decoded as UTF-8).

### Implementation

- A `Process` is constructed, with `executableURL = URL(fileURLWithPath:)`.
- Args are added; values that contain spaces are wrapped in single quotes (`escaped()`).
- The env is initialized from `ProcessInfo.processInfo.environment` (so the child inherits `PATH`, `HOME`, etc.) and then merged with `env` (and the plugin's own `Environment` if used).
- If `runInBash` is true, the executable is replaced with the resolved user shell (`Environment.userLoginShell`) and the real command is prepended with `-lc` (or `-c` for `csh`/`tcsh`). The `args` are then:
  - For `bash`/`zsh`/`sh`: `["-lc", "<quoted script>"]`.
  - For `csh`/`tcsh`: `["-c", "<quoted script>"]`.
  - For `fish`: `["-l", "-c", "<quoted script>"]`.
  - For other shells: `["-c", "<quoted script>"]`.
- The quoting is handled by `String.needsShellQuoting` and `String.quoteIfNeeded()` to safely handle spaces and shell metacharacters.
- A `Pipe` collects stdout (and stderr if `pipeStdErr` is true).
- A `DispatchWorkItem` enforces `maxRunTime`; if the process is still running, it is terminated and `out` is `nil`.
- On exit, both pipes are drained, the work item is cancelled, and the function returns.

### Used by

- `PluginManager.invokePlugin(_:refreshEnv:)` for all script-backed plugins.
- `AppDelegate.setDefaultShelf()` (to call `dscl`).
- `AppShared.runInBackground` (raw `bash -c` for menu clicks).
- `ShortcutsManager` (for `osascript` calls).

## `Environment` — the env-var provider

[Environment.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Utility/Environment.swift) is a singleton that every plugin run is enriched with. It exposes a dictionary of `String: String` that is merged with the inherited environment.

### Injected variables

| Variable | Value | Notes |
| --- | --- | --- |
| `SWIFTBAR_VERSION` | `appVersion` | Cached at app start. |
| `SWIFTBAR_BUILD` | `appBuild` | Cached at app start. |
| `SWIFTBAR_PLUGIN_PATH` | The plugin file path. | Re-set per-invocation. |
| `SWIFTBAR_PLUGIN_CACHE_PATH` | The plugin's data folder under `cacheDirectory`. |  |
| `SWIFTBAR_PLUGIN_DATA_PATH` | The plugin's data folder under `dataDirectory`. |  |
| `OS_LAST_SLEEP_TIME` / `OS_LAST_WAKE_TIME` | Updated on sleep/wake. | ISO-8601 strings. |
| `OS_START_TIME` | When the app started. |  |
| `HOME`, `TMPDIR`, `LANG`, `LC_ALL` | Re-exposed. |  |
| `PATH` | Inherited. |  |
| `SHELL` | The user's resolved login shell. |  |
| `DISPLAY` | Removed (macOS doesn't use X). |  |

`sharedEnv.userLoginShell` is a mutable property used by `setDefaultShelf`. `getCurrentEnv()` returns the merged dictionary.

`Environment.appendEnv(...)` allows a one-off merge (used by the `refreshEnv` URL-scheme parameter and by `SetEphemeralPlugin`).

## `ShortcutsManager` — Apple Shortcuts bridge

[ShortcutsManager.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Utility/ShortcutsManager.swift) wraps `NSAppleScript` calls into `Shortcuts.app` to run Apple Shortcuts as if they were scripts.

### Functions

- `shortcutsList()` — runs the AppleScript:

  ```applescript
  tell application "Shortcuts Events"
      set shortcutNames to name of every shortcut
      return shortcutNames
  end tell
  ```

  and returns a `[String]`. If `Shortcuts Events` is not installed, it returns an empty array (and logs an error).

- `runShortcuts(named:input:runInBackground:)` — runs the named shortcut. The AppleScript body is:

  ```applescript
  tell application "Shortcuts Events"
      run shortcut "<name>" with input "<input>"
  end tell
  ```

  When `runInBackground` is true, the function uses the "Instant Run" path: it constructs `runShortcut(_:onScriptError:)` that wraps the call in an `NSAppleScript` and returns synchronously. Output is captured from the AppleScript result.

- `defaultShortcutRunType` — a preference. One of `.instant` (default), `.silent`, `.foreground`, `.pinnedMenuBar`. The pinned mode wraps the call in an `open -a "Shortcuts" shortcut://...` invocation that doesn't surface the Shortcuts UI.

### Error handling

Errors from `NSAppleScript` (e.g. "Shortcuts is not running") are surfaced via the `error` key in the returned tuple. The plugin then marks `lastError` and sets a corresponding `content` error line.

## `PluginUtilities` — refresh interval parsing & plugin operations

[PluginUtilities.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Utility/PluginUtilities.swift) is a thin module-level file:

- `parseRefreshInterval(...)` — supports `Ns`, `Nm`, `Nh`, `Nd`, `wN` (1 minute minimum). The unit is one of `[s, m, h, d, w]`. Returns `nil` on parse failure (the plugin will use the default 10s).
- `RunPluginOperation<T: Plugin>` — an `Operation` subclass that invokes a plugin and assigns the result to `content`. The operation's `start()` cancels the plugin's in-flight work, then enqueues a script invocation. On `cancel()` the operation signals the plugin to terminate before its `run()` finishes.
- `enableTimer()` — re-arms the plugin's timer based on `metadata.schedule` (cron) or `metadata.interval`. The cron implementation uses `SwifCron.nextFireDate(...)` to compute the next `Date`, then schedules a `Timer` for that date on the main `RunLoop` with `mode: .common`. After firing, it reschedules.
- `parseShellConfig(...)` — helper used by `setDefaultShelf` to extract a `UserShell:` line from `dscl` output.

## Terminal launching

[AppShared.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/AppShared.swift) hosts the terminal-laundering logic.

### `runInTerminal(script:args:runInBackground:env:runInBash:completionHandler:)`

1. Builds the shell command string. The plugin's script is wrapped by:
   - `cd "<plugin directory>"`
   - `<script> <args…>`
   - `; <env-dump>` (so the user sees the resulting env)
   - If `script` is meant to be interpreted (e.g. `bash foo.sh`), it's invoked as `bash <quoted script> <args>`.
2. Reads the preferred terminal app from `PreferencesStore.preferredTerminalApp` (`.terminal`, `.iterm`, `.ghostty`, `.kitty`).
3. For each variant:
   - **Terminal.app** (`buildTerminalAppleScript(...)`): a `do shell script` is sent over AppleScript. If `runInBackground`, the script is wrapped in `&` and `; exit` to detach.
   - **iTerm** (`buildITermAppleScript(...)`): creates a new tab or window, sets the default profile, `write text`.
   - **Ghostty** (`buildGhosttyAppleScript(...)`): creates a new tab or window, sends `input text` + `send key "enter"`.
   - **Kitty** (`runInKitty(...)`): forks a child `Process` with `kitty --single-instance -- <shell> -lc "<command>"`. If the user is using `csh`/`tcsh`, `-c` is used instead of `-lc`.
4. `completionHandler` is fired after the script is dispatched.

### `runInBackground(script:args:env:runInBash:completionHandler:)`

A `Process` is constructed directly. The `Process.terminationHandler` invokes the completion handler with `Process.ExitCode?`. The script's stdout/stderr are discarded (so the menu click feels instant).

## Process lifecycle summary

```
plugin.refreshEnv = { "FOO": "bar" }
  ↓
RunPluginOperation(plugin).start()
  ↓
plugin.runScript(to: ..., env: sharedEnv.getCurrentEnv() + refreshEnv)
  ↓
Process → pipe → decode → return (out, error, exitCode)
  ↓
plugin.content = out (or error line)
  ↓
contentUpdatePublisher.send(content)
  ↓
MenubarItem.refreshMenu (menuUpdateQueue → main)
```

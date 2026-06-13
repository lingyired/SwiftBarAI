# Application Lifecycle

This document covers everything that runs in `main.swift` and `AppDelegate*`, plus the global services that the app delegate wires up.

## Entry point — `main.swift`

```swift
// main.swift
import Cocoa

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

- The app uses a manual `main.swift` (no `@main` attribute) so that `delegate` is a top-level constant that other types reference as `delegate` (see `PluginManager`, `AppShared`, all intent handlers).
- `NSApplicationMain` blocks until termination.

## `AppDelegate`

The delegate conforms to `NSApplicationDelegate`, `SPUStandardUserDriverDelegate`, `SPUUpdaterDelegate`, `UNUserNotificationCenterDelegate`, and `NSWindowDelegate`. The MAS build replaces `SPUUpdater*` conformances with empty protocols defined locally so call sites compile unchanged.

### Owned state

| Property | Type | Notes |
| --- | --- | --- |
| `repositoryWindowController` | `NSWindowController?` | Lazy-created when "Get Plugins…" is opened; sets itself as the window's delegate. |
| `preferencesWindowController` | `PreferencesWindowController` | Backed by `sindresorhus/Preferences`; rebuilt at init. |
| `repositoryToolbarSearchItem` | `NSToolbarItem?` | Search field for the repository window. |
| `pluginManager` | `PluginManager!` | Force-unwrapped; constructed in `applicationDidFinishLaunching` after the plugin folder is known. |
| `prefs` | `PreferencesStore` | Shared `UserDefaults`-backed store. |
| `sharedEnv` | `Environment` | Singleton providing `SWIFTBAR_*` env vars. |
| `softwareUpdater` | `SPUUpdater!` | Non-MAS only. |

### `applicationDidFinishLaunching(_:)`

Step-by-step:

1. `preferencesWindowController.window?.delegate = self`.
2. `setupToolbar()` — registers the repository toolbar items and search field.
3. `cleanupStatusItemVisibility()` — removes `NSStatusItem Visible *` keys from `UserDefaults` (the autosave mechanism can wrongly hide items whose plugins output nothing).
4. (Non-MAS) Initializes `SPUStandardUserDriver` and `SPUUpdater`, calls `start()`.
5. `setDefaultShelf()` — picks the user's login shell. Prefers `$SHELL` from environment, falls back to `dscl . -read /Users/<name> UserShell`, defaults to `/bin/zsh`.
6. If the configured plugin folder no longer exists, clears `prefs.pluginDirectoryPath`.
7. Constructs `PluginManager.shared`, calls `loadPlugins()`, persists a system report.
8. **First-run guard**: while `prefs.pluginDirectoryPath == nil`, an `NSAlert` blocks until the user picks a folder or quits.
9. Subscribes to `NSWorkspace.willSleep` and `didWake` notifications:
   - On sleep: updates `OS_LAST_SLEEP_TIME` and `terminateAllPlugins()`.
   - On wake: updates `OS_LAST_WAKE_TIME` and `startAllPlugins()`.

### `setDefaultShelf()`

Three-step resolution:

```swift
if let shell = ProcessInfo.processInfo.environment["SHELL"],
   shell.hasPrefix("/"),
   FileManager.default.isExecutableFile(atPath: shell)
{
    sharedEnv.userLoginShell = shell
    return
}

let out = try? runScript(to: "/usr/bin/dscl", args: [".", "-read", "/Users/\(NSUserName())", "UserShell"], runInBash: false)
if let output = out?.out, let shell = parseUserShell(from: output), shell.hasPrefix("/")
{
    sharedEnv.userLoginShell = shell
    return
}

os_log("Failed to determine user login shell, using default: %{public}@", log: Log.plugin, type: .error, sharedEnv.userLoginShell)
```

`parseUserShell(from:)` scans the lines for one starting with `UserShell:`.

### URL scheme — `application(_:open:)`

The bundle declares `CFBundleURLSchemes = ["swiftbar"]` in `Info.plist`. The delegate's `application(_:open:)` switch dispatches on `url.host?.lowercased()`:

| Host | Behavior |
| --- | --- |
| `refreshallplugins` | `pluginManager.refreshAllPlugins(reason: .RefreshAllURLScheme)` |
| `refreshplugin` | Refresh by `?name=`/`?plugin=` (also sets `refreshEnv` from other query params) or by `?index=N`. |
| `enableplugin` / `disableplugin` / `toggleplugin` | Mutates `prefs.disabledPlugins` and triggers `pluginManager`. |
| `addplugin` | Downloads the file at `?src=` and imports it. |
| `setephemeralplugin` | Creates or updates an `EphemeralPlugin` (`?name=`, `?content=`, `?exitafter=`). |
| `notify` | Builds a `UNNotificationRequest` for the named plugin, with title/subtitle/body/href/silent params. |
| `copysystemreport` | Copies the system report to the pasteboard. |
| `opensystemreport` | Opens the report file in the default app. |
| (default) | Logs an unsupported-URL error. |

If the URL is a local file URL that looks like a plugin (or a `.swiftbar` package), it's imported via `pluginManager.importPlugin(from:)` first.

### Notification click handling — `userNotificationCenter(_:didReceive:withCompletionHandler:)`

When a plugin-driven notification is clicked:

1. Look up the plugin by the `SystemNotificationName.pluginID` user-info key.
2. If `SystemNotificationName.url` is present, open it via `NSWorkspace`.
3. If `SystemNotificationName.command` is present, decode it as `MenuLineParameters` JSON and run the embedded `bash` script (terminal or background, depending on `params.terminal`), optionally refreshing the plugin afterward.

### Sparkle feed

`feedURLString(for:)` returns the `appcast.xml` or `appcast-beta.xml` based on `prefs.includeBetaUpdates`:

```swift
if prefs.includeBetaUpdates {
    return "https://lingyi.github.io/menubar01/appcast-beta.xml"
}
return "https://lingyi.github.io/menubar01/appcast.xml"
```

### Activation policy

`changePresentationType()` toggles `NSApp.setActivationPolicy(.regular)` ↔ `.accessory`:

- A regular activation policy is needed while the preferences or repository window is visible (so the app gets a Dock icon / main menu).
- An accessory policy is used the rest of the time, keeping SwiftBar out of the Dock and the Cmd-Tab switcher.

`windowWillClose(_:)` defers `changePresentationType()` by 0.5 s to allow the window's first responder to fully tear down.

## `AppShared` (static facade)

[AppShared.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/AppShared.swift) is a class of `static` methods that any menu item or SwiftUI pane can call. It is the only place outside the delegate that can perform cross-window actions.

| Method | Purpose |
| --- | --- |
| `openPluginFolder(path:)` | Reveal the plugin folder in Finder. |
| `changePluginFolder()` | `NSOpenPanel` with allowed/disallowed path checks; updates `prefs.pluginDirectoryPath` and reloads. |
| `getPlugins()` | Open the "Get Plugins…" window. If no plugin folder is set, prompts first. |
| `refreshRepositoryData()` | Force-refresh the plugin repository. |
| `openPreferences()` | Show the SwiftUI preferences window. |
| `showAbout()` | Standard `NSApp.orderFrontStandardAboutPanel()`. |
| `showPluginDebug(plugin:)` | Open the debug popover for a plugin. |
| `runInTerminal(script:args:runInBackground:env:runInBash:completionHandler:)` | Build and execute a shell command, optionally via AppleScript in Terminal/iTerm/Ghostty or as a Kitty child process. |
| `isDarkTheme`, `isDarkStatusBar`, `isReduceTransparencyEnabled` | UI mode queries. |
| `cacheDirectory`, `dataDirectory` | `URL`s for plugin per-instance cache and data dirs. |
| `checkForUpdates()` | Sparkle (non-MAS only). |

The terminal-launching functions in this file (`buildTerminalAppleScript`, `buildKittyLaunchArguments`, `kittyExecutableURL`, `runInKitty`) implement the cross-terminal behavior:

- `Terminal.app` — AppleScript keystroke "t" if a window exists, else new window.
- `iTerm` — AppleScript `create window` / `create tab with default profile` and `write text`.
- `Ghostty` — AppleScript `new tab in front window` / `new window` and `input text` + `send key "enter"`.
- `Kitty` — direct `Process` invocation with `kitty --single-instance <shell> -lc "<command>"` (or `-c` for `csh`/`tcsh`).

## `AppDelegate+Menu.swift` — `AppMenu`

Defines the minimal `NSMenu` that appears in the Dock / application menu when SwiftBar briefly switches to `.regular` activation policy. Contains: About, Send Feedback, Preferences (Cmd-,), Quit (Cmd-Q).

## `AppDelegate+Toolbar.swift` — repository toolbar

Implements `NSToolbarDelegate` for the plugin repository window. The toolbar includes:

- `NSToolbarItem.Identifier.toggleSidebar`
- `NSSearchToolbarItem` (search; posts `.repositoirySearchUpdate` to the `NotificationCenter` on text change)
- "Send Feedback" button (opens the GitHub issues page)
- "Refresh" button (calls `AppShared.refreshRepositoryData()`)

## `AppDelegate+Intents.swift` — Siri/Shortcuts routing

`application(_:handlerFor:)` returns the correct intent handler for each `INIntent` defined in [Intents.intentdefinition](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Resources/Intents.intentdefinition). See [10-Intents-and-URL-Scheme.md](./10-Intents-and-URL-Scheme.md).

## `Log.swift` — observability

```swift
enum Log {
    static let plugin      = OSLog(subsystem: "com.lingyi.menubar01", category: "Plugin")
    static let repository  = OSLog(subsystem: "com.lingyi.menubar01", category: "Plugin Repository")
    static let diagnostics = OSLog(subsystem: "com.lingyi.menubar01", category: "Diagnostics")
}
```

Use `os_log("…", log: Log.plugin, type: .info)` everywhere. To see streamable-plugin STDOUT, set `defaults write com.lingyi.menubar01 StreamablePluginDebugOutput -bool YES`.

## Hidden preferences (not exposed in UI)

Read directly from `UserDefaults` (often with a default value if missing). See [08-Preferences-and-Storage.md](./08-Preferences-and-Storage.md) for the full list and their `defaults write` incantations.

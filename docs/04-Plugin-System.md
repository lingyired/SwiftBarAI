# Plugin System

The plugin system is the heart of SwiftBar. Every "menu bar item" is a `Plugin`, an object that knows how to produce a textual output and how to react when the user clicks it.

## `Plugin` — the protocol

[Plugin.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Plugin/Plugin.swift) defines `Plugin` as a class-only protocol that extends `ObservableObject`. It is intentionally lightweight so each concrete type can be cheap to construct.

### Identity

| Property | Type | Meaning |
| --- | --- | --- |
| `metadata` | `PluginMetadata` | Refresh interval, type, custom env, name, etc. |
| `content` | `String?` | **The output** of the most recent run. The setter is `didSet` and publishes via `contentUpdatePublisher`. |
| `type` | `PluginType` | `.executable`, `.streamable`, `.packaged`, `.ephemeral`, `.shortcut`. |
| `run` | `() -> Void` | Triggers a single execution immediately. |
| `stop` | `() -> Void` | Cancels in-flight execution. |
| `terminate` | `() -> Void` | Stop and re-arm timers as appropriate. |
| `enableTimer` | `() -> Void` | Re-arm the periodic/cron timer. |
| `showInMenuBar` | `Bool` | Whether the plugin should appear in the menu bar right now (used to hide `error`/not-loaded plugins). |
| `lastRefresh` / `lastError` / `lastErrorRefresh` | `Date?` | Diagnostics. |
| `refreshDate` | `() -> Date?` | Returns the last successful refresh, if any. |
| `notify` | `(SystemNotification) -> Void` | Built-in hook to post a `UNNotificationRequest` from script output. |
| `associatedPluginPaths` | `[URL]` | Files owned by this plugin (used for import/uninstall). |
| `needsToBeTerminatedBeforeRestart` | `Bool` | True if a backup is needed when the user changes the plugin folder. |

### Updates flow

```swift
@Published var content: String? {
    didSet {
        contentUpdatePublisher.send(content)
    }
}

let contentUpdatePublisher = PassthroughSubject<String?, Never>()
```

Subscribers (the per-plugin `MenubarItem`) react on the main thread via `menuUpdateQueue`.

### Status / disabled

The `disabled` property in `PluginMetadata` (synced into `prefs.disabledPlugins`) is checked by the menu bar rendering layer; disabled plugins are not constructed.

## Concrete types

All five concrete `Plugin` types are constructed by `PluginManager`. They live in [SwiftBar/Plugin/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Plugin).

### `ExecutablePlugin` — finite scripts

For a file like `battery.10s.sh` in the plugin folder. Lifecycle:

1. `init(metadata:)` is called when the file is discovered.
2. `enableTimer()` schedules a `Timer` (or runs once) using:
   - `metadata.refreshInterval` if set, otherwise
   - The interval encoded in the filename (e.g. `.10s.`).
3. When the timer fires, `RunPluginOperation(self, refreshEnv:)` is enqueued on `pluginInvokeQueue`. The operation:
   - Cancels in-flight work.
   - Calls `runScript(to:args:runInBash:env:)` from [RunScript.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Utility/RunScript.swift).
   - Sets `self.content` to the script's `out` (truncating on errors).
   - On error, prepends a marker line and updates `lastError` / `lastErrorRefresh`.
   - Re-arms the timer.
4. `terminate()` invalidates the timer and cancels the in-flight operation.
5. `notify(_:)` posts a user notification with optional click-through to a URL or script.

`ExecutablePlugin.notify(_:)` calls `PluginManager.showNotification(plugin: SystemNotification)`. The `notify` parser is documented in [06-Plugin-Output-Parsing.md](./06-Plugin-Output-Parsing.md).

### `StreamablePlugin` — long-running scripts

For plugins that emit content continuously. Construction picks the most recent of the file's `mtime` or a previously stored `lastRefresh` from the plugin's hidden `.swiftbar/state` directory.

- `init` is failable (`init?`); returns `nil` if the executable cannot be found.
- `metadata` requires `type == .streamable`. The protocol guarantees this; assertDebug in `init`.
- `run()` is called once at startup and (optionally) again on click if `metadata.click.shouldRun` is set.
- A `Pipe` is opened; the child process is started in line-buffered mode (`enableLineBuffering()`) so output is emitted promptly.
- `Pipe.readabilityHandler` reads one byte at a time. Each new line is appended to a `pendingData` buffer; when the buffer ends with `\n`, the completed lines are concatenated and assigned to `content`.
- When the process exits (`terminationHandler`), the plugin sets `content` to an error state and posts a notification (unless `metadata.streamingDisableFailureNotif` is set).
- The cached state file is updated with the next expected refresh every 5 s (active feedback) and on termination.

The stdout is also written to `os_log` (category `Log.plugin`) if the `StreamablePluginDebugOutput` default is `YES` — useful for debugging.

### `ShortcutPlugin` — Apple Shortcuts

For plugins that wrap a Shortcut (created via the "Get Plugins" button or as an importable URL). It re-uses `ExecutablePlugin`'s dispatch logic but substitutes a `runShortcut(...)` call that uses `ShortcutsManager`:

1. Look up the shortcut by name in `ShortcutsManager.shortcutsList()`.
2. `runShortcuts(named:input:)` uses `NSAppleScript` to invoke `run shortcut` against `Shortcuts.app`.
3. The output (a string returned via Apple Events) becomes `content`.

The "Instant Run" feature (`runShortcuts(named:input:)` with `runInBackground: true`) executes the shortcut in `defaultShortcutRunType = .instant` mode, or in `.silent`, `.foreground`, `.pinnedMenuBar` modes.

### `EphemeralPlugin` — URL-scheme items

Created at runtime by `swiftbar://setephemeralplugin?...`. The plugin is rendered in the menu bar and removed when the URL is invoked again (or when `lastSet` is older than the configured TTL). Parameters:

- `name=…` — display name.
- `content=…` — the textual body to render. First line is the menu-bar title, everything after `---` is the dropdown.
- `href=…` — optional link.
- `image=…` — optional base64 image data URL for the menu bar icon.
- `exitafter=…` — hide the item automatically after N seconds.
- `reset=true` — re-set even if name is unchanged.

If no content is provided, the menu-bar item is removed. Ephemeral plugins never go to disk.

### `PackagedPlugin` — `.swiftbar` bundles

A `.swiftbar` package is a directory whose name ends in `.swiftbar`, recognized as a `com.ameba.SwiftBar.PluginPackage` UTI. Inside:

```
myplugin.swiftbar/
├── plugin.sh           # required: the entry executable
├── metadata.json       # optional, takes precedence over filename
├── icon.png            # optional
├── app.icns            # optional
├── AppIcon.icns        # optional
├── README.md
├── LICENSE
├── screenshot.png
└── …                   # additional files referenced via relative URL
```

`init(directory: env:)` recursively scans for a child directory matching `<name>.swiftbar` (or treats the path itself as the package directory). It computes a stable cache path under `cacheDirectory/package/<id>/` (where `id = SHA256(dir.path)`):

- Copies every file into the cache, preserving relative structure.
- Reads `metadata.json` if present and uses it as `PluginMetadata`. This file lets plugins ship structured metadata (name, refresh interval, dependencies, triggers) without relying on the filename convention.
- Looks for `app.icns` / `AppIcon.icns` and uses the first one found as the menu-bar icon (NSImage).
- Returns a `PackagedPlugin` whose `executableURL` is `<cache>/plugin.sh`. The package is then exec'd like a regular `ExecutablePlugin`.

On macOS, `.swiftbar` packages are also `FilePackage` document bundles; opening one of them with the default app opens SwiftBar with a new plugin in the folder.

## `PluginMetadata`

[PluginMetadata.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Plugin/PluginMetadata.swift) holds the resolved configuration. Two factories:

- `PluginMetadata(filename:)` — parses `<name>.<interval>.<ext>`.
- `PluginMetadata(file:)` — delegates to the filename factory.
- `PluginMetadata(pluginPackage:)` — also available, and used by `PackagedPlugin`.
- `init(name: type: enabled: …)` — direct construction.

Notable fields:

| Field | Notes |
| --- | --- |
| `type` | Defaults to `.executable`; the filename-based factory infers `.streamable` from the `*/stream*` token and `.packaged` from the `.swiftbar` extension. |
| `name` | Base filename without the interval token. |
| `interval` | Parsed from filename via `parseRefreshInterval(...)`. Supports `10s`, `5m`, `1h`, etc.; falls back to default 10s. |
| `schedule` | Optional cron expression. If set, the plugin is re-armed via a `Timer` whose `fireDate` is the next matching fire time (`SwifCron.nextFireDate`); after firing, the timer is rescheduled. |
| `customEnv` | Extra env vars injected when the script runs. |
| `triggers` | The xbar-style `<swiftbar.triggers>` parsed from script output (an empty array if not used). |
| `click` | `<swiftbar.click>` config (run script on click, open URL, post notification). |
| `image` | The `<swiftbar.image>` resolved URL (after `FileFinder` checks the package / data folder). |
| `forceUpdateInterval` | The minimum interval at which SwiftBar is allowed to re-render. |
| `streamingDisableFailureNotif` | Set by `ExecutablePlugin` as `true` for streamable plugins so they don't double-notify. |
| `lastUpdated` | A counter incremented on every change so the menu bar UI can `Equatable` against it. |
| `lastError` | Captured during script run; copied here on `lastErrorRefresh`. |

## `PluginManager`

[PluginManger.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Plugin/PluginManger.swift) (typo preserved for git-blame stability). Singleton (`PluginManager.shared`).

### Owned state

| Property | Type | Notes |
| --- | --- | --- |
| `plugins` | `[Plugin]` | The full list, including disabled. `didSet` → `pluginsDidChange()`. |
| `enabledPlugins` | `[Plugin]` | Computed by filtering `disabledPlugins`. |
| `menuBarItems` | `[Plugin.ID: MenubarItem]` | One per enabled plugin. |
| `pluginInvokeQueue` | `OperationQueue` | `.userInitiated`, max 20. |
| `menuUpdateQueue` | `OperationQueue` | `.userInteractive`, max 10. |
| `lastSystemReport` / `lastSystemReportReason` | `String?` / `String?` | Most recent report. |
| `ephemeral` | `EphemeralPlugin?` | The single active ephemeral plugin. |

### Public API

- `loadPlugins()` — runs the discovery pipeline:
  1. Resets `plugins`.
  2. Scans the plugin folder (and selected subfolders) for `*.swiftbar` directories, scripts, and Apple Shortcut links.
  3. Constructs the matching `Plugin` subclass for each.
  4. Picks the `setDefaultPluginsEnabled` / `disableAllPlugins` rules.
  5. Calls `pluginsDidChange()`.
- `pluginsDidChange()` — reconciles `menuBarItems` with `plugins`:
  - Adds new items; `startPlugin(...)` for each new.
  - Removes old items; `terminatePlugin(...)` for each.
  - Calls `updateDefaultBarItemVisibility()`.
  - Persists a system report.
- `startAllPlugins()` / `terminateAllPlugins()` — used on wake/sleep.
- `refreshAllPlugins(reason:)` — used on click and URL scheme.
- `refreshAllMenus()` / `refreshMenu(pluginID:)` — re-apply NSMenu diffing for one or all.
- `importPlugin(from:)` / `importPlugin(named:from:)` / `importPlugin(url:)` — install a plugin, marking the source with an `xattr` (`.SwiftBar.SourceURL`) to remember where it came from.
- `showNotification(plugin: SystemNotification)` — used by `notify=` lines.
- `showAlert(plugin: SystemNotification)` — modal alert variant.
- `currentSystemReport(reason:)` — see [02-Architecture.md](./02-Architecture.md#diagnostics).
- `openLatestSystemReport()` / `copyLatestSystemReportToPasteboard()`.
- `runInTerminal(...)` — proxy to `AppShared.runInTerminal`.
- `startStreamablePlugin(_:)` / `terminateStreamablePlugin(_:)` — convenience for streamable lifecycle.
- `applyEphemeral(...)` — create or update the active `EphemeralPlugin`; clear when `content` is nil.
- `setPluginsEnabled(_:pluginIDs:)` / `disableAllPlugins()`.
- `setEphemeralPlugin(...)` — entry point for the `swiftbar://setephemeralplugin` handler.

### Subsystem updates

`PluginManager` listens to `PreferencesStore.disabledPlugins` and other `PassthroughSubject`s. When `disabledPlugins` changes, it calls `loadPlugins()`.

`PluginManager` also subscribes to `NSWorkspace`'s sleep/wake notifications (forwarded by `AppDelegate`) and to its own `DirectoryObserver`:

- The directory observer watches the plugin folder and `~/Library/Application Support/SwiftBar/ephemeral/` (used by tests).
- On change, it calls `loadPlugins()` and updates the directory watcher's list of known paths.

### Threading

- `loadPlugins` is a `@objc` method and is called on the main thread (or asserted via `dispatchPrecondition`).
- `pluginInvokeQueue` and `menuUpdateQueue` are the only queues that should mutate plugin content.
- Subscription to `contentUpdatePublisher` happens on `menuUpdateQueue` (passed in via `receive(on:)`).

## `PluginDebugInfo` — per-plugin debug event log

[PluginDebugInfo.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Plugin/PluginDebugInfo.swift) keeps a rolling `maxEntries`-bounded `entries` array of `PluginDebugInfo.Entry { timestamp, content }`. The debug popover (`AppShared.showPluginDebug(plugin:)`) shows this list and offers a copy / clear action. It is shared across runs and re-read on `init` from `Application Support/<AppName>/Plugins/<plugin-id>.log` if it exists, so past events persist across restarts.

## Putting it together — an item's full lifecycle

1. **Discovery** — `PluginManager.loadPlugins` finds `battery.10s.sh` and creates an `ExecutablePlugin(metadata:)`.
2. **Add to menu bar** — `pluginsDidChange` constructs `MenubarItem(plugin:)`, which subscribes to the plugin's `contentUpdatePublisher`.
3. **First run** — `MenubarItem` calls `plugin.run()`; the plugin enqueues a `RunPluginOperation`; the script outputs `🔋 87%`; the operation sets `self.content`; the publisher fires; the menu bar updates.
4. **Periodic refresh** — the plugin's timer fires; another `RunPluginOperation` runs; content updates; menu bar refreshes.
5. **Click** — `MenuItemNode` routes the click to `MenuItemNode.performAction(_:)`; this either opens the URL, posts a notification, or invokes a `terminal`/`bash` command (`MenuLineParameters`).
6. **Disable** — user unchecks the plugin in Preferences; `prefs.disabledPlugins` publishes; `loadPlugins` is called; the item is removed; the `MenubarItem` is destroyed.

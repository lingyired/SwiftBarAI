# Preferences and Storage

menubar01 stores all user preferences in `UserDefaults` (a single `PreferencesStore` singleton acts as the typed facade) and in a few on-disk files (plugin-folder state, the system report, and the launcher data folder).

## `PreferencesStore`

[PreferencesStore.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/PreferencesStore.swift) is a single class:

```swift
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()
    private let userDefaults = UserDefaults(suiteName: "com.lingyi.menubar01")!
    …
}
```

It uses a custom `UserDefaults` suite so the data lives in `~/Library/Preferences/com.lingyi.menubar01.plist`. Almost every property is wrapped in `get` / `set` pairs that read from `userDefaults` and write back through `userDefaults.set(_:forKey:)`.

### Published events

| `PassthroughSubject` | When fired |
| --- | --- |
| `disabledPlugins` | When `disabledPlugins` set. |
| `menubar01IconIsHidden` | When `hideIcon` set. |
| `pluginDirectoryPath` | When `pluginDirectoryPath` set. |
| `preferredTerminalApp` | When the preferred terminal changes. |
| `showDefaultMenuBar` | When the dock-menu default is toggled. |
| `shortcutsList` | When the `ShortcutPlugin` list is reloaded. |

Subscribers (e.g. `PluginManager`, `AppShared`) use these to react and reconcile state.

## Exposed preferences

Most of these have a UI in `menubar01/UI/Preferences/`. The full list (with type, default, and `defaults write` key) is below.

| Property | Type | Default | `defaults write com.lingyi.menubar01 …` key |
| --- | --- | --- | --- |
| `pluginDirectoryPath` | `String?` | `nil` | `PluginDirectoryPath` |
| `showDefaultMenuBar` | `Bool` | `false` | `ShowDefaultMenuBar` |
| `hideIcon` | `Bool` | `false` | `Hidemenubar01DefaultIcon` |
| `disabledPlugins` | `Set<String>` | `[]` | `DisabledPlugins` |
| `setDefaultPluginsEnabled` | `Bool` | `false` | `SetDefaultPluginsEnabled` |
| `disableAllPlugins` | `Bool` | `false` | `DisableAllPlugins` |
| `preferences` | `String?` | `nil` | `Preferences` |
| `showPluginRepository` | `Bool` | `true` | `ShowPluginRepository` |
| `includeBetaUpdates` | `Bool` | `false` | `IncludeBetaUpdates` |
| `preferredTerminalApp` | `TerminalApp` | `.terminal` | `PreferredTerminalApp` |
| `shortcutDefaults` | `[String: [String: String]]` | `[]` | `ShortcutDefaults` |
| `shortcutsList` | `[(name: String, runType: String, schedule: String?)]` | `[]` | `ShortcutsList` |
| `showShortcutPlugins` | `Bool` | `false` | `ShowShortcutPlugins` |
| `userBashScript` | `String?` | `nil` | `UserBashScript` |
| `userZshScript` | `String?` | `nil` | `UserZshScript` |
| `userFishScript` | `String?` | `nil` | `UserFishScript` |
| `userScriptOverride` | `String?` | `nil` | `UserScriptOverride` |
| `showDefaultMenuBar` | `Bool` | `false` | `ShowDefaultMenuBar` |
| `disablePluginReordering` | `Bool` | `false` | `DisablePluginReordering` |
| `swifCronUpdatesPerMinute` | `Int` | `60` | `SwifCronUpdatesPerMinute` |
| `defaultShortcutRunType` | `ShortcutRunType` | `.instant` | `DefaultShortcutRunType` |
| `showDefaultBarItemsInStatusBar` | `Bool` | `false` | `ShowDefaultBarItemsInStatusBar` |
| `dataDirectory`, `cacheDirectory` | `URL?` | `nil` (overridable) | `DataDirectory`, `CacheDirectory` |

### Terminal apps

```swift
enum TerminalApp: String, CaseIterable {
    case terminal
    case iterm
    case ghostty
    case kitty
}
```

The selected terminal is used by `AppShared.runInTerminal`. The Preferences pane is `TerminalPreferencesView`.

## Hidden settings (read directly from `UserDefaults`)

These are not in the UI. They are useful for debugging and for power users.

| Setting | Key | Default | Purpose |
| --- | --- | --- | --- |
| Enable verbose logging | `Debug` (also `Verbose` shortcuts) | `false` | `os_log` at `.debug` level. |
| (removed in 1ccd8ef) | `StreamablePluginDebugOutput` | n/a | Streamable plugin type was removed; the preference key is harmless to leave in user state. |
| Use a debug cache dir | `DebugCacheDirectory` | `false` | Routes package caches to `/tmp`. |
| Bundle-id override | `BundleIdentifier` | `com.lingyi.menubar01` | For development builds. |
| Date formatter | `DateFormat` | system locale | |
| `RefreshPluginByDefault` | `RefreshPluginByDefault` | `false` | Always run the user's `defaultRefreshPlugin` script. |
| `AppDelegate.firstRun` | `FirstRun` | `true` | Show the plugin-folder picker again. |
| `isFirstRun` | `isFirstRun` | `true` | Internal: prevent Sparkle from running on first launch. |
| `ForceDarkMode` | `ForceDarkMode` | `false` | Force the SwiftUI repository window into dark mode. |
| `StreamablePluginDebugOutput` | (see above; removed in 1ccd8ef) | n/a | |
| `OS_LAST_SLEEP_TIME`, `OS_LAST_WAKE_TIME`, `OS_START_TIME` | (set at runtime) | `nil` | Updated in `AppDelegate`. |
| Status item visible overrides | `NSStatusItem Visible <bundle-id>.<key>` | `true` | AppKit's autosave; removed by `AppDelegate.cleanupStatusItemVisibility`. |

## On-disk state

- `~/Library/Application Support/menubar01/`
  - `Diagnostics/latest-system-report.txt` — most recent system report, refreshed on every plugin change or refresh.
  - `PluginRepository.json` — the cached plugin list, refreshed on every "Get Plugins…" launch.
  - `PluginRepositoryData/` — git checkout of [swiftbar/swiftbar-plugins](https://github.com/swiftbar/swiftbar-plugins).
- `<plugin folder>/<plugin>/`
  - `state/<plugin-id>/state` — last successful refresh, last error refresh, etc., used by streamable plugins.
- `<plugin folder>/<plugin>/`
  - `state/<plugin-id>/log` — debug entries, loaded by `PluginDebugInfo.init(plugin:)`.

## `Defaults.plist`-style keys (compiled in)

A few defaults are read straight from `UserDefaults.standard` instead of the typed store. They are present for backward compatibility with old xbar/BitBar installations.

```
defaults write com.lingyi.menubar01 UseImageSizeFromUserDefaults -bool YES
defaults write com.lingyi.menubar01 UserImageSize 18
defaults write com.lingyi.menubar01 MenuBarIconSize 18
```

## Migration

`PreferencesStore` was built around the assumption that the only key stable across versions is `PluginDirectoryPath`. A new key that the user might want to change is added with a sensible default and a `defaults write` hint. There is no migration code path; new installations start with the defaults, and old installations keep their data.

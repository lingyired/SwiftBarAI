# Project Overview

## What SwiftBar is

SwiftBar is a **macOS menu-bar customization tool** that turns small executable scripts into live items in the system menu bar. It is the official successor to BitBar/xbar for macOS, written natively in Swift.

User workflow:

1. Drop an executable script (any language) into a chosen "Plugin Folder".
2. SwiftBar runs the script, parses the output, and renders the result in the menu bar and a dropdown menu.
3. The script can be re-run on a schedule, on click, on sleep/wake, or via the `swiftbar://` URL scheme, and can also be backed by Apple Shortcuts.

> Repository default branch: `main`. Minimum macOS: 10.15 (Catalina). The app's own UI is built with a mix of AppKit (NSStatusItem, NSMenu) and SwiftUI (preferences, repository, popovers).

## Key facts

| Property | Value |
| --- | --- |
| Bundle ID | `com.ameba.SwiftBar` |
| URL Scheme | `swiftbar://` |
| Document type | `.swiftbar` (a folder recognized as a Plugin Package) |
| UTI | `com.ameba.SwiftBar.PluginPackage` |
| Min macOS | 10.15 (Catalina) |
| UI Frameworks | AppKit + SwiftUI (hosted in `NSHostingController`) |
| Persistence | `UserDefaults` (driven by `PreferencesStore`) + on-disk plugin folder |
| Distribution | Direct (Sparkle) + Mac App Store (sandbox-friendly) |

## Tech stack

- **Language**: Swift 5.x
- **Build system**: Xcode project (`SwiftBar.xcodeproj`) with two targets: `SwiftBar` and `SwiftBar MAS`. The MAS target is selected via the `MAC_APP_STORE` Swift compile flag.
- **UI**: AppKit for the menu bar, SwiftUI for the preferences window, plugin repository window, plugin detail, debug, and popover content.
- **Notifications**: `UserNotifications` (UNUserNotificationCenter) for plugin-driven notifications.
- **Apple Events / Shortcuts**: `ScriptingBridge` to talk to `com.apple.shortcuts.events`.
- **Updater**: `Sparkle` (non-MAS builds only).
- **Launch at login**: `ServiceManagement` (`SMAppService.mainApp`).
- **Cron parsing**: `SwifCron`.
- **Global hotkeys**: `HotKey`.

## Third-party SwiftPM dependencies

Defined in [Package.resolved](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved):

| Package | Version | Why |
| --- | --- | --- |
| `HotKey` (forked under `swiftbar/`) | 0.1.3 | Global keyboard shortcuts for menu items. |
| `LaunchAtLogin` (sindresorhus) | 5.0.0 | Toggle "Launch at login". |
| `Preferences` (sindresorhus) | 2.6.0 | SwiftUI preferences window host. |
| `Sparkle` (sparkle-project) | 2.4.1 | Software update channel for non-MAS builds. |
| `SwifCron` (MihaelIsaev) | 2.0.0 | Cron expression parsing for `<swiftbar.schedule>`. |

Forks live under the `swiftbar/` GitHub org specifically to "freeze and secure dependencies".

## Build flavors

The Xcode project defines two schemes:

- `SwiftBar` — direct distribution, Sparkle updater, full file-system access.
- `SwiftBar MAS` — Mac App Store build, no Sparkle, sandbox-friendly, with a different entitlements file (`SwiftBar MAS.entitlements`).

Switching is done with the `MAC_APP_STORE` Swift compile flag. Most code uses `#if !MAC_APP_STORE` to omit Sparkle and certain file-system observers.

## Module / folder map

| Folder | Purpose |
| --- | --- |
| [SwiftBar/main.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/main.swift) | NSApplication bootstrap. |
| [SwiftBar/AppDelegate*.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/AppDelegate.swift) | App lifecycle, URL routing, toolbar, intents. |
| [SwiftBar/Plugin/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Plugin) | Plugin model and all concrete types. |
| [SwiftBar/MenuBar/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/MenuBar) | NSStatusItem / NSMenu rendering pipeline. |
| [SwiftBar/Intents/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Intents) | Siri/Shortcuts intent handlers. |
| [SwiftBar/Utility/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Utility) | Process launching, env, helpers, extensions. |
| [SwiftBar/UI/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/UI) | SwiftUI windows and panes. |
| [SwiftBar/Resources/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Resources) | Info.plist, Assets, Localizable.strings, Intents.intentdefinition. |
| [SwiftBarTests/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBarTests) | Minimal unit-test bundle. |

## External plugin contract

A SwiftBar plugin is a plain executable file with a name following the convention:

```
{name}.{refresh-interval}.{ext}
```

For example: `battery.10s.py` — refresh every 10 seconds. The output of the script is parsed line by line. The first `---` line is the boundary between the menu-bar header and the dropdown body. Each line follows:

```
<Item Title> | param1=value1 param2="value 2" ...
```

Full grammar and parameters are documented in [06-Plugin-Output-Parsing.md](./06-Plugin-Output-Parsing.md) and the [project README](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/README.md).

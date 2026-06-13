# Project Overview

## What menubar01 is

menubar01 is a **macOS menu-bar customization tool** that turns small executable scripts into live items in the system menu bar. It is the official successor to BitBar/xbar for macOS, written natively in Swift.

User workflow:

1. Drop an executable script (any language) into a chosen "Plugin Folder".
2. menubar01 runs the script, parses the output, and renders the result in the menu bar and a dropdown menu.
3. The script can be re-run on a schedule, on click, on sleep/wake, or via the `menubar01://` URL scheme, and can also be backed by Apple Shortcuts.

> Repository default branch: `main`. Minimum macOS: 10.15 (Catalina). The app's own UI is built with a mix of AppKit (NSStatusItem, NSMenu) and SwiftUI (preferences, repository, popovers).

## Key facts

| Property | Value |
| --- | --- |
| Bundle ID | `com.lingyi.menubar01` |
| URL Scheme | `menubar01://` |
| Document type | (none — `.swiftbar` UTI removed in 1acb6d0) |
| UTI | (none — `.swiftbar` UTI removed in 1acb6d0) |
| Min macOS | 10.15 (Catalina) |
| UI Frameworks | AppKit + SwiftUI (hosted in `NSHostingController`) |
| Persistence | `UserDefaults` (driven by `PreferencesStore`) + on-disk plugin folder |
| Distribution | Direct (Sparkle) + Mac App Store (sandbox-friendly) |

## Tech stack

- **Language**: Swift 5.x
- **Build system**: Xcode project (`menubar01.xcodeproj`) with two targets: `menubar01` and `menubar01 MAS`. The MAS target is selected via the `MAC_APP_STORE` Swift compile flag.
- **UI**: AppKit for the menu bar, SwiftUI for the preferences window, plugin repository window, plugin detail, debug, and popover content.
- **Notifications**: `UserNotifications` (UNUserNotificationCenter) for plugin-driven notifications.
- **Apple Events / Shortcuts**: `ScriptingBridge` to talk to `com.apple.shortcuts.events`.
- **Updater**: `Sparkle` (non-MAS builds only).
- **Launch at login**: `ServiceManagement` (`SMAppService.mainApp`).
- **Cron parsing**: `SwifCron`.
- **Global hotkeys**: `HotKey`.

## Third-party SwiftPM dependencies

Defined in [Package.resolved](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved):

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

- `menubar01` — direct distribution, Sparkle updater, full file-system access.
- `menubar01 MAS` — Mac App Store build, no Sparkle, sandbox-friendly, with a different entitlements file (`menubar01 MAS.entitlements`).

Switching is done with the `MAC_APP_STORE` Swift compile flag. Most code uses `#if !MAC_APP_STORE` to omit Sparkle and certain file-system observers.

## Module / folder map

| Folder | Purpose |
| --- | --- |
| [menubar01/main.swift](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/main.swift) | NSApplication bootstrap. |
| [menubar01/AppDelegate*.swift](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/AppDelegate.swift) | App lifecycle, URL routing, toolbar, intents. |
| [menubar01/Plugin/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/Plugin) | Plugin model and all concrete types. |
| [menubar01/MenuBar/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/MenuBar) | NSStatusItem / NSMenu rendering pipeline. |
| [menubar01/Intents/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/Intents) | Siri/Shortcuts intent handlers. |
| [menubar01/Utility/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/Utility) | Process launching, env, helpers, extensions. |
| [menubar01/UI/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/UI) | SwiftUI windows and panes. |
| [menubar01/Resources/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/Resources) | Info.plist, Assets, Localizable.strings, Intents.intentdefinition. |
| [menubar01Tests/](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01Tests) | Minimal unit-test bundle. |

## External plugin contract

A menubar01 plugin is a plain executable file with a name following the convention:

```
{name}.{refresh-interval}.{ext}
```

For example: `battery.10s.py` — refresh every 10 seconds. The output of the script is parsed line by line. The first `---` line is the boundary between the menu-bar header and the dropdown body. Each line follows:

```
<Item Title> | param1=value1 param2="value 2" ...
```

Full grammar and parameters are documented in [06-Plugin-Output-Parsing.md](./06-Plugin-Output-Parsing.md) and the [project README](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/README.md).

# Build and Run

This document explains how menubar01 is built, how to run it from Xcode, and how the various deployment flavors are switched.

## Requirements

- **Xcode** 14.0 or newer (Swift 5.7+).
- **macOS** 10.15+ (the build host; the deployment target is 10.15).
- **Command Line Tools** for `git`, `swift`, `dscl` (used by `setDefaultShelf`).
- A working internet connection the first time you build, so SwiftPM can pull dependencies.

## Project layout (build-side)

```
menubar01.xcodeproj/
└── project.pbxproj         # Two targets, two schemes

menubar01/
├── main.swift              # Entry point
├── AppDelegate.swift       # App delegate
├── AppDelegate+*.swift     # Toolbar, Menu, Intents
├── …                       # The rest of the app

menubar01Tests/
├── Info.plist
└── …                       # Minimal tests
```

The Xcode project defines two targets:

| Target | Build flavor | Purpose |
| --- | --- | --- |
| `menubar01` | Direct distribution | Includes Sparkle. Uses [Resources/Info.plist](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01/Resources/Info.plist) and `menubar01.entitlements`. |
| `menubar01 MAS` | Mac App Store | No Sparkle. Uses `menubar01 MAS.entitlements`. Compiled with the `MAC_APP_STORE` Swift flag. |

## How to build and run

### From Xcode

1. Open `menubar01.xcodeproj`.
2. Select the `menubar01` scheme (top toolbar).
3. Pick **My Mac** as the destination.
4. **Product → Run** (⌘R). Xcode will resolve packages and build.

For the MAS build, switch the scheme to `menubar01 MAS` before running.

### From the command line

```bash
# Direct distribution build
xcodebuild -project menubar01.xcodeproj -scheme menubar01 -configuration Release

# Mac App Store build
xcodebuild -project menubar01.xcodeproj -scheme "menubar01 MAS" -configuration Release
```

To open the built `.app` and launch it:

```bash
open ./build/Release/menubar01.app
```

### Code signing

The two targets use different code-signing identities. The default for local development is **Sign to Run Locally** (no team required). For a notarized release, the project expects the `Developer ID Application: ...` identity and a Sparkle-supplied `edDSA` key for the direct build.

## Dependencies

Dependencies are resolved automatically by SwiftPM through [Package.resolved](file:///Users/lingsmbp/Documents/aiwork/menubar01AI/menubar01.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). They are:

- `HotKey` (forked under `swiftbar/`) — 0.1.3
- `LaunchAtLogin` (sindresorhus) — 5.0.0
- `Preferences` (sindresorhus) — 2.6.0
- `Sparkle` (sparkle-project) — 2.4.1
- `SwifCron` (MihaelIsaev) — 2.0.0

## Configuration flags

### `MAC_APP_STORE`

The single Swift flag that toggles between the two build flavors. Define it in the **Swift Compiler – Custom Flags** → **Other Swift Flags** build setting (`-D MAC_APP_STORE`) to enable MAS mode. The two targets in the project set this automatically based on which target is being built.

When defined:

- `SPUUpdater` calls are no-ops (an empty protocol is conformed to).
- `DirectoryObserver` is not enabled.
- The "Check for Updates" UI is hidden.
- The "Use beta updates" toggle is hidden.
- The "Sparkle" log category is omitted.

When undefined (the default `menubar01` target):

- `SPUUpdater` updates are enabled, with the feed URL controlled by `prefs.includeBetaUpdates`:
  - `https://lingyi.github.io/menubar01/appcast.xml`
  - `https://lingyi.github.io/menubar01/appcast-beta.xml`
- `DirectoryObserver` is used to live-update when the plugin folder changes.

### Hidden preference toggles

Useful for development and debugging:

```
defaults write com.lingyi.menubar01 Debug -bool YES
defaults write com.lingyi.menubar01 StreamablePluginDebugOutput -bool YES
defaults write com.lingyi.menubar01 IncludeBetaUpdates -bool YES
defaults write com.lingyi.menubar01 ForceDarkMode -bool YES
```

Reset the defaults with:

```
defaults delete com.lingyi.menubar01
```

## First-run flow

1. The app launches with `NSApp.setActivationPolicy(.accessory)` so it lives in the menu bar.
2. If no plugin folder is configured, a modal `NSAlert` blocks until the user picks one (or quits).
3. The plugin folder is watched by `DirectoryObserver` (non-MAS) for changes; new files become `Plugin` instances.
4. Each plugin is run on its configured cadence. Output is parsed into `MenuItemNode` trees, then diffed into `NSMenu`s.

## Logging

```
log stream --predicate 'subsystem == "com.lingyi.menubar01"' --style compact
```

Or, in Xcode's console, filter by `com.lingyi.menubar01`. To enable debug-level output, set `Debug` and `StreamablePluginDebugOutput` to `YES` (see above) and relaunch.

## Tests

```bash
xcodebuild test -project menubar01.xcodeproj -scheme menubar01 -destination 'platform=macOS'
```

The current test target is light; consider it a starting point for unit-testing the script/output/grammar layers.

## Packaging

### Direct distribution (Sparkle)

- Build the `menubar01` Release configuration.
- The `.app` is uploaded to GitHub Releases with a Sparkle `appcast.xml` entry. The `appcast.xml` is published at `https://lingyi.github.io/menubar01/appcast.xml` (and a `*-beta.xml` variant for pre-releases).

### Mac App Store

- Build the `menubar01 MAS` Release configuration.
- Codesign with the App Store distribution identity.
- Submit via App Store Connect.

## Common pitfalls

- **Plugin folder permission** — On the first run, the user must pick the plugin folder via the GUI. menubar01 stores a security-scoped bookmark for the directory in MAS builds, so simply changing `PluginDirectoryPath` in `defaults` may not work in MAS.
- **Apple Events / Automation** — The first time a user runs a script in Terminal/iTerm, macOS prompts for permission. menubar01 launches `osascript` (via `ShortcutsManager`), which the user must allow.
- **Plugin output order** — Plugins are sorted by `metadata.priority` (descending) and then by file name. The `DisablePluginReordering` default forces the file-name sort.
- **Sparkle updates** — On a development build, `SPUUpdater.start()` is called and will hit the production `appcast.xml`. To prevent updates during local development, set the bundle id to something unique (e.g. `com.lingyi.menubar01-dev`):

  ```
  defaults write com.lingyi.menubar01 BundleIdentifier com.lingyi.menubar01-dev
  ```

# Build and Run

This document explains how SwiftBar is built, how to run it from Xcode, and how the various deployment flavors are switched.

## Requirements

- **Xcode** 14.0 or newer (Swift 5.7+).
- **macOS** 10.15+ (the build host; the deployment target is 10.15).
- **Command Line Tools** for `git`, `swift`, `dscl` (used by `setDefaultShelf`).
- A working internet connection the first time you build, so SwiftPM can pull dependencies.

## Project layout (build-side)

```
SwiftBar.xcodeproj/
└── project.pbxproj         # Two targets, two schemes

SwiftBar/
├── main.swift              # Entry point
├── AppDelegate.swift       # App delegate
├── AppDelegate+*.swift     # Toolbar, Menu, Intents
├── …                       # The rest of the app

SwiftBarTests/
├── Info.plist
└── …                       # Minimal tests
```

The Xcode project defines two targets:

| Target | Build flavor | Purpose |
| --- | --- | --- |
| `SwiftBar` | Direct distribution | Includes Sparkle. Uses [Resources/Info.plist](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/Resources/Info.plist) and `SwiftBar.entitlements`. |
| `SwiftBar MAS` | Mac App Store | No Sparkle. Uses `SwiftBar MAS.entitlements`. Compiled with the `MAC_APP_STORE` Swift flag. |

## How to build and run

### From Xcode

1. Open `SwiftBar.xcodeproj`.
2. Select the `SwiftBar` scheme (top toolbar).
3. Pick **My Mac** as the destination.
4. **Product → Run** (⌘R). Xcode will resolve packages and build.

For the MAS build, switch the scheme to `SwiftBar MAS` before running.

### From the command line

```bash
# Direct distribution build
xcodebuild -project SwiftBar.xcodeproj -scheme SwiftBar -configuration Release

# Mac App Store build
xcodebuild -project SwiftBar.xcodeproj -scheme "SwiftBar MAS" -configuration Release
```

To open the built `.app` and launch it:

```bash
open ./build/Release/SwiftBar.app
```

### Code signing

The two targets use different code-signing identities. The default for local development is **Sign to Run Locally** (no team required). For a notarized release, the project expects the `Developer ID Application: ...` identity and a Sparkle-supplied `edDSA` key for the direct build.

## Dependencies

Dependencies are resolved automatically by SwiftPM through [Package.resolved](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). They are:

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

When undefined (the default `SwiftBar` target):

- `SPUUpdater` updates are enabled, with the feed URL controlled by `prefs.includeBetaUpdates`:
  - `https://swiftbar.github.io/SwiftBar/appcast.xml`
  - `https://swiftbar.github.io/SwiftBar/appcast-beta.xml`
- `DirectoryObserver` is used to live-update when the plugin folder changes.

### Hidden preference toggles

Useful for development and debugging:

```
defaults write com.ameba.SwiftBar Debug -bool YES
defaults write com.ameba.SwiftBar StreamablePluginDebugOutput -bool YES
defaults write com.ameba.SwiftBar IncludeBetaUpdates -bool YES
defaults write com.ameba.SwiftBar ForceDarkMode -bool YES
```

Reset the defaults with:

```
defaults delete com.ameba.SwiftBar
```

## First-run flow

1. The app launches with `NSApp.setActivationPolicy(.accessory)` so it lives in the menu bar.
2. If no plugin folder is configured, a modal `NSAlert` blocks until the user picks one (or quits).
3. The plugin folder is watched by `DirectoryObserver` (non-MAS) for changes; new files become `Plugin` instances.
4. Each plugin is run on its configured cadence. Output is parsed into `MenuItemNode` trees, then diffed into `NSMenu`s.

## Logging

```
log stream --predicate 'subsystem == "com.ameba.SwiftBar"' --style compact
```

Or, in Xcode's console, filter by `com.ameba.SwiftBar`. To enable debug-level output, set `Debug` and `StreamablePluginDebugOutput` to `YES` (see above) and relaunch.

## Tests

```bash
xcodebuild test -project SwiftBar.xcodeproj -scheme SwiftBar -destination 'platform=macOS'
```

The current test target is light; consider it a starting point for unit-testing the script/output/grammar layers.

## Packaging

### Direct distribution (Sparkle)

- Build the `SwiftBar` Release configuration.
- The `.app` is uploaded to GitHub Releases with a Sparkle `appcast.xml` entry. The `appcast.xml` is published at `https://swiftbar.github.io/SwiftBar/appcast.xml` (and a `*-beta.xml` variant for pre-releases).

### Mac App Store

- Build the `SwiftBar MAS` Release configuration.
- Codesign with the App Store distribution identity.
- Submit via App Store Connect.

## Common pitfalls

- **Plugin folder permission** — On the first run, the user must pick the plugin folder via the GUI. SwiftBar stores a security-scoped bookmark for the directory in MAS builds, so simply changing `PluginDirectoryPath` in `defaults` may not work in MAS.
- **Apple Events / Automation** — The first time a user runs a script in Terminal/iTerm, macOS prompts for permission. SwiftBar launches `osascript` (via `ShortcutsManager`), which the user must allow.
- **Plugin output order** — Plugins are sorted by `metadata.priority` (descending) and then by file name. The `DisablePluginReordering` default forces the file-name sort.
- **Sparkle updates** — On a development build, `SPUUpdater.start()` is called and will hit the production `appcast.xml`. To prevent updates during local development, set the bundle id to something unique (e.g. `com.ameba.SwiftBar-dev`):

  ```
  defaults write com.ameba.SwiftBar BundleIdentifier com.ameba.SwiftBar-dev
  ```

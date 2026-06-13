# Utilities

This document is a reference for the small, single-purpose helpers and extensions that don't have a natural home in the main subsystems. Most live under [menubar01/Utility/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility).

## `String+Escaped.swift`

[Utility/String+Escaped.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/String+Escaped.swift) — string helpers for shell and URL handling.

| Method | Notes |
| --- | --- |
| `escaped()` | Wraps in single quotes if it contains a space. |
| `appleScriptEscaped()` | Escapes `\` and `"` for AppleScript string literals. |
| `getURL()` | Returns a `URL?`, falling back to percent-encoding against the URL host+path set. |
| `URLEncoded` | Percent-encodes the string against a hard-coded "unreserved" set. |
| `isEnclosedInQuotes` | True if the string is already properly single-quoted (with `'\''` escapes for embedded quotes). |
| `needsShellQuoting` | True if the string contains shell metacharacters (excluding pure operators). |
| `quoteIfNeeded()` | Returns the string, single-quoted if necessary, with `'\''` escapes. |

Used by `RunScript.runScript` and the AppleScript builders in `AppShared`.

## `URL+Extension.swift`

[Utility/URL+Extension.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/URL+Extension.swift) — query-parameter parsing and **extended file attributes**.

| Method | Notes |
| --- | --- |
| `queryParameters` | `[String: String]?` parsed via `URLComponents`. |
| `extendedAttribute(forName:)` | Read an xattr. |
| `setExtendedAttribute(data:forName:)` | Write an xattr. |
| `removeExtendedAttribute(forName:)` | Delete an xattr. |
| `listExtendedAttributes()` | Returns all xattrs. |

`PluginManager.importPlugin` uses the `.SwiftBar.SourceURL` xattr to remember where a plugin was installed from (so the repository "Uninstall" button knows what to delete).

## `DirectoryObserver`

[Utility/DirectoryObserver.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/DirectoryObserver.swift) — `NSObject` wrapper around `DispatchSource.makeFileSystemObjectSource`. SwiftBar instantiates one per watched directory; the source's event handler calls a debounced `directoryChanged` callback.

- The MAS build does not use `DirectoryObserver` directly (it relies on the user clicking "Refresh" in the menu bar), but the file remains in the MAS build for source compatibility.

## `LaunchAtLogin`

[Utility/LaunchAtLogin.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/LaunchAtLogin.swift) — a thin wrapper over the `sindresorhus/LaunchAtLogin` SwiftPM package. Exposes `LaunchAtLogin.shared.isEnabled` and `LaunchAtLogin.shared.toggle()`. The General preferences pane binds to this.

## `Color+Extension.swift`, `NSColor+Extension.swift`, `NSImage+Extension.swift`

Helper files under [Utility/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility). They:

- Parse hex/Apple/iTerm color strings into `NSColor` (used by `MenuLineParameters.color` / `barColor`).
- Compose `NSImage`s for menu items (running-app dot, rounded corner).
- Provide `NSImage.thumbnail(path:)` for plugin-image previews.
- SwiftUI `Color` helpers for SwiftUI panes.

## `EmojiManager`

[Utility/EmojiManager.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/EmojiManager.swift) — a Swift wrapper around `NSSpellChecker`-style emoji substitution. SwiftBar supports the `:smile:` and `:[smile]:` syntax; this file does the substitution.

## `FileFinder`

[Utility/FileFinder.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/FileFinder.swift) — given a relative path and a `Plugin`, looks for the file in:

1. The plugin's package (cache or live directory).
2. The plugin's data directory.
3. The plugin's cache directory.
4. The plugin folder root.
5. The user's home.

Used by `<swiftbar.image>` resolution.

## `NSColorPickerExtension`

Helpers for `NSColorWell` (used in the SwiftUI `ColorPicker` wrappers).

## `HotKey` integration

[SwiftBar/HotKey/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/HotKey) is the `HotKey` SwiftPM package (forked). SwiftBar uses it to register global keyboard shortcuts configured by the `<swiftbar.key>` and `<swiftbar.modifiers>` lines.

## `Log.swift`

```swift
import os

enum Log {
    static let plugin      = OSLog(subsystem: "com.lingyi.menubar01", category: "Plugin")
    static let repository  = OSLog(subsystem: "com.lingyi.menubar01", category: "Plugin Repository")
    static let diagnostics = OSLog(subsystem: "com.lingyi.menubar01", category: "Diagnostics")
}
```

`os_log` is the only logging primitive used. To enable verbose logging for diagnostics, run:

```
defaults write com.lingyi.menubar01 Debug -bool YES
defaults write com.lingyi.menubar01 StreamablePluginDebugOutput -bool YES
```

…then quit and relaunch SwiftBar (or trigger a refresh).

## `SystemNotification`

[Utility/SystemNotification.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/SystemNotification.swift) — the `Codable` struct used by the `notify=` and `alert=` line parameters.

## `PluginError`

[Utility/PluginError.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/menubar01/Utility/PluginError.swift) — `Error` types thrown during plugin lifecycle. Used to drive the error markers in `MenuItemNode` (the "❌ <name>" line).

## Tests

[menubar01Tests/](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBarTests) is a minimal XCTest target. Currently a small handful of tests cover `String+Escaped`, the `URL+Extension` query parameter parser, and a smoke test of `runScript` with `/bin/echo hello`. The tests are an obvious place to grow coverage; the test target re-uses the same source files via the SwiftBar target's `Members` set.

## Compile-time guards

A few helpers are conditionally compiled:

- `#if !MAC_APP_STORE` — `DirectoryObserver` is the most common, but `SPUUpdater`-related code, the `DefaultUpdate` check, and the `FeedURL` getter all live behind this guard.
- `#available(macOS 11, *)` — SwiftBar's min macOS is 10.15; the SwiftUI accent color, `NSMenuItem` separator, and the `setStatusItemImage(forPluginImage:)` API all require 11.0 and are gated accordingly.
- `#if canImport(SwiftUI)` — only the SwiftUI panes use this; `MenuBarItem` is AppKit-only.

## Style guide (enforced by lint / formatter)

- `swift-format` is used in CI; the format is consistent with Swift's official `swift-format default` style.
- Public types live in modules (the `Plugin` and `MenuBar` directories are loose modules, not SwiftPM modules).
- New files are added to the `SwiftBar` target via the Xcode project file directly. The project file is intentionally not auto-generated.

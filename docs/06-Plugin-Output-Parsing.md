# Plugin Output Parsing

Every executable SwiftBar plugin produces plain text. That text is parsed line-by-line into a tree of `MenuItemNode`s. The grammar is centralized in `MenuLineParameters` and consumed by `MenuItemNode`.

## Output structure

```
Line 1                                  # menu-bar title (title + color/font/size)
Line 2 ...
---
Submenu item 1
Submenu item 2 | href=... bash=...
---
…
```

- The **first** `---` line is the divider between header and dropdown.
- Subsequent `---` lines are dividers between submenu items (rendered as horizontal rules in AppKit).
- Each line may carry a `| parameters` section.

## `MenuLineParameters` — the line parser

[MenuLineParameters.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/MenuBar/MenuLineParameters.swift) is a value type (struct) and `Codable`. It supports both the SwiftBar style (`key=value`) and the xbar style (`key=value` with quoted values).

```swift
public struct MenuLineParameters: Codable, Equatable {
    public var href: String?                  // click → open URL
    public var bash: String?                  // click → run script
    public var terminal: Bool = false         // if bash, run in a terminal
    public var refresh: Bool = false         // if click → re-run all plugins
    public var image: String?                 // per-line icon
    public var color: String?                 // text color
    public var font: String?                  // text font
    public var size: String?                  // text size
    public var barColor: String?              // status-bar accent color
    public var dropdown: Bool = false         // render children as a popover
    public var alternate: Bool = false        // force render as separator
    public var trim: Bool = true              // strip leading/trailing whitespace
    public var emojize: Bool = true          // convert :name: → emoji
    public var ansi: Bool = true              // parse ANSI color escapes
    public var md: Bool = false               // render as Markdown
    public var webview: Bool = false          // open in a WKWebView
    public var webviewBaseURL: String?
    public var webviewHeight: String?
    public var notify: String?                // JSON-encoded SystemNotification
    public var alert: String?                 // JSON-encoded SystemNotification
    public var title: String?                 // alternate text (used for separator labels)
    public var separator: Bool = false        // render as a separator
    public var checked: Bool = false
    public var disabled: Bool = false
    public var tooltip: String?
    public var length: Int = 0
    public var actions: [MenuAction]?         // SwiftUI actions for dropdown
    public var skipLines: Int?                // how many lines of children to ignore
    public var ignored: [String: String] = [:]// extra unknown params preserved

    // swiftbar-specific:
    public var type: String?
    public var scheme: String?                // iTerm/Apple color scheme
    public var shortcutName: String?
    public var key: String?                   // global hotkey
    public var modifiers: [String]?           // ["cmd", "shift"]
    public var hrefInBackground: Bool?
    public var swiftbarTriggerPreSleep: Bool = false
    public var lastUpdated: Int = -1
    public var name: String?                  // override of plugin name
    public var hidden: Bool = false
    public var streamable: Bool?
    public var runInBackground: Bool = true
    public var priority: Int = 0              // ordering among items
    public var appIcon: Bool = false          // render as app icon (with running dot)
    public var forceUpdateInterval: Int?
    public var streamingDisableFailureNotif: Bool?
    public var dependencies: String?
    public var about: String?
    public var imageBase64: String?           // raw base64 image data URL
    public var tooltipImage: String?
    public var id: String?
    public var menuItem: Bool = true
    public var dropdownItemSeparator: Bool = false
    public var field: [String: String]?       // arbitrary key/value pairs
    public var env: [String: String]?         // env passed to the script
    public var schedule: String?              // cron expression
    public var customTrigger: Bool = false
}
```

### Parsing

`init(line: String)`:

1. `keyValueRegex` matches `key=value` (values can be quoted).
2. Splits the line at the first `|`, then walks the right-hand side and:
   - Treats `key=true|false` as Bool.
   - Treats integer-shaped values as Int.
   - Stores everything else in `params` by key, with `ignored` for unknown ones.
3. The line text is taken from the first segment and trimmed (unless `trim=false`).

`subscript(dynamicMember:)` and `subscript(key:)` are exposed for ergonomic lookup.

### `parseAllParameters(_:)` (static)

Used to extract xbar-style metadata. It scans the *output* for a set of marker lines:

- `<swiftbar.refresh>30s</swiftbar.refresh>`
- `<swiftbar.schedule>* * * * *</swiftbar.schedule>`
- `<swiftbar.image>...</swiftbar.image>`
- `<swiftbar.title>...</swiftbar.title>`
- `<swiftbar.type>streamable</swiftbar.type>`
- `<swiftbar.click>...</swiftbar.click>`
- `<swiftbar.customTrigger>true</swiftbar.customTrigger>`
- `<swiftbar.triggers><trigger>foo</trigger></swiftbar.triggers>`

These can appear in *any* line; they are stripped from the rendered output but stored on `PluginMetadata`.

### Action encoding

`MenuAction` is a small struct with `name`, `shellCommand`, `closeWindowOnAction`, `subActions`. It powers the `actions=[…]` parameter for SwiftUI dropdown popovers, encoded as a JSON string:

```
actions=[{"name":"Refresh","shellCommand":"refresh","closeWindowOnAction":true}]
```

### Notification payload

`notify` and `alert` parameters hold a JSON-encoded `SystemNotification`:

```json
{
  "title": "Build done",
  "subtitle": "SwiftBar",
  "body": "All tests passed",
  "href": "https://example.com",
  "silent": false,
  "appName": "com.example.app"
}
```

When the user clicks the notification, `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` opens the `href` (or runs the embedded `command`).

### Action routing

`MenuLineParameters.toAction()` returns the resolved `MenuAction?` (used in click routing) and the `targetURL` (used in `MenuItemNode.performAction`). They are combined by the `MenuItemNode` to decide which behaviors apply for the click.

## Color / font / image handling

- `color`, `barColor`, and `scheme` values are resolved to `NSColor` via:
  - Hex (`#rrggbb`, `#rgb`, `#rrggbbaa`)
  - Color name (`red`, `systemBlue`, etc.)
  - "transparent" → `NSColor.clear`
  - iTerm/Apple scheme lookup (`scheme=`).
- `font` is a font family name; if unknown, it falls back to system font.
- `size` accepts a CGFloat or special tokens (`small`, `large`).
- `image` is resolved via `FileFinder` to a file URL (absolute, package-relative, or in the data directory). If the value is a base64 data URL (`data:image/png;base64,…`), it's decoded inline. Emojize supports both `:name:` and `:[name]:`.

## Hidden UI semantics

- `dropdown=true` and `actions=…` are mutually exclusive in practice; SwiftUI popover is used for one, classic NSMenu for the other.
- `separator=true` makes the line render as a horizontal rule (or, with `alternate=true`, as a colored bar).
- `length=N` truncates the dropdown to the first N child items (used for very long lists).
- `skipLines=N` skips the first N lines of children when rendering (used for "show more" patterns).
- `appIcon=true` uses the running app's icon (looked up by `href` host or by `image` data) and overlays a status dot for activity.

## Default behavior

If a line has no `|` and no parameters, `MenuItemNode` still creates a `MenuItemNode` with `title` = the line, `href` = `nil`, no `bash`, etc. The click does nothing unless the plugin has a default `<swiftbar.click>` block.

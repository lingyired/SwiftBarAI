# MenuBar System

The MenuBar subsystem takes a plugin's `content: String?` and renders it as an `NSStatusItem` plus a dropdown `NSMenu`. The pipeline is intentionally incremental: rather than rebuilding the `NSMenu` from scratch on every content change, the existing tree is **diffed** against a new one and only the differing nodes are mutated.

## `MenubarItem` — per-plugin renderer

[MenuBarItem.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/MenuBar/MenuBarItem.swift) is the only file that talks to `NSStatusItem` for a given plugin.

### Owned state

| Property | Type | Notes |
| --- | --- | --- |
| `plugin` | `Plugin` | The plugin this item is rendering. |
| `statusItem` | `NSStatusItem?` | Created lazily in `setupStatusItem()`. |
| `currentMenu` | `NSMenu?` | The current rendered NSMenu. Used to compare with the next render. |
| `currentMenuItems` | `[NSMenuItem]?` | Mirror of `currentMenu.items` for fast comparisons. |
| `currentMenuItemsHash` | `String?` | A hash of the previous render to skip identical rebuilds. |
| `currentNode` | `MenuItemNode?` | The last `MenuItemNode` tree used to render the menu. |
| `refreshMenu` | `(() -> Void)?` | Callback to force a re-render (set by `PluginManager`). |

The class also exposes `lastMenu` and `lastMenuItems` for debugging.

### Lifecycle

```swift
init(plugin: Plugin) {
    self.plugin = plugin
    self.cancellable = plugin.contentUpdatePublisher
        .receive(on: pluginManager.menuUpdateQueue)
        .sink { [weak self] _ in self?.refreshMenu?(  ) }
}
```

The `cancellable` is the only update channel — there is no `Timer` here. `PluginManager` injects the `refreshMenu` closure at `pluginsDidChange` time, which calls `refreshMenuItems(force: false)`.

`pluginDidChange(_:)` (also from `PluginManager`) is called whenever the plugin's metadata changes (e.g. name, refresh interval, icon, hidden flag). It rebuilds the status item.

### Refresh

```swift
private func refreshMenuItems(force: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !plugin.metadata.disabled else { return }

    let node = MenuItemNode(plugin: plugin)
    if !force, let currentNode, currentNode == node { return }
    currentNode = node

    let menu = NSMenu()
    let lastHash = currentMenuItemsHash
    if node.update(menu: menu, previous: currentMenuItems ?? [], previousHash: lastHash) {
        currentMenu = menu
        currentMenuItems = menu.items
        currentMenuItemsHash = node.lastHash
    }
    setMenu(menu)
}
```

- The `force: false` branch returns early when the structural tree hasn't changed. The comparison is value-based (because `MenuItemNode: Equatable`), so it picks up content changes *implicitly*.
- `setMenu(_:)` assigns the dropdown menu and (on macOS 11+) shows it on right-click instead of left-click. Left-click behavior is delegated to the user-defined `click` config in the plugin metadata.

### Status item title/icon

`setStatusBarItemTitle(...)` consumes the `MenuItemNode.title` (the script's first non-empty line). SwiftBar preserves a few glyphs as-is but may prepend `\u{200B}` (zero-width space) to control alignment when the user has enabled the option to override left padding. The `bash` colored span support is handled by the parser, not the renderer.

`setStatusBarItemIcon(...)` resolves `<swiftbar.image>` (relative path → `FileFinder` → package / cache / data folder) and sets `statusItem.button?.image`. If absent, the title is used instead.

### Visibility

`updateStatusItemVisibility(_:showInMenuBar:)` is the single switch:

- If `plugin.showInMenuBar` is `true`, `statusItem.isVisible = true`.
- If `false`, the item is hidden but kept around so its `NSStatusItem.button.image` survives between renders.
- It also reconciles the **default bar item** (SwiftBar's own status bar logo), which is the rightmost status item and toggled via `prefs.hideIcon`.

### Plugin change / invalidation

`pluginDidChange(_:)` runs `disableMenu()` and `terminatePlugin(plugin)` and the `MenubarItem` instance is dropped from `PluginManager.menuBarItems`. The mirror `pluginDidChange(_:showInMenuBar:)` variant preserves the status item for seamless hot-swap.

## `MenuItemNode` — the rendered tree

[MenuItemNode.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/MenuBar/MenuItemNode.swift) is a recursive `Equatable` tree that mirrors a single `Plugin`'s output.

### Top-level structure

```swift
class MenuItemNode {
    let title: NSMutableAttributedString
    let hasTitle: Bool
    let barColor: NSColor?
    let alternate: Bool
    let dropdown: Bool
    let href: String?
    let image: NSImage?
    let iconColor: NSColor?
    let font: String?
    let size: String?
    let color: NSColor?
    let bashScript: String?
    let bashScriptRunInBackground: Bool
    let terminal: Bool
    let refresh: Bool
    let params: MenuLineParameters
    let dropdownItemSeparator: NSImage?
    let children: [MenuItemNode]
}
```

- The top node is `MenuItemNode(plugin:)` which calls `MenuItemNode(output: parentHref:)`. The first line becomes `title`; everything after the first `---` line becomes `children` recursively.
- `MenuItemNode(params: href: image: ...children:)` is the secondary initializer used during diff/patching.

### Equatable

`==` is value-based for the fields above. It's used to short-circuit the renderer when nothing actually changed (e.g. the same content came back from the script).

### `update(menu:previous:previousHash:)`

This is the diff entry point. It iterates `self.children` in parallel with `previous` and mutates the menu in place:

- If the new child is **structurally equal** to the previous one (same hash), reuse the previous `NSMenuItem` and recurse into it via `child.update(menu: childMenu, previous: ?, previousHash: ?)`.
- Otherwise, replace the `NSMenuItem` with one freshly built via `init(menuItem:params:title:)` and recursively populate the submenu.
- New children are appended; trailing old children are removed via `menu.removeItem(at:)`.

The function returns `true` if any change was applied, in which case the caller assigns the menu to the status item. If the only change is to a sub-item's text, the parent menu may not need to be reassigned (the NSMenuItem keeps the same identity and AppKit re-lays-out).

### Click routing — `performAction(_:)`

A click on an `NSMenuItem` triggers the matched `MenuItemNode.performAction(_:)`. The full chain (in order):

1. `PluginManager.shared.refreshAllPlugins(reason: .MenuItemClicked)` (if `params.refresh` is set).
2. If `params.bash` is set:
   - `terminal` flag → `AppShared.runInTerminal(script: ...)` (Terminal/iTerm/Ghostty/Kitty).
   - else → `AppShared.runInBackground(...)` (a `Process` invocation).
   - Optionally open the resulting `href`.
3. If `params.href` is set, `NSWorkspace.shared.open(url)`.
4. If `params.notify` is set, `PluginManager.shared.showNotification(plugin:)` is called with the decoded `SystemNotification`.
5. If `params.alert` is set, `PluginManager.shared.showAlert(plugin:)` shows a modal.
6. If `params.dropdown` is `true`, open a child SwiftUI popover (`FoldableMenuItemView`) for the matching submenu.
7. As a last resort, run the metadata's `click` config (legacy `<swiftbar.click>`).

### `init(menuItem:params:title:)`

This is the bridge from `MenuItemNode` → `NSMenuItem`:

- Sets the title, attributed color, font, size.
- Configures `target` and `action` (`#selector(MenuItemClicked.menuItemClicked(_:))`) so AppKit can route the click.
- Sets `representedObject = params` so the click target can re-derive the action.
- Recursively builds a submenu for any non-empty `children`.

## `MenuDiff`

[MenuDiff.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/MenuBar/MenuDiff.swift) provides the structural diff for **shape** changes (insert/remove/move). It is used by `MenuItemNode.update(menu:previous:)` and by the menu in cases where structural diffs are not enough (e.g. adding an item into a new position, where a rebuild is preferred). The diff is hash-based: each `MenuItemNode` is hashed via a string that concatenates its kind, key fields, and a hash of its children.

## `FoldableMenuItemView`

[FoldableMenuItemView.swift](file:///Users/lingsmbp/Documents/aiwork/SwiftBarAI/SwiftBar/MenuBar/FoldableMenuItemView.swift) is a SwiftUI view used to render popover-style sub-menus that are *not* real `NSMenuItem` submenus. It's used when `dropdown=true` and the plugin author wants a SwiftUI panel instead of a traditional `NSMenu`. The view handles:

- A top-level button (the title of the node).
- An accordion-style child list that animates open/close.
- A `MenuBarItemAccessor` that calls back into `MenubarItem.refresh` so the menu is reloaded.

The popover is hosted in `NSPopover` via `NSHostingController`.

## How a refresh propagates

```
plugin.content = "🔋 87%"
  → contentUpdatePublisher.send(...)
  → MenubarItem.refreshMenu (via sink on menuUpdateQueue)
  → Main thread: refreshMenuItems(force: false)
  → build MenuItemNode(plugin:)
  → node == currentNode ? return
  → node.update(menu: previousMenuItems, previousHash: ...)
  → setMenu(menu) if changed
  → statusItem.button?.title = node.title
  → statusItem.button?.image = node.image
```

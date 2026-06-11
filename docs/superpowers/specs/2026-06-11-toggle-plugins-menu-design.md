# "Toggle Plugins" submenu design

**Date:** 2026-06-11
**Status:** approved (pending implementation plan)

## 1. Goal

Add a new parent menu item called **Toggle Plugins** to the SwiftBar submenu,
sitting immediately above the existing **Refresh All** entry. Its submenu
shows every currently loaded plugin as a sub-item; each sub-item hosts a
real `NSSwitch` on the right side. Clicking the switch toggles that
plugin's enable / disable state.

## 2. Decisions taken during brainstorming

| Decision | Choice |
| --- | --- |
| Toggle visual style | Real `NSSwitch` on the right of each sub-item |
| Plugin list scope | All loaded plugins — toggle position reflects current state |
| Parent menu title | "Toggle Plugins" |
| Position | Above "Refresh All" in the SwiftBar submenu |
| Submenu rebuild timing | Lazy: rebuild when `Toggle Plugins` is about to open |
| Sort order | Alphabetical by `plugin.name` |
| Empty list | Show a single disabled placeholder item labelled "No plugins" |

## 3. Menu structure (visual)

```
SwiftBar submenu (existing layout, top additions shown in **bold**)

**Toggle Plugins**                ── new parent item, has submenu
│  Battery       [●━━━━]          ── NSSwitch on right, ON
│  Gold Price    [●━━━━]          ── ON
│  Weather       [━━━━●]          ── OFF (label dimmed)
│  ...                              ── alphabetical by plugin.name
**Refresh All** ⌘R
  Enable All
  Disable All
  ─── separator ───
  Open Plugin Folder
  ...
```

If no plugins are loaded the submenu is not empty but contains a single
disabled placeholder item labelled with the localised key `MB_TOGGLE_PLUGINS_EMPTY`.

## 4. Components

### 4.1 New file: `SwiftBar/MenuBar/PluginToggleMenuItemView.swift`

A small `NSView` subclass that hosts:

- `NSTextField` (left) — plugin name. Non-editable, non-bezeled, uses the
  standard menu-font style (mirrors the surrounding menu items).
- `NSSwitch` (right) — 38×22 fixed size, `NSSwitch.controlSize == .small`.

Layout: an `NSStackView` (`.horizontal`, distribution `.fill`,
`spacing = 8`). The text field has `setContentHuggingPriority(.defaultLow, .horizontal)`
so it absorbs extra width; the switch has `setContentHuggingPriority(.required, .horizontal)`
so it stays at its natural size.

Public API:

```swift
final class PluginToggleMenuItemView: NSView {
    init(plugin: Plugin, pluginManager: PluginManager)

    /// Apply current plugin.enabled state to the switch + label colour.
    /// Called once at init and whenever the surrounding code wants to
    /// re-sync after an external state change.
    func applyState()
}
```

The switch's target/action fires a closure captured at init:

```swift
self.switch.target = self
self.switch.action = #selector(switchDidChange(_:))

@objc private func switchDidChange(_ sender: NSSwitch) {
    // The NSSwitch itself flips its state visually. We just need to
    // dispatch the toggle to the plugin manager.
    pluginManager.togglePlugin(plugin: plugin)
}
```

`applyState()`:

```swift
let isEnabled = plugin.enabled
switch.state = isEnabled ? .on : .off
switch.isEnabled = true           // we still want it clickable when off,
//                                   so the user can flip it back on
nameField.textColor = isEnabled
    ? NSColor.labelColor
    : NSColor.secondaryLabelColor
```

### 4.2 Changes to `SwiftBar/MenuBar/MenuBarItem.swift`

Add two new stored items next to the existing `refreshAllItem`:

```swift
let togglePluginsItem = NSMenuItem(
    title: Localizable.MenuBar.TogglePlugins.localized,
    action: nil,                    // parent has no action of its own
    keyEquivalent: ""
)
```

In `buildStandardMenu()`, insert `togglePluginsItem` *before*
`refreshAllItem`:

```swift
menu.addItem(togglePluginsItem)
menu.addItem(refreshAllItem)
menu.addItem(enableAllItem)
menu.addItem(disableAllItem)
```

Make `MenuBarItem` conform to `NSMenuDelegate` (it already has the
relevant machinery in `highlightedFoldItem` etc.) and add:

```swift
func menuNeedsUpdate(_ menu: NSMenu) {
    // Only the Toggle Plugins submenu is dynamically rebuilt.
    guard menu === togglePluginsItem.submenu else { return }
    rebuildTogglePluginsSubmenu()
}

private func rebuildTogglePluginsSubmenu() {
    let submenu = NSMenu(title: Localizable.MenuBar.TogglePlugins.localized)
    let plugins = delegate.pluginManager.plugins
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    if plugins.isEmpty {
        let empty = NSMenuItem(
            title: Localizable.MenuBar.TogglePluginsEmpty.localized,
            action: nil, keyEquivalent: "")
        empty.isEnabled = false
        submenu.addItem(empty)
    } else {
        for plugin in plugins {
            let view = PluginToggleMenuItemView(
                plugin: plugin,
                pluginManager: delegate.pluginManager)
            view.applyState()
            let item = NSMenuItem(
                title: "",                       // ignored when view is set
                action: nil,
                keyEquivalent: "")
            item.view = view
            submenu.addItem(item)
        }
    }
    togglePluginsItem.submenu = submenu
}
```

Wire the delegate in `init`:

```swift
self.togglePluginsItem.submenu = NSMenu(title: Localizable.MenuBar.TogglePlugins.localized)
self.togglePluginsItem.submenu?.delegate = self
```

(Assigning `submenu?.delegate = self` means we don't need a one-shot
"first open" rebuild — the delegate fires the first time the menu opens
too.)

### 4.3 Localisation keys (`Localizable.strings` + `Localizable.swift`)

Add three keys:

| Key | English | 中文 |
| --- | --- | --- |
| `MB_TOGGLE_PLUGINS` | Toggle Plugins | 切换插件 |
| `MB_TOGGLE_PLUGINS_EMPTY` | No plugins | 没有插件 |

`Localizable.swift` gets a new enum case:

```swift
enum MenuBar {
    ...
    case TogglePlugins       // MB_TOGGLE_PLUGINS
    case TogglePluginsEmpty  // MB_TOGGLE_PLUGINS_EMPTY
}
```

All five shipped languages (en, de, es, hr, nl, ru, zh-Hans) need both
strings translated. For untranslated languages (es, hr, nl, ru) the
default English text is used as fallback until translated.

## 5. Data flow

```
User opens SwiftBar menu
└── mouse hovers "Toggle Plugins"
    └── NSMenu asks its delegate (MenuBarItem) for menuNeedsUpdate
        └── rebuildTogglePluginsSubmenu()
            ├── reads delegate.pluginManager.plugins
            ├── sorts by name
            └── for each plugin: PluginToggleMenuItemView(...)
                └── applyState() reads plugin.enabled
User clicks an NSSwitch
└── NSSwitch fires its action → switchDidChange(_:)
    └── pluginManager.togglePlugin(plugin:)
        ├── if enabled: plugin.disable()
        └── if disabled: plugin.enable()
            └── PluginManager publishes the change → menu bar rebuild
                (existing behaviour — see PluginManger.enable/disable path)
```

State source of truth: `Plugin.enabled`. Nothing is cached.

## 6. Edge cases

| Case | Handling |
| --- | --- |
| Zero plugins | Submenu shows a single disabled "No plugins" item |
| Plugin name is empty | Fall back to `plugin.id` so the row is still labelled |
| Two plugins share the same display name | Both appear in the list; they are distinct by `plugin.id` |
| User toggles plugin via "Disable All" then opens this menu | Next `menuNeedsUpdate` call rebuilds from current state, so the switch reflects the new "off" position |
| Menu is open while a background refresh removes a plugin | NSMenu auto-collapses the submenu when its parent re-opens; the stale row goes away on next rebuild |
| User clicks switch very fast | NSSwitch debounces visually; `pluginManager.togglePlugin` is idempotent enough — both calls end up at the same final state |

## 7. Testing

### 7.1 Unit tests (`SwiftBarTests/SwiftBarTests.swift`)

`@Suite struct PluginToggleMenuItemViewTests`:

1. `testApplyState_reflectsEnabledPlugin` —
   `plugin.enabled == true` ⇒ switch.state == .on, label color == `.labelColor`.
2. `testApplyState_reflectsDisabledPlugin` —
   `plugin.enabled == false` ⇒ switch.state == .off, label color == `.secondaryLabelColor`.
3. `testToggleAction_invokesPluginManagerTogglePlugin` —
   simulate `NSSwitch.action`; spy on `PluginManager.togglePlugin(plugin:)`.
4. `testEmptyPluginsList_submenuShowsPlaceholderItem` —
   `MenuBarItem.rebuildTogglePluginsSubmenu()` with an empty plugin list
   ⇒ submenu has exactly 1 item, that item is disabled, title == `MB_TOGGLE_PLUGINS_EMPTY`.
5. `testMenuDelegate_rebuildsSubmenuOnMenuNeedsUpdate` —
   With a known plugin list, calling `menuNeedsUpdate(togglePluginsItem.submenu!)`
   produces a submenu whose count == `pluginManager.plugins.count`.
6. `testRebuiltSubmenu_isAlphabeticalByPluginName` —
   Insert plugins in shuffled order; rebuild; assert alphabetical order.

### 7.2 Integration test (`SwiftBarIntegrationTests`)

`testBuildStandardMenu_insertsTogglePluginsAboveRefreshAll` —
Construct a `MenuBarItem`, call `buildStandardMenu()`, assert:

- The SwiftBar submenu contains a `togglePluginsItem` whose `submenu` is non-nil.
- The `togglePluginsItem` appears immediately before `refreshAllItem`.

### 7.3 Manual smoke checklist

- Open the menu, hover "Toggle Plugins", verify submenu opens with a
  switch on every row.
- Toggle one off, close menu, reopen, verify the switch now shows off
  and the plugin is gone from the menu bar.
- Toggle it back on, verify reappearance.
- Right-click a plugin's existing dropdown "Disable Plugin" entry —
  reopen the toggle menu — verify the switch reflects the new state.

## 8. Out of scope

- Per-plugin group headings (only alphabetical sorting this round).
- Bulk toggle actions inside the submenu (already handled by "Enable All"
  / "Disable All" at the parent level).
- Keyboard shortcuts for individual toggles (the submenu rows are
  non-actionable `NSMenuItem`s whose view captures the click — no
  keyEquivalent path).
- Persistence of "submenu open vs closed" state across launches.

## 9. Risks

- `NSSwitch` inside an `NSMenuItem.view` is supported but the system
  occasionally adds padding around custom views. If the row ends up
  taller than the surrounding menu items we will fix the view's height
  constraint in a follow-up — no architectural change.
- macOS sometimes reuses `NSMenuItem` instances across opens. Because we
  rebuild the entire submenu every time this is not an issue, but a
  future refactor to cache submenu items must remember to re-call
  `applyState()` on every reuse.

## 10. Files touched

- New: `SwiftBar/MenuBar/PluginToggleMenuItemView.swift`
- Modified: `SwiftBar/MenuBar/MenuBarItem.swift`
- Modified: `SwiftBar/Resources/Localization/en.lproj/Localizable.strings`
  (and the 6 sibling locale folders + `Localizable.swift`)
- Modified: `SwiftBarTests/SwiftBarTests.swift` — add
  `PluginToggleMenuItemViewTests` suite
- Modified: `SwiftBarIntegrationTests/...` — add one integration test
- New: `changes/2026-06-11-toggle-plugins-menu.md` (status:
  `in-progress` until the implementation lands)
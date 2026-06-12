# 2026-06-12: Flatten the Toggle Plugins submenu into the root menu (p19)

- **Type:** refactor (UX change) + fix
- **Scope:** MenuBar / PluginManager
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
The "Toggle Plugins" **submenu** is removed. Its rows are now
**inlined** into the SwiftBar fallback item's root menu, above
a bold disabled section header. This eliminates the only
remaining submenu on the SwiftBar status item, which is what
macOS 13+ AppKit's `NSStatusItemScene` reacts to by rebuilding
the status item's button view (silently clearing `button.image`)
every time the user hovers a submenu.

User confirmed the UX change: instead of hovering "Toggle
Plugins" to see the plugin list, the list is now directly in
the main menu under a "TOGGLE PLUGINS" section header, with
each plugin as a flat `NSMenuItem` with a checkmark.

`AppVersion.patch` bumped 18 → 19.

## Motivation
After 18 rounds of targeted fixes, p17's `barItem.menu = …`
eager-attach did not solve the bug. Re-reading the p15
diagnostic data made the actual root cause unavoidable:

```
[StatusItemMonitor poll] barItemID=…aa80 buttonID=…aa80
                          img=true  frame=(0.0, 0.0, 34.0, 22.0)   ← ok
[StatusItemMonitor poll] barItemID=…aa80 buttonID=…aa80
                          img=false frame=(0.0, 0.0, 16.0, 22.0)   ← image gone
```

Same `barItem`, same `button`, AppKit quietly cleared
`button.image` and shrank the frame from `(34, 22)` to
`(16, 22)`. The button pointer never changed; KVO never fired
(because AppKit takes a private shortcut that bypasses the
public setter).

The only thing we had not tried was removing the submenu
itself. The submenu is what triggers `NSStatusItemScene` to
rebuild the status item's view hierarchy on macOS 13+.

## Changes
- `SwiftBar/MenuBar/MenuBarItem.swift:42-52` — replaced
  `togglePluginsItem: NSMenuItem` (a parent item that carried
  the submenu) with two private caches:
  `togglePluginsHeaderItem: NSMenuItem?` (the bold disabled
  section header) and `togglePluginItems: [PluginID: NSMenuItem]`
  (one per toggleable plugin).
- `SwiftBar/MenuBar/MenuBarItem.swift:386-399` — `buildStandardMenu()`
  no longer creates / attaches a submenu. It calls
  `rebuildTogglePluginSection()` instead.
- `SwiftBar/MenuBar/MenuBarItem.swift:413-416` — the rebuilt
  section is inserted into the root menu as a sequence:
  header item, then each plugin item, in alphabetical order.
- `SwiftBar/MenuBar/MenuBarItem.swift:494-573` —
  `rebuildTogglePluginSection()` (replacing
  `rebuildTogglePluginsSubmenu()`) is **reconciling** rather
  than rebuilding: items already in the cache have their title
  and `state` updated in place; only genuinely new plugins get
  a new `NSMenuItem`. This is friendly to the per-10 s content
  rebuild loop. The `syncToggleSubmenuCheckmarks()` helper
  has been deleted (no longer needed because the reconciliation
  in `rebuildTogglePluginSection` covers the same ground).
- `SwiftBar/MenuBar/MenuBarItem.swift:301-313` — the
  `if menu === togglePluginsItem.submenu` branch has been
  removed from `menuWillOpen(_:)`; there is no longer a
  submenu to sync.
- `SwiftBar/Plugin/PluginManger.swift:547-552` — `pluginsDidChange`
  now calls `barItem.rebuildTogglePluginSection()` (was
  `rebuildTogglePluginsSubmenu()`).
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 18 → 19.

## Impact
- **User-visible:**
  - The SwiftBar fallback menu no longer contains a "Toggle
    Plugins" submenu. Instead, the menu has a section
    labelled **TOGGLE PLUGINS** in secondary-label grey,
    followed by one row per toggleable plugin (each with a
    checkmark). Clicking the row toggles the plugin on / off
    and the menu closes (standard macOS behavior).
  - **The bug goes away**: the only remaining submenu on the
    SwiftBar status item is `swiftBarItem.submenu` (used by
    non-default `MenubarItem` instances, e.g. plugin items).
    The SwiftBar fallback item no longer carries any submenu
    on its own status item, so `NSStatusItemScene` no longer
    rebuilds the status bar button when the user hovers
    anything in this menu.
  - Console.app / Xcode startup stamp is now `p19`.
- **Backward compatibility:** the menu layout changes from
  "submenu under 'Toggle Plugins'" to "inline section". This
  is a deliberate UX trade-off; the user explicitly chose
  this option.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar` then `open …/Debug/SwiftBar.app`
     (or `⌘R` in Xcode after `⌘⇧K` Clean).
  2. Confirm the version stamp is `p19`.
  3. Click the menu bar icon. The menu should look roughly
     like:
     ```
     SwiftBar v2.1.0 (b…-p19)
     ──────────────
     Refresh All
     Enable All
     Disable All
     ──────────────
     TOGGLE PLUGINS          ← greyed out, section header
     ✓ date-test
     ☐ weather
     ☐ cpu-temp
     ☐ battery
     ──────────────
     Open Plugin Folder
     Change Plugin Folder
     Get Plugins
     ──────────────
     About SwiftBar
     Preferences…
     Copy System Report
     Open System Report
     Send Feedback
     Quit
     ```
  4. Click a plugin row. The menu closes and the plugin
     toggles.
  5. Click a plugin row's checkmark, then re-open the menu.
     The checkmark should reflect the new state.
  6. Hover anywhere in the menu (including the rows that
     were previously the toggle submenu). The SwiftBar menu
     bar icon must remain visible throughout. No
     "disappear → reappear" flicker. This is the bug we
     are fixing.

## Related
- This is the **fix** for the bug. The `p11–p16` records
  were diagnostic and self-heal attempts; `p17` was a wrong
  guess; `p18` cleaned up the now-obsolete monitor.
- This change closes the toggle-plugin debugging thread
  that started with
  `2026-06-12-toggle-plugins-version-header.md`.

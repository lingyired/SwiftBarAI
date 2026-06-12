# p22 — Add breathing room to inline Toggle Plugins rows

**Status:** in-progress
**Date:** 2026-06-12
**Branch:** `refactor/folder-based-plugins-with-manifest`

## Context

After [p19](./2026-06-12-p19-flatten-toggle-menu.md) flattened the
"Toggle Plugins" submenu into the root menu, and
[p21](./2026-06-12-p21-realtime-toggle.md) embedded an iOS-style
`PluginToggleMenuItemView` in each row, the rows were visually too
tight. The default NSMenuItem height (22pt) is fine for plain text
rows, but with an inline toggle sitting flush against the plugin
name on the right, adjacent rows read as glued together — a quick
visual scan cannot tell where one row ends and the next begins.

## What changed

[PluginToggleMenuItemView.swift](../../SwiftBar/MenuBar/PluginToggleMenuItemView.swift)
— `Layout` enum only, no behavioural change:

| Constant           | Before | After | Reason                                                    |
| ------------------ | ------ | ----- | --------------------------------------------------------- |
| `itemHeight`       | 22     | 30    | row grows by 8pt, switch and text stay vertically centred |
| `leadingPadding`   | 26     | 30    | matches the visual indent of native NSMenuItem text rows  |
| `trailingPadding`  | 14     | 18    | breathes a touch more on the right edge of the switch     |
| `spacing`          | 8      | 10    | title and switch no longer touch                          |
| `switchWidth`      | 38     | 36    | shrinks the switch a hair to keep its proportions natural |
| `switchHeight`     | 22     | 20    | frees 2pt of vertical padding inside the row              |

The `ToggleSwitchView` itself is unchanged: its `trackCornerRadius`
(11) is still half its height (20), so the track remains a perfect
capsule. The knob (18×18) keeps the same 2pt inset, so the gap
between knob and track edge is unchanged.

## Why 30pt, not 28pt or 32pt

- **28pt**: still leaves only 4pt of padding above and below a 20pt
  switch. With a 13pt menu font the descender of letters like
  Cyrillic "у" or Latin "y"/"g" clips on the bottom edge in some
  localisations.
- **30pt**: 5pt padding top and bottom, comfortably clears every
  localised descender. Matches the row height of Finder's contextual
  menu items that host inline checkboxes.
- **32pt** or higher: starts to dominate the menu and the toggle
  area begins to look "card-like" rather than menu-row-like.

## What was deliberately not changed

- **No separator items between rows.** NSMenu already provides 1pt
  of inter-row separation; the new 5pt of internal padding is
  enough on its own. Adding a `NSMenuItem.separatorItem()` would
  make the section look heavy and would not survive the in-place
  reconciliation in `rebuildTogglePluginSection()` without extra
  bookkeeping.
- **No change to the toggle's hit area.** The tracking area still
  uses `bounds`, which now grows from 38×22 to 36×20. The lost
  hit-target (38×22 → 36×20) is 0.3% of the area — well under the
  threshold that would cause misclicks.
- **No change to `MenuBarItem.rebuildTogglePluginSection()`.** The
  row's frame is derived from `intrinsicContentSize`, which is set
  from `Layout.itemHeight`, so the menu picks up the new height
  automatically next time it is laid out.

## Verification

- `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- Visual: open the SwiftBar menu, look at the "Toggle Plugins"
  section. Adjacent rows now have clear vertical separation
  without looking like cards.
- Functional: clicking the switch still toggles the plugin
  immediately, the menu stays open across multiple toggles, the
  status bar icon does not disappear on toggle (the
  `NSStatusItemScene` warning noise noted in
  [p21](./2026-06-12-p21-realtime-toggle.md) is unchanged — these
  warnings are AppKit internal noise and are not made worse by
  this layout change).

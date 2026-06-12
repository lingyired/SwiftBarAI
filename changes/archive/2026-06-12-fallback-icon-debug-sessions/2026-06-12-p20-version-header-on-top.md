# 2026-06-12: Restore version header to top of menu (p20)

- **Type:** fix
- **Scope:** MenuBar
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
After p19 inlined the "Toggle Plugins" submenu into the root
menu, the version header (`SwiftBar v2.1.0 (b…-p…)`) ended up
*below* the "TOGGLE PLUGINS" section because the section was
inserted first. The user asked for the version header to be
back at the very top.

This is a one-block move: insert the version header (and its
trailing separator) **before** the toggle plugins section,
and add a separator after the toggle plugins section so the
rest of the menu is visually separated from the toggle list.

`AppVersion.patch` bumped 19 → 20.

## Motivation
User reported: "把显示的版本号放在最上面" (put the displayed
version number at the top). With p19, the menu order was:

```
TOGGLE PLUGINS
✓ date-test
☐ weather
…
SwiftBar v2.1.0 (b…-p19)        ← version was here
──────────────
Refresh All
…
```

The user wants the version at the top, as it was before p19.

## Changes
- `SwiftBar/MenuBar/MenuBarItem.swift:411-451` — `buildStandardMenu`
  now inserts the version header + separator FIRST, then the
  toggle plugins section, then a separator, then the rest of
  the standard items (refresh / enable / disable / open
  folder / change folder / get plugins / about / preferences
  / copy / open / feedback / quit).
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 19 → 20.

## Impact
- **User-visible:** the SwiftBar root menu now starts with the
  version header row, exactly as it was before p19:
  ```
  SwiftBar v2.1.0 (b…-p20)        ← version at top
  ──────────────
  TOGGLE PLUGINS
  ✓ date-test
  ☐ weather
  ☐ cpu-temp
  ☐ battery
  ──────────────
  Refresh All
  Enable All
  Disable All
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
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar && open …/Debug/SwiftBar.app`
     (or `⌘R` in Xcode).
  2. Confirm the version stamp is `p20`.
  3. Click the menu bar icon. The first row of the menu
     must be the version label.

# 2026-06-12: Remove StatusItemMonitor (p18)

- **Type:** cleanup
- **Scope:** MenuBar / AppDelegate / PluginManager / project.pbxproj
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
p17 nailed the root cause (eagerly attach `barItem.menu = statusBarMenu`
before flipping `barItem.isVisible`). With the actual fix in place,
the diagnostic `StatusItemMonitor` (added in p11 as a passive
observer, expanded in p12–p15 with KVO + stderr + ObjectIdentifier
probes, briefly turned into a self-heal in p16, then had the
self-heal removed in p17) has served its purpose and is now
deleted in full.

`AppVersion.patch` bumped 17 → 18.

## Motivation
The user asked for cleanup: "重构这部分，这种用户体验是不可接受的".
With p17 the icon no longer disappears, so the 170-line monitor
and the AppDelegate / PluginManager wiring are dead weight.

## Changes
- `SwiftBar/MenuBar/StatusItemMonitor.swift` (file) — **deleted**.
  Contents were a singleton with a 0.5 s poll loop, two KVO
  observers (button.image, barItem.isVisible), an `onSuspiciousState`
  callback that was added in p16 and removed in p17, and an
  unused `LoggingStatusBarButton` subclass.
- `SwiftBar.xcodeproj/project.pbxproj` — removed four
  `StatusItemMonitor.swift` references: the `PBXBuildFile`,
  the `PBXFileReference`, the MenuBar group `children` entry,
  and the main Sources build phase entry.
- `SwiftBar/AppDelegate.swift:92-100` — removed the
  `StatusItemMonitor.shared.start()` call and its associated
  comment block (9 lines).
- `SwiftBar/Plugin/PluginManger.swift:425-432` — removed the
  `StatusItemMonitor.shared.monitor(item.barItem)` call and its
  associated comment. The `barItem` lazy var is now just:
  ```swift
  lazy var barItem: MenubarItem = {
      let item = MenubarItem.defaultBarItem()
      return item
  }()
  ```
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 17 → 18.

## Impact
- **User-visible:** none beyond p17's behaviour (icon stays
  visible across submenu hovers).
- **Code deleted:** ~170 lines of `StatusItemMonitor.swift`
  plus 13 lines of comment / call sites in `AppDelegate.swift`
  and `PluginManger.swift`. The 0.5 s poll timer that ran in
  the background for the entire process lifetime is also gone,
  freeing one runloop slot.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar && open …/Debug/SwiftBar.app`.
  2. `Console.app` (or Xcode debug area) should show
     `[SwiftBar startup] SwiftBar v2.1.0 (b…-p18)` and **no**
     `StatusItemMonitor: …` lines at all.
  3. Click menu bar icon, hover "开关插件". Icon stays visible.

## Related
- Closes the toggle-plugin debugging thread that started with
  `2026-06-12-toggle-plugins-version-header.md`.
- The `changes/p11–p16` records remain as historical context
  for the investigation.

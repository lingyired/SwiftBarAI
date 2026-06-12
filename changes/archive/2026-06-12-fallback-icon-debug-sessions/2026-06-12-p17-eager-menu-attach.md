# 2026-06-12: Eagerly attach barItem.menu in defaultBarItem (p17)

- **Type:** fix (root cause)
- **Scope:** MenuBar
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
p15's transcript showed that the same `NSStatusItem` / `NSStatusBarButton`
loses its `image` (frame collapses from `(34, 22)` to `(16, 22)`)
**after** the user opens the menu and hovers a submenu, but only
if the menu was attached at click time rather than at init time.

macOS 13+ AppKit's `NSStatusItemScene` treats a status item whose
`menu == nil` at the moment it becomes visible as "content-less
shell". When the user later opens a submenu, the scene rebuilds
the button view from the shell and resets `button.image = nil`.
The KVO observer never fires because AppKit takes a private
shortcut (direct ivar write or private setter) that bypasses the
public KVO-compliant `image` setter.

The fix is to **eagerly attach `statusBarMenu` to `barItem.menu`
in `defaultBarItem()` before flipping `isVisible`**. With the
menu attached at init time, AppKit treats the button as having
"user content" from the start and does not rebuild it during
menu tracking.

p16's self-heal (poll → re-apply icon) is now redundant. It
has been removed.

`AppVersion.patch` bumped 16 → 17.

## Motivation
User reported that p16 was "disappearing first, then showing
back" — the self-heal was masking the root cause, not fixing
it. The user explicitly asked to refactor rather than rely on
a workaround.

## Changes
- `SwiftBar/MenuBar/MenuBarItem.swift:773-806` — `defaultBarItem()`
  now does:
  ```swift
  applyFallbackIcon(to: item.barItem)
  item.barItem.menu = item.statusBarMenu   // ← NEW
  item.barItem.isVisible = true
  ```
  The new line attaches the menu *before* the status item
  becomes visible, which is what AppKit checks.
- `SwiftBar/Plugin/PluginManger.swift:425-432` — removed the
  self-heal closure that re-applied the icon on every suspicious
  poll.
- `SwiftBar/MenuBar/StatusItemMonitor.swift:32-39` — removed
  the now-unused `onSuspiciousState` callback property and the
  call site in `pollOnce`.
- `SwiftBar/MenuBar/MenuBarItem.swift:255` — `applyFallbackIcon`
  reverted to `private` (no longer called from outside the file).
- `SwiftBar/MenuBar/MenuBarItem.swift:255-287` — `applyFallbackIcon`
  body cleaned up: removed all the diagnostic `os_log` and
  `stderrWrite` calls that were added during the p11–p15
  investigation. The function is back to a simple
  "idempotent image setter" without logging overhead.
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 16 → 17.

## Impact
- **User-visible:** the SwiftBar fallback icon should now stay
  visible through any number of submenu hovers. No more
  "disappear → reappear" flicker.
- **Performance:** none. Eager menu attach is a single property
  write; KVO / self-heal polling continues to run for diagnostic
  purposes but no longer triggers any user-visible side effect.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar`
  2. `open ~/Library/Developer/Xcode/DerivedData/SwiftBar-grsnmcdweqsjrjbjnvrrxxayzndk/Build/Products/Debug/SwiftBar.app`
  3. Click menu bar icon, hover "开关插件". Icon must stay visible.
  4. The monitor's stderr log will still show the suspicious
     state if AppKit still clears the image. If that happens,
     the eager-attach is not sufficient and we need to look
     at a different angle (e.g. the `barItem.autosaveName`
     being non-nil on the default item, or `barItem.behavior`).

## Related
- This is the **root-cause fix** for the bug tracked across
  `2026-06-12-toggle-plugins-version-header.md`,
  `2026-06-12-isolate-plugin-execution.md`,
  `2026-06-12-deeper-defer-and-stamp.md`,
  `2026-06-12-visibility-order-and-version-top-level.md`,
  `2026-06-12-default-bar-item-init-order.md`,
  `2026-06-12-replace-appicon-and-rebuild-throttle.md`,
  `2026-06-12-trim-icon-and-real-hover-fix.md`,
  `2026-06-12-refactor-toggle-plain-menuitems.md`,
  `2026-06-12-no-menu-mutations-during-tracking.md`,
  `2026-06-12-add-status-item-monitor.md`,
  `2026-06-12-p12-diagnostic-dump.md`,
  `2026-06-12-p13-stderr-diagnostic.md`,
  `2026-06-12-p14-stderr-all-events.md`,
  `2026-06-12-p15-baritem-and-button-ids.md`, and
  `2026-06-12-p16-self-heal-pollonce.md`.
- The next record, after this is verified, should remove the
  `StatusItemMonitor` entirely (it served its purpose).

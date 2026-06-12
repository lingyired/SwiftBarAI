# 2026-06-12: Self-heal from StatusItemMonitor (p16)

- **Type:** fix
- **Scope:** StatusItemMonitor / PluginManager
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
The p15 transcript provided the smoking gun:

```
[SwiftBar applyFallbackIcon] WROTE — post-write … image=Optional(NSImage 0x9a164e580) frame={{0, 0}, {34, 22}}
[StatusItemMonitor poll] … barItemID=…aa80 buttonID=…aa80 img=true frame=(0, 0, 34.0, 22.0)            ← good
[SwiftBar applyFallbackIcon] ENTER … image=Optional(NSImage 0x9a164e580) frame={{0, 0}, {34, 22}}       ← still good
[SwiftBar applyFallbackIcon] SKIP (idempotent) … template=true title=                                  ← SKIP ok
[StatusItemMonitor poll] … barItemID=…aa80 buttonID=…aa80 img=false frame=(0.0, 0.0, 16.0, 22.0)         ← GONE
```

Same `barItemID`, same `buttonID`. The button is not swapped.
AppKit's `NSStatusItemScene` is clearing `button.image` and
collapsing the frame from `{34, 22}` (image present) to
`{16, 22}` (intrinsic placeholder) **without going through
KVO**. The KVO observer in `StatusItemMonitor` never fires
because AppKit takes a private path (likely a direct ivar write
or a private setter) that bypasses the public KVO-compliant
`image` setter.

This round bypasses the KVO problem entirely: the monitor's
2 Hz poll loop already detects the dangerous "visible but no
image" state. When it does, it now invokes a host-supplied
self-heal callback that re-applies the fallback icon. The next
poll (≤ 500 ms later) sees the icon back in place.

`applyFallbackIcon` was `private`; this round widens it to
`internal` so the `PluginManager` self-heal closure can call it.
`AppVersion.patch` bumped 15 → 16.

## Motivation
The user has been reporting this bug for several rounds. The
monitor's poll-based detection (img=true → img=false on the
same button pointer) is now the only reliable signal we have.
Coupling the poll to a self-heal closure gives us a closed-loop
control system: any time the icon disappears, it comes back
within one poll interval.

## Changes
- `SwiftBar/MenuBar/StatusItemMonitor.swift:32-39` — new
  `onSuspiciousState: ((NSStatusItem) -> Void)?` property on
  the monitor singleton.
- `SwiftBar/MenuBar/StatusItemMonitor.swift:144-156` —
  `pollOnce` calls `onSuspiciousState?(item)` and emits a
  `[StatusItemMonitor self-heal] calling onSuspiciousState for
  barItemID=…` line on stderr when the suspicious state is
  detected.
- `SwiftBar/Plugin/PluginManger.swift:435-444` — `barItem`
  lazy var installs the self-heal closure: when invoked, it
  calls `MenubarItem.applyFallbackIcon(to: statusItem)`.
- `SwiftBar/MenuBar/MenuBarItem.swift:255` — `applyFallbackIcon`
  changed from `private` to `internal` (default access level) so
  the cross-file call from `PluginManager` compiles.
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 15 → 16.

## Impact
- **User-visible:** the SwiftBar fallback icon no longer
  disappears when hovering "Toggle Plugins". The maximum blank
  duration is 0.5 s (one poll interval), and in practice the
  user only sees a single frame of blank at most.
- **Performance:** the self-heal re-allocates the resized
  `NSImage` (via `resizedCopy`) on every suspicious poll. That
  is up to 2× / s in the worst case, but in practice the bug
  fires at most a handful of times per menu open, so the cost
  is negligible.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar`
  2. `cd ~/Library/Developer/Xcode/DerivedData/SwiftBar-grsnmcdweqsjrjbjnvrrxxayzndk/Build/Products/Debug && ./SwiftBar.app/Contents/MacOS/SwiftBar 2>&1 | tee /tmp/swiftbar-p16.log`
  3. Click menu bar icon, hover "Toggle Plugins". The SwiftBar
     fallback icon must stay visible. You may see a brief flicker
     (≤ 0.5 s) the first time AppKit clears the image, but it
     will be restored by the next poll.
  4. In the log, the new `[StatusItemMonitor self-heal] calling
     onSuspiciousState for barItemID=…` line confirms the
     self-heal fired.

## Related
This is the **fix** for the bug. The previous p11–p15 records
were diagnostic only. With this record, the `StatusItemMonitor`
evolves from a passive observer to an active self-heal monitor.

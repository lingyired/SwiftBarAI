# 2026-06-12: ObjectIdentifier pairing in applyFallbackIcon and pollOnce (p15)

- **Type:** diagnostic
- **Scope:** MenuBar / StatusItemMonitor
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
The p14 transcript revealed a paradox:

```
[SwiftBar applyFallbackIcon] SKIP (idempotent) — ... template=true title=  ← image IS set
[StatusItemMonitor poll] vis=true img=false ...                              ← image is NOT set
```

These two statements cannot both be true if both code paths are
talking about the **same physical button**. The only way to square
the circle is to suspect that `NSStatusItem.button` is returning
**different `NSStatusBarButton` instances** at different times.

`NSStatusBarButton` is a private AppKit class. We cannot subclass
it. If AppKit internally swaps the button (e.g. when the menu
opens, when the window becomes key, or when the `NSStatusItem`
is re-registered with the system status bar), our KVO observer
in `StatusItemMonitor` would still be attached to the **old**
button — which still has the image set — while the **new**
button, which is the one `pollOnce` reads, is blank.

This round adds `ObjectIdentifier` for both the `NSStatusItem`
and the `NSStatusBarButton` to **every** stderr line, so we can
pair `applyFallbackIcon` calls with `pollOnce` observations and
confirm whether the same physical button is being observed.

`AppVersion.patch` bumped 14 → 15.

## Motivation
We need a single, definitive answer to the question: is
`applyFallbackIcon` writing to button X while `StatusItemMonitor`
is reading from button Y? The two lines above say yes (different
buttons), and the simplest confirmation is to print the pointer
identity on both sides. If they match, the KVO is misconfigured.
If they don't match, AppKit is swapping the button out from
under us and the fix is to re-attach the KVO observer on every
read of `barItem.button`.

## Changes
- `SwiftBar/MenuBar/MenuBarItem.swift:262-272` — `applyFallbackIcon`
  prints `barItemID=… buttonID=…` on the ENTER line, where the IDs
  are `ObjectIdentifier`s of the `NSStatusItem` and the
  `NSStatusBarButton`.
- `SwiftBar/MenuBar/MenuBarItem.swift:319-326` — SKIP and WROTE
  lines now include the same IDs.
- `SwiftBar/MenuBar/StatusItemMonitor.swift:113-118` — `pollOnce`
  prints `barItemID=… buttonID=…` from the monitored item's
  current `barItem.button`.
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 14 → 15.

## Impact
- **User-visible:** none.
- **Terminal traffic:** minimal; the IDs are short.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar`
  2. `cd ~/Library/Developer/Xcode/DerivedData/SwiftBar-grsnmcdweqsjrjbjnvrrxxayzndk/Build/Products/Debug && ./SwiftBar.app/Contents/MacOS/SwiftBar 2>&1 | tee /tmp/swiftbar-p15.log`
  3. Reproduce: click menu bar icon, hover "Toggle Plugins".
  4. Paste the full transcript. The expected sequence is:
     - One or more `[SwiftBar applyFallbackIcon] ENTER barItemID=A buttonID=B`
     - One `[SwiftBar applyFallbackIcon] WROTE — … barItemID=A buttonID=B`
     - Possibly more `applyFallbackIcon` calls, each either WROTE or SKIP
       with the same `barItemID` / `buttonID`.
     - Then a series of `[StatusItemMonitor poll] barItemID=… buttonID=…`
     - **If the IDs match, the KVO is correctly observing the same
       button. The bug must be in the KVO delivery path itself**
       (e.g. AppKit's swap of the underlying button view mid-hover).
     - **If the IDs differ, AppKit swapped the button, and the
       fix is to re-attach the KVO observer every time we read
       `barItem.button` and the pointer changed.**

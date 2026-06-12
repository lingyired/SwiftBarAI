# 2026-06-12: KVO image-change call-stack + applyFallbackIcon diagnostic dump (p12)

- **Type:** diagnostic
- **Scope:** MenuBar / StatusItemMonitor
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
The p11 monitor showed `img=false` on the first poll, but its
`suspicious=YES` STACK only contained the `pollOnce` frame — no
external caller. That told us the offending code path is *not*
visible to a 0.5 s polling probe; we need the KVO event itself,
which carries the call-stack at the moment the property changes.

Two changes:

1. **KVO observer now logs at 1200 chars** and the log line is
   renamed `KVO button.image` so it is greppable. Same for
   `KVO barItem.isVisible`. The previous 800-char truncation cut
   off the relevant AppKit frame on long stacks.
2. **`applyFallbackIcon(to:)` now emits a six-line diagnostic
   block** on every call: enter, asset-catalog hit, resized-image
   state, etc. This will tell us whether the asset catalog entry
   is actually present and whether `resizedCopy` returns a valid
   image at all.

`AppVersion.patch` bumped 11 → 12.

## Motivation
User captured the first batch of monitor logs from p11:

```
StatusItemMonitor: poll vis=true img=false win=true title=<empty> alpha=1.0 frame=(0.0, 0.0, 16.0, 22.0) suspicious=YES
StatusItemMonitor: STACK 0   ... pollOnce ...
                    1   ... start() ...
                    2   ... NSTimer CIeghg ...
                    3-7 CoreFoundation runloop
```

Three facts are now nailed down:

- **`img=false` from the very first poll after launch.** The icon
  was never set; we are not "losing" it, we never had it.
- **`alpha=1.0` and `vis=true`** — the image was cleared
  *without* touching visibility or alpha. So no `barItem.hide()`
  or `barItem.show()` is involved.
- **`frame = (0, 0, 16, 22)`** — that is `NSStatusBarButton`'s
  intrinsic size *before* any image is applied. We never reached
  the "image applied" geometry.

This is incompatible with the hypothesis that an AppKit menu
tracking / scene-detach race is the cause. The image was never
written.

## Changes
- `SwiftBar/MenuBar/StatusItemMonitor.swift:71-95` — KVO
  observers now log at 1200 chars of stack (up from 800) and
  the log lines are renamed `KVO button.image` /
  `KVO barItem.isVisible` for easy grep.
- `SwiftBar/MenuBar/MenuBarItem.swift:255-289` — `applyFallbackIcon`
  now emits six diagnostic `os_log` lines on every call: enter,
  asset-catalog hit, resized-image state.
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 11 → 12.

## Impact
- **User-visible:** none. This is a pure observability layer.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -f SwiftBar && open …/Debug/SwiftBar.app`.
  2. Console.app: `[SwiftBar startup] SwiftBar v2.1.0 (b…-p12)`.
  3. Capture the **entire Console.app transcript from launch**.
  4. If the icon is *still* invisible, capture the entire
     `applyFallbackIcon` block output and paste it back.

# 2026-06-12: stderr-everything for StatusItemMonitor + applyFallbackIcon (p14)

- **Type:** diagnostic
- **Scope:** MenuBar / StatusItemMonitor
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
The user's p13 transcript via `tee` revealed what `os_log` could
not:

```
[SwiftBar applyFallbackIcon] rawAsset size={128, 128} reps=10 template=false
[SwiftBar applyFallbackIcon] resized (18x18) size={18, 18} reps=1 template=false
[SwiftBar applyFallbackIcon] SKIP (idempotent) — button already has matching image size={18, 18} reps=1 template=true title=
```

`applyFallbackIcon` IS being called. The first call succeeds (sets
`button.image`). A second call hits the idempotency check and skips
— and that second call is the problem, because the KVO observer
in `StatusItemMonitor` never logged an event for "image set" or
"image cleared". That is a contradiction: either the KVO event
was filtered out (privacy / subsystem mis-config), or the
observer was attached to the wrong button.

This round:
1. Routes **every** KVO / poll event through `FileHandle.standardError`
   in addition to `os_log`, so we never lose them.
2. Expands the SKIP and WROTE diagnostic lines in `applyFallbackIcon`
   so the user can see exactly which of the four idempotency
   conditions triggered.
3. Bumps `AppVersion.patch` 13 → 14.

## Motivation
The user's p13 transcript showed the bug is one level deeper:
`applyFallbackIcon` works correctly (idempotency skip is not the
bug per se), but something between the WROTE and the poll is
clearing `button.image` (or the KVO observer is on the wrong
button). The only way to know for sure is to get the KVO event
into stderr where the user can see it, alongside the
`applyFallbackIcon` calls.

## Changes
- `SwiftBar/MenuBar/StatusItemMonitor.swift:76-99` — both KVO
  observers (`button.image` and `barItem.isVisible`) now write
  the change event AND the full 2000-char call-stack to stderr
  on every fire.
- `SwiftBar/MenuBar/StatusItemMonitor.swift:118-136` — `pollOnce`
  now writes the snapshot to stderr on every state change, and
  the suspicious-state stack goes to stderr too.
- `SwiftBar/MenuBar/MenuBarItem.swift:305-321` — the SKIP and
  WROTE branches of `applyFallbackIcon` now print both the
  `existing` and `appIcon` fingerprint so we can see exactly
  which condition triggered.
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 13 → 14.

## Impact
- **User-visible:** none.
- **Terminal traffic:** every KVO event, every poll, every
  `applyFallbackIcon` branch — all on stderr, in the terminal
  that the user already has open via the `tee` command.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -9 -f SwiftBar`
  2. `cd ~/Library/Developer/Xcode/DerivedData/SwiftBar-grsnmcdweqsjrjbjnvrrxxayzndk/Build/Products/Debug && ./SwiftBar.app/Contents/MacOS/SwiftBar 2>&1 | tee /tmp/swiftbar-p14.log`
  3. Reproduce: click menu bar icon, hover "Toggle Plugins".
  4. Paste the full transcript. The expected sequence is:
     - One or more `[SwiftBar defaultBarItem] ENTER` lines.
     - One `[SwiftBar applyFallbackIcon] ENTER` per call.
     - Exactly one `[SwiftBar applyFallbackIcon] WROTE` for the
       initial set.
     - Possibly more `applyFallbackIcon` calls, each either
       `WROTE` or `SKIP`.
     - Exactly one `[StatusItemMonitor KVO button.image] old=nil new=…`
       for the initial WROTE. If we see an additional
       `KVO button.image` line that goes `old=… new=nil`, that
       is the moment the icon disappears and its stack is the
       smoking gun.
     - Then a series of `[StatusItemMonitor poll] … suspicious=YES`
       lines.

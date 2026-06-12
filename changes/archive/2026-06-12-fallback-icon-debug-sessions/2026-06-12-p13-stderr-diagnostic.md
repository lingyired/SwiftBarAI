# 2026-06-12: stderr-based diagnostic for defaultBarItem + applyFallbackIcon (p13)

- **Type:** diagnostic
- **Scope:** MenuBar
- **Author(s):** Trae AI
- **Commit(s):** _pending_
- **Status:** in-progress

## Summary
The p12 `os_log`-based diagnostic dump did not show up in the user's
Console.app output. That left two possibilities:

- (a) The user is still running an older build (p11), in which case
      the new `os_log` calls are not in the binary at all.
- (b) The p12 `os_log` calls are running, but Apple's logging
      subsystem is dropping the lines (privacy redaction,
      subsystem mis-config, log level cutoff, etc.).

This round eliminates ambiguity by switching the diagnostic
output from `os_log` to `FileHandle.standardError.write(Data(...))`.
stderr lines:

- Are **always** captured by Console.app for the lifetime of
  the process (no subsystem / privacy / level filtering).
- Include the literal substring `[SwiftBar applyFallbackIcon]`
  and `[SwiftBar defaultBarItem]` for easy grep.
- Cover the full path through both call sites: the factory
  function (`defaultBarItem`) and the icon-apply helper
  (`applyFallbackIcon`), including the SKIP / WROTE branches
  inside the idempotency check.

`AppVersion.patch` bumped 12 → 13.

## Motivation
User pasted the p11/p12 log transcript:

```
StatusItemMonitor: poll vis=true img=false win=true title=<empty> alpha=1.0 frame=(0.0, 0.0, 16.0, 22.0) suspicious=YES
StatusItemMonitor: STACK 0   ... pollOnce ...
                    1   ... start() ...
                    2-7 NSTimer + runloop
```

The p12 dumps (`applyFallbackIcon: ENTER`, `applyFallbackIcon:
rawAsset`, `applyFallbackIcon: appIcon`) are **not** in the
transcript, even though the source has them and the dylib at
the user's STACK address (`0x1040d3f6c`) was built before p12.
Two of the strongest possibilities:

- The user is running a stale `pkill`-resistant build.
- The os_log subsystem is silently dropping the lines.

stderr is the simplest, most reliable way to find out. Every
time `defaultBarItem` and `applyFallbackIcon` are entered or
take a branch, a `[SwiftBar …]` line is now written to stderr
which Console.app will display as the process's standard
output.

## Changes
- `SwiftBar/MenuBar/MenuBarItem.swift:765-769` — `defaultBarItem()`
  writes `[SwiftBar defaultBarItem] ENTER — constructing fallback
  MenubarItem` to stderr.
- `SwiftBar/MenuBar/MenuBarItem.swift:255-264` — `applyFallbackIcon`
  opens a local `stderrWrite` closure and writes ENTER with the
  current `button.image` and `button.frame`.
- `SwiftBar/MenuBar/MenuBarItem.swift:277-285` — emits
  `rawAsset size=… reps=… template=…` after the asset catalog
  lookup.
- `SwiftBar/MenuBar/MenuBarItem.swift:290` — emits
  `resized (18x18) size=… reps=… template=…` after `resizedCopy`.
- `SwiftBar/MenuBar/MenuBarItem.swift:312` — emits `SKIP
  (idempotent) — …` when the idempotency check fires.
- `SwiftBar/MenuBar/MenuBarItem.swift:317` — emits
  `WROTE button.image — post-write image=… frame=…` after the
  `button?.image = appIcon` write.
- `SwiftBar/Utility/AppVersion.swift:25` — `AppVersion.patch`
  bumped 12 → 13.

## Impact
- **User-visible:** none.
- **Console.app traffic:** the launch path now writes 4-6
  `[SwiftBar …]` lines to stderr, which Console.app shows
  immediately. These are not subject to the os_log privacy /
  subsystem configuration.
- **Backward compatibility:** None.

## Testing
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → `** BUILD SUCCEEDED **`.
- Manual:
  1. `pkill -f SwiftBar`
  2. `open ~/Library/Developer/Xcode/DerivedData/SwiftBar-grsnmcdweqsjrjbjnvrrxxayzndk/Build/Products/Debug/SwiftBar.app`
  3. Console.app, search for `applyFallbackIcon` and `defaultBarItem`.
  4. Confirm the launch transcript shows the new
     `[SwiftBar defaultBarItem] ENTER …` line, followed by
     `[SwiftBar applyFallbackIcon] ENTER …`,
     `[SwiftBar applyFallbackIcon] rawAsset …`,
     `[SwiftBar applyFallbackIcon] resized (18x18) …`, and
     `[SwiftBar applyFallbackIcon] WROTE button.image …`.
  5. If any of those are missing, paste the full transcript.

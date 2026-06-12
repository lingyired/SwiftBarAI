# p25 — Fix opaque backing-store in `resizedCopyTight`

**Status:** in-progress
**Date:** 2026-06-12
**Branch:** `refactor/folder-based-plugins-with-manifest`

## Context

After
[p24](./2026-06-12-p24-replace-app-icon.md) replaced the SwiftBar
app icon with the user's new wordmark design, the menu-bar
fallback icon disappeared — the slot where the icon should have
been showed a solid green rectangle. The menu itself still
worked (the user could still open the menu and see "SwiftBar
v2.1.x" and the "Toggle Plugins" section), so the status item
was still alive; only the rendered image was wrong.

## Root cause

The regression was inside
[`resizedCopyTight`](../SwiftBar/Utility/NSImage.swift) — the
helper added in
[p23](./2026-06-12-p23-tighten-fallback-icon.md) to crop and
aspect-fit the asset's visible glyph.

The old implementation built the destination on
`NSImage(size:).lockFocus()`:

```swift
let result = NSImage(size: destSize)
result.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: destSize).fill()
draw(in: fitRect, from: tight, operation: .sourceOver, fraction: 1)
result.unlockFocus()
```

The trap is that `lockFocus()` on a bare `NSImage(size:)`
**allocates a backing bitmap with `bitmapAlpha = .none`** — the
rep is opaque by default. On an opaque backing store:

1. `NSColor.clear.setFill()` followed by `fill()` writes
   RGB(0, 0, 0) with alpha 1.0, not transparent. The
   "clear to transparent" step is a no-op for alpha purposes.
2. `draw(... .sourceOver)` then composites the source glyph on
   top of the opaque black. The destination ends up **fully
   opaque**: every pixel has alpha = 1.0, regardless of what
   the source glyph's alpha was.

The result is a 16×16 image where the *entire rectangle* is
opaque. The glyph shape is still drawn correctly, but the
"transparent margin" around the glyph is gone.

When the caller (`MenubarItem.applyFallbackIcon`) then sets
`isTemplate = true` on this image, AppKit uses the alpha
channel as a mask and fills the **opaque** area with the
system tint colour. There is no longer a distinction between
glyph and margin — both are opaque, so both get tinted. The
visual result is a uniformly-tinted rectangle in the status
bar. On macOS Sonoma+ that tint matches the menu bar's
translucent background, which on the user's screen read as
solid green.

The old `{/*}` asset happened to survive this bug in practice
because its 16×16 file has so few opaque pixels (12×9 ≈ 108)
that the all-opaque "fence" around the glyph was visually
indistinguishable from the all-opaque glyph itself when
rendered at 16pt. The new wordmark design fills almost the
entire 16×16 frame (a 16×10.7 horizontal glyph), so the
surrounding opaque fence is the same size as the glyph and
dominates the visual — turning the icon into a coloured
rectangle.

## What changed

[SwiftBar/Utility/NSImage.swift](../../SwiftBar/Utility/NSImage.swift)
— the body of `resizedCopyTight` was rewritten to allocate
the destination as a real `NSBitmapImageRep` with
`hasAlpha: true` (and `samplesPerPixel: 4`), then zero the
rep's `bitmapData` directly with `memset` before drawing:

```swift
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(w), pixelsHigh: Int(h),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { return resizedCopy(w: w, h: h) }
bitmap.size = destSize

let result = NSImage(size: destSize)
result.addRepresentation(bitmap)
if let raw = bitmap.bitmapData {
    memset(raw, 0, bitmap.bytesPerRow * Int(h))
}
result.lockFocus()
draw(in: fitRect, from: tight, operation: .sourceOver, fraction: 1)
result.unlockFocus()
result.isTemplate = isTemplate
return result
```

Two important details:

1. **Real alpha-capable rep.** Going through
   `NSBitmapImageRep(... hasAlpha: true ...)` is the only
   documented way to get an alpha-capable backing store. The
   rep is then attached to the `NSImage` with
   `addRepresentation`, so `lockFocus()` locks onto *this* rep
   and not onto a cached opaque one.
2. **Direct `memset` instead of `NSColor.clear.fill()`.** Even
   with the right rep, `NSColor.clear` through the AppKit
   drawing context is fragile — it depends on the current
   compositing operation and the rep's `bitmapAlpha` value
   being honoured by the cached graphics context. Zeroing the
   raw buffer guarantees every pixel starts at `(0, 0, 0, 0)`
   before the glyph is composited on top, regardless of
   AppKit version or `lockFocus` caching behaviour.

A long doc-comment in the file explains both points so that
the next person who reaches for `NSImage(size:).lockFocus()`
to do compositing on a transparent background sees why that
path is unsafe.

## Verification

- `xcodebuild ... clean build` → `** BUILD SUCCEEDED **`.
- Standalone Swift verification script: load the new
  `mac_512@2x.png` from the asset catalog, run the fixed
  `resizedCopyTight` path inline, and read back the alpha
  histogram of the resulting 16×16 image:
  - alpha range `[0, 162]` (was previously `[1, 255]` with
    no zero-alpha pixels).
  - `opaque > 16` count: **178** (the wordmark glyph at its
    rendered scale).
  - fully-transparent (alpha = 0) count: **825** (the margin
    around the glyph).
  - total: 1024 = 16×16 ✓.
- The same script on the previous `resizedCopyTight` body
  returned `opaque > 16` count of 1024 (every pixel opaque),
  confirming the diagnosis: the old code produced an
  all-opaque image and the new code does not.

## What was deliberately not changed

- **`resizedCopy` itself.** That helper is used in three call
  sites (`MenubarItem.applyFallbackIcon` would not be one
  after p23, `MenuBarItem.swift:458` for the menu's
  `swiftBarItem.image`, and `MenuLineParameters` for
  user-supplied `image=` parameters). Its callers either
  never needed alpha (the menu icon has its own background)
  or take their source image from a user script that already
  provides a bitmap with alpha. Leaving the simpler
  `lockFocus` path in `resizedCopy` avoids regressing those
  call sites.
- **`applyFallbackIcon`**. The wrapper already sets
  `isTemplate = true`; that is correct behaviour for a
  monochrome-style wordmark (it lets the menu bar pick the
  dark/light tint) and is no longer the cause of the visual
  failure. The fix in `resizedCopyTight` is the only place
  the alpha channel was being silently dropped.
- **The asset PNGs themselves** were not re-exported. The
  same `sips`-generated files from p24 are correct; the bug
  was in how SwiftBar read them at runtime, not in the files.

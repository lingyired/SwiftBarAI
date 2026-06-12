# p23 — Tighten the SwiftBar fallback icon against the menu-bar neighbours

**Status:** in-progress
**Date:** 2026-06-12
**Branch:** `refactor/folder-based-plugins-with-manifest`

## Context

After [p19](./2026-06-12-p19-flatten-toggle-menu.md) the SwiftBar
fallback icon (the `{/*}` glyph that appears in the menu bar while
no plugin is producing content, or when the active plugin has no
icon of its own) sat noticeably narrower than the surrounding app
icons. The vertical centering was fine, but the icon looked like it
had a couple of extra points of padding on each side, so it read
as smaller and stranded against Control Center, Finder, and the
menu icon next to it.

The user-visible result was a menubar that visually said "SwiftBar
is doing less" even when the app was running normally.

## Root cause

Two compounding issues, both in the image pipeline that backs
`MenubarItem.applyFallbackIcon(to:)`:

1. **Image was sized at 18×18.** AppKit sizes the `NSStatusItem`
   button from `image.size` (plus a small internal inset). 18pt is
   not a canonical size; the macOS standard is 16pt. Every extra
   point we fed in widened the button by exactly that point on each
   side after AppKit's own horizontal inset was applied.
2. **Asset has built-in transparent padding.** The source PNGs in
   `AppIcon.appiconset/` are 16×16 (or @2x 32×32 etc.) but the
   actual visible glyph occupies only 12×9 px (a 24×18 box in
   the 32×32 @2x). The empty border was being preserved by the
   existing `resizedCopy`, so the rendered icon was only 75% of
   the image dimensions in width and 56% in height. The rest was
   transparent space *inside* the image — invisible to layout but
   very obvious to the eye.

The combination: a 18pt-wide image holding a 13.5pt glyph inside
a button with AppKit's ~6pt inset, rendered at 16pt effective
content size. The neighbours were filling their 28pt buttons with
glyphs that took up the full 22pt visual width.

## What changed

### `SwiftBar/Utility/NSImage.swift`

Added two new functions on `NSImage`:

- `resizedCopyTight(w:h:alphaThreshold:)` — public helper. Crops
  the source to its tight non-transparent bounding box, then
  aspect-fits the crop inside the destination and centres it.
  Aspect-fit (not aspect-fill) is deliberate: a 24×18 crop
  inside a 16×16 destination becomes a 16×12 glyph centred
  vertically, not a stretched 16×16. The 2pt of vertical margin
  is the same kind of margin every system template icon has on
  its short axis, so the icon reads as "normal" and not as
  "squashed".
- `tightOpaqueBounds(alphaThreshold:)` — private helper. Walks
  the bitmap's alpha channel and returns the tight `NSRect` of
  the pixels with `alpha > threshold`. Falls back to `nil` for
  fully transparent sources (in which case the public helper
  falls back to the legacy `resizedCopy`).

The threshold is 16/255 — low enough to catch anti-aliased edges
on the `{`, `*`, and `}` glyphs in the asset without picking up
compression artefacts.

### `SwiftBar/MenuBar/MenuBarItem.swift`

In `applyFallbackIcon(to:)`:

- `resizedCopy(w: 18, h: 18)` → `resizedCopyTight(w: 16, h: 16)`.
- Updated the comment block to explain the sizing choice (16 is
  the canonical NSStatusItem image dimension; tight crop removes
  asset padding).

The idempotency guard immediately below the resize call still
works unchanged: it compares `image.size`, `isTemplate`,
`representations.count`, and `title`. None of those change in a
way that would defeat the early return.

## What was deliberately not changed

- **`swiftBarItem.image` at `MenuBarItem.swift:458`.** That line
  renders the same asset for the first row of the menu (not the
  status bar) at 21×21. The user only reported the menubar icon,
  and the menu row is already 30pt tall (per
  [p22](./2026-06-12-p22-toggle-row-spacing.md) for adjacent
  rows) so the icon naturally reads as smaller inside a larger
  frame. Touching it is out of scope.
- **The asset PNGs themselves.** We could redraw the source
  glyph to fill its 16×16 box, but that is a design change
  (proportions, kerning, optical sizing) rather than a fix.
  Doing it in code means the change is reversible and version-
  controllable without re-exporting binary assets.
- **`NSStatusItem.length`.** We did not change
  `barItem` from `NSStatusItem.variableLength` to a square
  length. The 16pt image is the canonical driver of the button
  width; the variable length only matters for status items that
  show text, which the SwiftBar root item does not.

## Verification

- `xcodebuild ... build` → `** BUILD SUCCEEDED **`
- Pixel sanity test: rasterised the 32×32 @2x asset, computed the
  tight opaque bounding box in a standalone Swift script:
  `(4,7)-(27,24)` = 24×18, matching the measurement taken with
  Python's PIL. The crop in `tightOpaqueBounds` is therefore
  extracting exactly the pixels that the eye sees, and the
  aspect-fit is computing a 16×12 result inside a 16×16 frame.
- Visual: open SwiftBar with no plugin output (or with a plugin
  that returns no icon). The `{/*}` glyph in the menu bar now
  spans the dominant axis of its button, matching the visual
  weight of the surrounding icons. The vertical margin (2pt top
  and bottom) matches the margin every system template icon has.

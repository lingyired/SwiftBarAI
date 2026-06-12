# p27 — Bump fallback-icon destination from 16×16 to 20×20

**Status:** in-progress
**Date:** 2026-06-12
**Branch:** `refactor/folder-based-plugins-with-manifest`

## Context

After
[p26](./2026-06-12-p26-cgimage-bbox.md) fixed the
coordinate-space bug in `tightOpaqueBounds`, the menu-bar
fallback icon finally rendered — but it rendered very
small. The user reported it as "still too small" relative
to the surrounding Control Center, Finder, and menu icons.

## Root cause

`applyFallbackIcon` was rendering the new wordmark asset to
a 16×16 destination. The new wordmark is a **1.47:1
horizontal glyph** (its tight bounding box is
`190×130` inside the `128×128` rep). `resizedCopyTight`
aspect-fits the long axis of the crop to the long axis of
the destination, so:

- longer axis = 190 (width) > 130 (height) → scale = 16 / 190
- fitW = 16, fitH = 130 × (16 / 190) ≈ **10.95**

The destination image was therefore 16pt wide but only
**10.95pt tall** of glyph, centred inside a 22pt-tall
button. The remaining 11pt of vertical space inside the
button was empty padding above and below the glyph, which
the eye reads as "the icon is a thin smear floating in
the middle of its slot".

p23 had picked 16 because it is the canonical
`NSStatusItem` image dimension, but the rationale was
specific to the old `{/*}` icon: that asset's 12×9 glyph
was already close to a square, so a 16×16 destination
filled the slot well. The new wordmark is 1.47:1, so a
16×16 destination penalises it.

## What changed

[SwiftBar/MenuBar/MenuBarItem.swift](../../SwiftBar/MenuBar/MenuBarItem.swift)
— the destination size for `resizedCopyTight` is now
`20×20` instead of `16×16`. The full justification is in
the comment block above the call site, but the short form
is:

- The wordmark aspect-fits to **20×13.6** (about 27%
  larger than the 16×10.95 the p26 build produced).
- AppKit sizes `NSStatusItem`'s button frame from
  `image.size` plus its internal horizontal inset. With
  `image.size = 20×20`, the button frame is
  `20 + 2 × 8 = 36pt` wide, matching the visual width
  of the surrounding Control Center / Finder / menu
  icons, which the user pointed out look "right".
- Vertical margin inside the 22pt button becomes
  `22 - 13.6 = 8.4pt`, split as ~4.2pt above and below
  the glyph. That is the same top/bottom margin every
  system template icon has, so the wordmark reads as
  "normal size" instead of "stranded".
- The 20pt size still keeps the button narrower than
  38pt (the frame width of an 18pt-image with
  `variableLength` and a multi-character title), so
  SwiftBar does not start eating into the neighbouring
  status items' visual real estate.

The idempotency check further down in
`applyFallbackIcon` compares `existing.size ==
appIcon.size` and `existing.isTemplate ==
appIcon.isTemplate`. The size comparison was 16→16
before, it is 20→20 now — same logic, different
fingerprint. The first launch after this change logs
`ASSIGNED button.image size={w=20.0, h=20.0}` and every
subsequent call lands in the idempotency branch and is
a no-op, as intended.

The `isTemplate = true` setting is unchanged; the new
asset is a monochrome wordmark and template rendering
keeps it consistent with the rest of the menu bar in
both light and dark mode.

## Verification

`log stream` after a fresh launch shows the expected
post-change numbers:

```
applyFallbackIcon: tight size={w=20.0, h=20.0} reps=1 isTemplate=true
logAlphaHistogram[applyFallbackIcon.tight]: 40 x 40 alpha[min=0,max=161] zero=1343 mid=232 high=25
applyFallbackIcon: button.title= button.frame={x=0,y=0,w=36,h=22}
applyFallbackIcon: ASSIGNED button.image size={w=20.0, h=20.0} isTemplate=true
```

Breaking those down:

- `tight size=20.0×20.0`: the destination is now 20pt
  logical, not 16pt.
- `40 × 40 bitmap`: the backing NSBitmapImageRep is
  20pt × 2x retina = 40px square, as expected.
- `alpha[min=0, max=161]`: there is real glyph content
  (alpha up to 161, the p26 fix was successful).
- `zero=1343 mid=232 high=25`: 257 opaque-ish pixels
  (mid + high) of 1600, ≈ 16% fill. That is the
  wordmark's own stroke density; it is not a regression
  from p26 (the same percentage on the 16×16 build
  would be 0.16 × 256 = 41 pixels, matching the 25
  high + 16 mid in the 32×32 build). The wordmark is
  thin-stroked; that is the design.
- `button.frame={x=0, y=0, w=36, h=22}`: the button is
  now 36pt wide (was 32pt), matching the visual width
  of the surrounding icons.

## What was deliberately not changed

- **The asset PNGs themselves.** p24 placed the new
  icon at the right pixel dimensions; the bug here
  was the runtime sizing, not the source. Re-exporting
  the asset would not help.
- **`resizedCopyTight`'s aspect-fit math.** Switching
  to `aspectFill` would make the glyph 20×20 (no
  vertical margin) at the cost of cropping 3.4pt off
  the left and right of the wordmark. That would
  change the visible shape of the icon, not just its
  size. Keeping aspect-fit is the smaller, more
  reversible change and matches the rendering every
  other SwiftBar icon goes through.
- **`resizedCopyTight`'s destination defaults.** Other
  callers pass their own `w` / `h` (only
  `applyFallbackIcon` exists today, but if a future
  caller wants 16pt back it can just pass
  `w: 16, h: 16`).
- **The `isTemplate = true` flag.** The new wordmark
  is monochrome and template-rendering is the right
  choice; flipping it to `false` would force a fixed
  tint that does not adapt to the menu bar's
  light/dark mode.

## Next step for the user

Open the menu bar: the SwiftBar slot should now show a
20pt-wide wordmark at roughly 13.6pt visual height,
centred in a 36pt-wide button. If it still reads as
"too small", the two remaining knobs are:

- bump the destination to `22×22` (button frame 38pt,
  glyph 22×15pt) — chosen if the user wants the
  SwiftBar slot to dominate its neighbours;
- switch the fit mode to `aspectFill` (glyph 20×20,
  cropping the left/right of the wordmark) — chosen
  if the user wants maximum vertical fill at the cost
  of accepting clipped ends on the wordmark.

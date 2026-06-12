# p24 — Replace SwiftBar app icon with the new design

**Status:** in-progress
**Date:** 2026-06-12
**Branch:** `refactor/folder-based-plugins-with-manifest`

## Context

The user supplied a new 1024×1024 master icon at
`/Users/lingsmbp/Documents/aiwork/SwiftBarAI/icon.png` and asked
for it to replace the existing SwiftBar app icon throughout the
asset catalog. The previous glyph — a `{/*}` set of curly braces
with an asterisk between them — was serviceable but visually
light; the new design is a more substantial, horizontally
oriented logo.

The app icon drives two distinct rendering paths in SwiftBar, and
both continue to work unchanged after the asset swap:

1. The macOS app icon (Dock, Finder, About window, app switcher).
   This is rendered by macOS from the bundle's icon files; SwiftBar
   does not draw it.
2. The status-bar fallback icon. This is rendered at runtime by
   [`MenubarItem.applyFallbackIcon(to:)`](../../SwiftBar/MenuBar/MenuBarItem.swift)
   using `NSImage(named: "AppIcon")`, which reads the same asset
   catalog. [p23](./2026-06-12-p23-tighten-fallback-icon.md)
   already installed a `resizedCopyTight` pipeline that crops the
   source to its tight non-transparent bounding box before
   resizing — that path automatically adapts to the new asset's
   transparent border, so no further code change is needed for
   the status bar.

## What changed

[SwiftBar/Resources/Assets.xcassets/AppIcon.appiconset/](../../SwiftBar/Resources/Assets.xcassets/AppIcon.appiconset/)
— all 10 PNGs in the catalog were regenerated from the new master
using macOS `sips`:

| Filename       | Pixel size | Source            |
| -------------- | ---------- | ----------------- |
| `mac_16.png`   | 16×16      | `icon.png` 1024²  |
| `mac_16@2x.png`| 32×32      | `icon.png` 1024²  |
| `mac_32.png`   | 32×32      | `icon.png` 1024²  |
| `mac_32@2x.png`| 64×64      | `icon.png` 1024²  |
| `mac_128.png`  | 128×128    | `icon.png` 1024²  |
| `mac_128@2x.png`| 256×256   | `icon.png` 1024²  |
| `mac_256.png`  | 256×256    | `icon.png` 1024²  |
| `mac_256@2x.png`| 512×512   | `icon.png` 1024²  |
| `mac_512.png`  | 512×512    | `icon.png` 1024²  |
| `mac_512@2x.png`| 1024×1024 | `icon.png` 1024²  |

`AppIcon.appiconset/Contents.json` was not modified — the file
names and slot definitions are unchanged, only the binary
contents.

## Bbox sanity check

After the swap, every file in the appiconset was rasterised and
its non-transparent bounding box measured. The new design's
visible content fills **75% of the width** and **50% of the
height** of every size, in a 1.47:1 horizontal aspect. That is
intentional — the source is a horizontal wordmark, and the
master canvas is square only so the same file can drive the
round-rect-masked macOS app icon shape.

For the status-bar fallback (the only path SwiftBar draws at
runtime), p23's `resizedCopyTight` automatically:

1. Crops each catalog PNG to its tight bbox (e.g. 12×8 inside the
   16×16 file).
2. Aspect-fits the crop inside the 16×16 destination — longer
   axis matches the destination's longer axis.
3. Centres the result.

So the new icon will render in the menu bar as a 16×10.7
horizontal glyph, centred inside the 16pt button frame. That
matches the visual weight of the surrounding status-bar icons
(per p23's original goal) and uses the new design's horizontal
proportions correctly.

## What was deliberately not changed

- **`Contents.json`**, the slot definitions, the scale modifiers,
  and the macOS idiom tags. The asset catalog contract is
  unchanged; only the rendered pixels differ.
- **The status-bar fallback pipeline** (p23). The new asset's
  built-in padding is the same kind of padding p23 was written
  to absorb, so the fix is asset-agnostic.
- **`icon.1024.png` and `icon.trimmed.png`** at the project
  root. These are scratch files from earlier p18-p20 work and
  are not referenced by the Xcode build. They are still
  untracked and are not part of this change.
- **The old appiconset PNGs** were not copied into a fresh
  backup directory. The git history of every file in
  `AppIcon.appiconset/` is a complete backup; the user can
  recover any previous version with `git checkout HEAD~N -- …`.

## Verification

- `sips -g pixelWidth -g pixelHeight` on every regenerated file
  shows the expected physical size.
- Python/PIL bbox scan on every regenerated file shows
  consistent ~75%×50% opaque coverage, matching the source
  master's 1.47:1 horizontal aspect.
- `xcodebuild ... build` → `** BUILD SUCCEEDED **`.
- The new icon should appear in the Dock and `About SwiftBar`
  window the next time the app is launched (the asset catalog
  is baked into the bundle at build time).

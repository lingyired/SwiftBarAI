import Cocoa

extension NSImage {
    static func createImage(from base64: String?, isTemplate: Bool) -> NSImage? {
        guard let base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        let image = NSImage(data: data)
        image?.isTemplate = isTemplate
        return image
    }

    func resizedCopy(w: CGFloat, h: CGFloat) -> NSImage {
        let destSize = NSMakeSize(w, h)
        let newImage = NSImage(size: destSize)

        newImage.lockFocus()

        draw(in: NSRect(origin: .zero, size: destSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: CGFloat(1))

        newImage.unlockFocus()

        guard let data = newImage.tiffRepresentation,
              let result = NSImage(data: data)
        else { return NSImage() }
        result.isTemplate = isTemplate
        return result
    }

    /// Like `resizedCopy`, but first crops the source image to its
    /// tight non-transparent bounding box, then aspect-fills the
    /// result into the requested destination and centres it. This
    /// is what you want when the source asset is a square PNG (e.g.
    /// an iOS app icon) with built-in padding, and you want the
    /// visible glyph to fill the destination's image area in both
    /// axes — cropping the side decorations of a horizontal
    /// wordmark so that the central mark occupies the full
    /// square, rather than floating with a margin the way
    /// aspect-fit would render it.
    ///
    /// "Aspect-fill, centre" means: scale the cropped glyph so its
    /// shorter axis matches the destination's shorter axis, let
    /// the longer axis spill past the destination edge and be
    /// cropped there, and position the result at the centre of
    /// the destination frame. The destination is therefore filled
    /// edge-to-edge in both axes by the visible portion of the
    /// glyph. We rely on the source's tight bbox already being
    /// centred inside the master canvas (true for the SwiftBar
    /// `icon.png`) so that the cropped spill is symmetric and the
    /// main subject of the icon remains visible.
    ///
    /// If the source has no pixels with `alpha > threshold` we fall
    /// back to a plain `resizedCopy` — there is no meaningful bbox to
    /// compute, and rendering the whole (transparent) source is
    /// indistinguishable from rendering nothing.
    ///
    /// **Important backing-store detail.** We deliberately build the
    /// destination on a `NSBitmapImageRep` with
    /// `bitmapAlpha = .premultipliedFirst`, NOT on the plain
    /// `NSImage(size:).lockFocus()` path that `resizedCopy` uses.
    /// `lockFocus()` on a bare `NSImage` lands on a backing store
    /// whose alpha channel is **opaque by default** — the bitmap
    /// rep it picks has `bitmapAlpha = .none`. In that case
    /// `NSColor.clear.setFill()` writes RGB(0,0,0) (opaque black),
    /// not transparent, and a subsequent `draw(.sourceOver)` keeps
    /// the whole canvas opaque. The resulting image therefore has
    /// no transparent pixels at all, and when it is later flagged
    /// `isTemplate = true` (as `MenubarItem.applyFallbackIcon`
    /// does), AppKit fills the entire image rectangle with the
    /// system tint colour. In the menu bar that tint is the
    /// translucent background colour, which on macOS Sonoma+
    /// renders as a solid green rectangle — the "icon disappeared,
    /// replaced by a green box" failure mode.
    func resizedCopyTight(w: CGFloat, h: CGFloat, alphaThreshold: UInt8 = 16) -> NSImage {
        guard let tight = tightOpaqueBounds(alphaThreshold: alphaThreshold) else {
            return resizedCopy(w: w, h: h)
        }
        // `tightOpaqueBounds` returns the bbox in the chosen rep's
        // native pixel coordinates. `NSImage.draw(in:from:)`,
        // however, consumes `from` in the image's logical
        // (point) coordinate space, so we have to convert. The
        // rep the bbox was measured against is the one
        // `cgImage(forProposedRect: nil, …)` returns, whose
        // logical size is the NSImage's overall `size`.
        let chosenRep = self.bestRepresentation(
            for: NSRect(origin: .zero, size: size),
            context: nil,
            hints: nil
        ) ?? self.representations.first
        let pixW = CGFloat(chosenRep?.pixelsWide ?? Int(size.width))
        let pixH = CGFloat(chosenRep?.pixelsHigh ?? Int(size.height))
        let scaleX = size.width  / max(pixW, 1)
        let scaleY = size.height / max(pixH, 1)
        let tightLogical = NSRect(
            x: tight.origin.x * scaleX,
            y: tight.origin.y * scaleY,
            width: tight.size.width * scaleX,
            height: tight.size.height * scaleY
        )

        let destSize = NSSize(width: w, height: h)
        let cropSize = tightLogical.size

        // Aspect-fill: scale the glyph so its shorter axis
        // matches the destination's shorter axis. The longer axis
        // becomes proportionally larger and is cropped equally
        // on both sides, with the glyph centred.
        let cropAspect = cropSize.width / max(cropSize.height, 1)
        let destAspect = w / max(h, 1)
        let scale: CGFloat = cropAspect > destAspect
            ? h / cropSize.height
            : w / cropSize.width
        let fitW = cropSize.width * scale
        let fitH = cropSize.height * scale
        let fitRect = NSRect(
            x: (w - fitW) / 2,
            y: (h - fitH) / 2,
            width: fitW,
            height: fitH
        )

        // Build the destination as a real alpha-capable bitmap
        // rep, then wrap it in an NSImage. `NSImage(size:)
        // .lockFocus()` forces `bitmapAlpha = .none` and silently
        // discards alpha, so we go through `NSBitmapImageRep`
        // directly.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(w),
            pixelsHigh: Int(h),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return resizedCopy(w: w, h: h)
        }
        bitmap.size = destSize

        let result = NSImage(size: destSize)
        result.addRepresentation(bitmap)
        // Zero the alpha buffer. Going through `lockFocus` can
        // land the drawing context on a cached rep rather than
        // the one we just allocated; memset is the reliable path.
        if let raw = bitmap.bitmapData {
            memset(raw, 0, bitmap.bytesPerRow * Int(h))
        }
        result.lockFocus()
        draw(in: fitRect, from: tightLogical, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = isTemplate
        return result
    }

    /// Tight bounding box (in source-image coordinates) of the pixels
    /// with `alpha > alphaThreshold`. Returns `nil` when no opaque
    /// pixels are found, or when the image cannot be rasterised.
    ///
    /// We deliberately do **not** use `tiffRepresentation` here.
    /// For an `NSImage` that came from a compiled asset catalog
    /// (e.g. `NSImage(named: "AppIcon")`), `tiffRepresentation`
    /// rasterises the *NSCGImageRep* the asset catalog returns,
    /// and the resulting bitmap's pixel coordinates are in the
    /// *original* PDF / SVG authoring space — typically the
    /// master 1024×1024 canvas, even when the rep's nominal
    /// `pixelsWide × pixelsHigh` is 128×128 (the @1x slot).
    /// Computing the bbox in those coordinates and then passing
    /// it to `draw(in:from:)` against a 128×128 source means the
    /// `from` rect lies entirely outside the source, the draw
    /// is a no-op, and the destination image ends up fully
    /// transparent. That is exactly the failure observed when
    /// the SwiftBar fallback icon disappears from the menu bar
    /// after replacing the app icon.
    ///
    /// Instead we walk the rep's `CGImage` directly. A `CGImage`
    /// always reports its pixels in its own native coordinate
    /// space, matching `pixelsWide × pixelsHigh`, so the bbox we
    /// compute here is always valid for the very rep we are
    /// going to draw from.
    private func tightOpaqueBounds(alphaThreshold: UInt8) -> NSRect? {
        // Pick a representation that already exposes a CGImage.
        // For an `NSImage` from a compiled asset catalog, this is
        // the NSCGImageRep whose `pixelsWide × pixelsHigh` match
        // its nominal slot (16, 32, 128, 256, 512 ...). The
        // CGImage it returns is rasterised 1:1 in those exact
        // pixel coordinates, which is what we need: a bbox
        // computed against this bitmap can be passed to
        // `draw(in:from:)` against the same rep without any
        // coordinate-space mismatch.
        // Ask NSImage to pick its best rep and rasterise it for
        // us. The returned CGImage is in the pixel coordinates
        // of whatever rep NSImage chose, which is what we need.
        guard let cgImage = self.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return nil }
        return Self.tightOpaqueBoundsOfCGImage(cgImage, alphaThreshold: alphaThreshold)
    }

    private static func tightOpaqueBoundsOfCGImage(
        _ cgImage: CGImage, alphaThreshold: UInt8
    ) -> NSRect? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        guard let provider = cgImage.dataProvider,
              let cfData = provider.data,
              let raw = CFDataGetBytePtr(cfData)
        else { return nil }
        let bytesPerRow = cgImage.bytesPerRow
        let totalBytes = bytesPerRow * height
        let alphaInfo = cgImage.alphaInfo
        // We need to read the alpha byte. CGImage's byte layout
        // depends on `bitmapInfo` and `alphaInfo`:
        //   - .premultipliedFirst / .first           → alpha at +3
        //   - .premultipliedLast  / .last            → alpha at +0
        //   - .none                                  → no alpha, all opaque
        //   - .only                                  → alpha at +0 (gray alpha mask)
        // We normalise to "where is the alpha byte" and bail on
        // bitmaps we cannot reason about.
        let alphaOffsetInPixel: Int?
        switch alphaInfo {
        case .premultipliedFirst, .first:
            alphaOffsetInPixel = 3
        case .premultipliedLast, .last:
            alphaOffsetInPixel = 0
        case .none:
            // No alpha channel — every pixel is opaque. Return
            // the full image as the bbox.
            return NSRect(x: 0, y: 0, width: width, height: height)
        @unknown default:
            return nil
        }
        let componentsPerPixel: Int
        switch cgImage.bitsPerPixel {
        case 32: componentsPerPixel = 4
        case 24: componentsPerPixel = 3
        case 16: componentsPerPixel = 2
        case 8:  componentsPerPixel = 1
        default: return nil
        }
        let alphaOffset = alphaOffsetInPixel!

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var found = false

        for y in 0..<height {
            let rowBase = y * bytesPerRow
            for x in 0..<width {
                let pixelOffset = rowBase + x * componentsPerPixel + alphaOffset
                guard pixelOffset < totalBytes else { continue }
                let a = raw[pixelOffset]
                if a > alphaThreshold {
                    found = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard found, maxX >= minX, maxY >= minY else { return nil }
        return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func tintedImage(color: NSColor?) -> NSImage {
        guard isTemplate else { return self }
        guard let color, let newImage = copy() as? NSImage else { return self }

        newImage.lockFocus()

        color.set()

        let imageRect = NSRect(origin: .zero, size: newImage.size)
        imageRect.fill(using: .sourceAtop)

        newImage.unlockFocus()
        newImage.isTemplate = false

        return newImage
    }
}

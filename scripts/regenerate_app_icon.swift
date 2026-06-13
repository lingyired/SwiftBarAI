#!/usr/bin/env swift
// regenerate_app_icon.swift
//
// Generates the menubar01 AppIcon PNGs required by the asset catalog.
//
// Run from the repo root:
//     swift scripts/regenerate_app_icon.swift
//
// The icon is intentionally minimal — a rounded square (macOS-native shape)
// with three horizontal bar glyphs (representing a menu bar item) — and
// matches Apple's macOS template-icon conventions so it reads correctly
// in the Dock and the About panel.
//
// The script overwrites the existing PNG files in
// `SwiftBar/Resources/Assets.xcassets/AppIcon.appiconset/` and leaves the
// `Contents.json` alone (filenames are unchanged).

import AppKit
import Foundation

@discardableResult
func writeIcon(size: CGFloat, scale: CGFloat, to url: URL) -> Bool {
    let pixelSize = size * scale

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize),
        pixelsHigh: Int(pixelSize),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return false
    }
    bitmap.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return false
    }
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

    // Rounded-square background (macOS-style squircle approximation).
    let cornerRadius = pixelSize * 0.225
    let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.20, alpha: 1.0).setFill()
    backgroundPath.fill()

    // Menu-bar glyph: three short horizontal bars stacked vertically.
    let barCount = 3
    let totalBarAreaHeight = pixelSize * 0.50
    let barHeight = totalBarAreaHeight / CGFloat(barCount) * 0.55
    let spacing = (totalBarAreaHeight - barHeight * CGFloat(barCount)) / CGFloat(barCount - 1)
    let barWidth = pixelSize * 0.55
    let leftMargin = (pixelSize - barWidth) / 2
    let topMargin = (pixelSize - totalBarAreaHeight) / 2

    NSColor.white.setFill()
    for index in 0 ..< barCount {
        let barRect = NSRect(
            x: leftMargin,
            y: topMargin + CGFloat(index) * (barHeight + spacing),
            width: barWidth,
            height: barHeight
        )
        NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try pngData.write(to: url)
        return true
    } catch {
        FileHandle.standardError.write(Data("write failed at \(url.path): \(error)\n".utf8))
        return false
    }
}

let assetDirectory = URL(fileURLWithPath: "SwiftBar/Resources/Assets.xcassets/AppIcon.appiconset")

let sizes: [(label: String, size: CGFloat, scale: CGFloat, filename: String)] = [
    ("16@1x", 16, 1, "mac_16.png"),
    ("16@2x", 16, 2, "mac_16@2x.png"),
    ("32@1x", 32, 1, "mac_32.png"),
    ("32@2x", 32, 2, "mac_32@2x.png"),
    ("128@1x", 128, 1, "mac_128.png"),
    ("128@2x", 128, 2, "mac_128@2x.png"),
    ("256@1x", 256, 1, "mac_256.png"),
    ("256@2x", 256, 2, "mac_256@2x.png"),
    ("512@1x", 512, 1, "mac_512.png"),
    ("512@2x", 512, 2, "mac_512@2x.png"),
]

var failures = 0
for entry in sizes {
    let destination = assetDirectory.appendingPathComponent(entry.filename)
    let ok = writeIcon(size: entry.size, scale: entry.scale, to: destination)
    let marker = ok ? "✓" : "✗"
    print("\(marker) \(entry.label) → \(destination.lastPathComponent)")
    if !ok { failures += 1 }
}

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) icons failed to render\n".utf8))
    exit(1)
}
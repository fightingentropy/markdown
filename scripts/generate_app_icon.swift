#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let source = root.appendingPathComponent("branding/obsidian-icon.svg")
let destination = root.appendingPathComponent("Obsidian/Assets.xcassets/AppIcon.appiconset")

guard let image = NSImage(contentsOf: source) else {
    fatalError("Unable to load the Obsidian icon at \(source.path)")
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create the \(pixels)-pixel icon")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let size = CGFloat(pixels)
    let inset = size * 3 / 32
    image.draw(in: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode the \(pixels)-pixel icon")
    }
    try png.write(to: destination.appendingPathComponent("icon_\(pixels).png"))
}

print("Generated all seven macOS app icon sizes from the Obsidian SVG.")

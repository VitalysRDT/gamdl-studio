#!/usr/bin/env swift
// Draws the Gamdl Studio icon and fills AppIcon.appiconset.
//
//   swift scripts/make-icon.swift
//
// macOS squircle (1024 grid with a 100 px margin), pink to coral gradient,
// a highlight at the top, and a white "note + download arrow" glyph.

import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appending(path: "GamdlStudio/Resources/Assets.xcassets/AppIcon.appiconset")

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Main gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.30, alpha: 1).cgColor,
        NSColor(srgbRed: 0.98, green: 0.18, blue: 0.36, alpha: 1).cgColor,
        NSColor(srgbRed: 0.62, green: 0.10, blue: 0.52, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])

    // Glow in the top-left corner.
    let glow = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
    ctx.restoreGState()

    // Inner stroke.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Glyph: white SF Symbol with a light shadow for depth.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config),
       let arrow = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
           .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 200, weight: .bold)) {
        func tinted(_ image: NSImage) -> NSImage {
            let out = NSImage(size: image.size)
            out.lockFocus()
            image.draw(in: CGRect(origin: .zero, size: image.size))
            NSColor.white.set()
            CGRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
            out.unlockFocus()
            return out
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        let note = tinted(symbol)
        let noteRect = CGRect(x: 512 - note.size.width / 2 - 40, y: 512 - note.size.height / 2 + 20, width: note.size.width, height: note.size.height)
        note.draw(in: noteRect)
        let a = tinted(arrow)
        a.draw(in: CGRect(x: 560, y: 210, width: a.size.width, height: a.size.height))
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(size: base * scale).write(to: iconset.appending(path: name))
    }
}
print("Icône écrite dans \(iconset.path)")

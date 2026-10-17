import AppKit
import SwiftUI

/// Dominant colors of an artwork, used to tint the UI background.
struct ImagePalette: Hashable, Sendable {
    struct RGB: Hashable, Sendable {
        var r: Double, g: Double, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }

        /// Relative luminance (WCAG), used to pick light or dark text.
        var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        /// Same hue with clamped saturation and brightness: a nearly black or
        /// white cover would otherwise produce an unreadable background.
        func tamed(minBrightness: Double = 0.28, maxBrightness: Double = 0.78) -> RGB {
            let ns = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let out = NSColor(hue: h, saturation: min(max(s, 0.25), 0.85), brightness: min(max(v, minBrightness), maxBrightness), alpha: 1)
                .usingColorSpace(.sRGB) ?? ns
            return RGB(r: out.redComponent, g: out.greenComponent, b: out.blueComponent)
        }
    }

    /// Most to least prominent, 1 to 4 colors.
    let colors: [RGB]

    static let fallback = ImagePalette(colors: [
        RGB(r: 0.98, g: 0.18, b: 0.33), RGB(r: 0.62, g: 0.12, b: 0.55), RGB(r: 0.99, g: 0.45, b: 0.25),
    ])

    var primary: RGB { colors.first ?? Self.fallback.colors[0] }
    func color(_ i: Int) -> Color { (colors.isEmpty ? Self.fallback.colors : colors)[i % max(colors.count, 1)].color }

    /// Downsamples the image to 24×24, buckets pixels by color (4 levels per
    /// channel) and keeps the most populated buckets. Accurate enough for a
    /// mood, and instant compared with a real k-means.
    static func extract(from cgImage: CGImage, maxColors: Int = 4) -> ImagePalette {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .fallback }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var buckets: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let key = (Int(r * 3.99) << 4) | (Int(g * 3.99) << 2) | Int(b * 3.99)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.count += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        let colors = buckets.values
            .sorted { $0.count > $1.count }
            .prefix(maxColors)
            .map { e in RGB(r: e.r / Double(e.count), g: e.g / Double(e.count), b: e.b / Double(e.count)) }
        return colors.isEmpty ? .fallback : ImagePalette(colors: Array(colors))
    }

    static func extract(from image: NSImage) -> ImagePalette {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .fallback }
        return extract(from: cg)
    }
}

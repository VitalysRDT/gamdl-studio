import AppKit
import Foundation
import Testing
@testable import GamdlStudio

@Suite("Utilities")
struct UtilitiesTests {
    @Test("UTF-8 decoding of a character split across two reads")
    func utf8Split() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("Téléchargement é".utf8)
        // Split in the middle of the first "é" (2 bytes).
        let first = decoder.decode(Data(bytes[..<2]))
        let rest = decoder.decode(Data(bytes[2...]))
        #expect(first == "T")
        #expect(first + rest == "Téléchargement é")
        #expect(decoder.finish().isEmpty)
    }

    @Test("Invalid bytes do not stall the stream")
    func utf8Invalid() {
        var decoder = UTF8StreamDecoder()
        let out = decoder.decode(Data([0x41, 0xFF, 0xFE, 0xFD, 0x42]))
        #expect(out.hasPrefix("A"))
        #expect(out.hasSuffix("B"))
    }

    @Test("ANSI codes are stripped")
    func stripANSI() {
        #expect(TextPatterns.stripANSI("\u{1B}[36m▶ ok\u{1B}[0m \u{1B}[2K") == "▶ ok ")
    }

    @Test("Durations, pluralization and relative dates")
    func formatting() {
        #expect(Formatters.duration(seconds: 339.8) == "5:40")
        #expect(Formatters.duration(seconds: 3725) == "1:02:05")
        #expect(Formatters.duration(seconds: .nan) == "–:––")
        #expect(Formatters.longDuration(milliseconds: 54 * 60_000) == "54 min")
        #expect(Formatters.longDuration(milliseconds: 72 * 60_000) == "1 h 12 min")
        // Plural variations come from the String Catalog; French puts 0 in the "one" category.
        #expect(String(localized: "\(1) titres") == "1 titre")
        #expect(String(localized: "\(3) titres") == "3 titres")
        #expect(String(localized: "\(0) erreurs") == "0 erreur")
        #expect(String(localized: "\(2) déjà présents") == "2 déjà présents")
        let now = Date()
        #expect(Formatters.relative(now.addingTimeInterval(0.2), now: now) == "à l'instant")
        #expect(Formatters.relative(now.addingTimeInterval(-3600), now: now) == "il y a 1 heure")
    }

    @Test("English localization ships with its plural forms")
    func englishCatalog() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try #require(Bundle(path: path))
        #expect(String(localized: "\(1) titres", bundle: en) == "1 track")
        #expect(String(localized: "\(3) titres", bundle: en) == "3 tracks")
        // No 0 case here: the plural category follows the process locale (fr under the
        // test scheme), which files 0 under "one" even when reading the English table.
        #expect(String(localized: "File d'attente", bundle: en) == "Queue")
        #expect(String(localized: "Terminé avec \(1) erreurs", bundle: en) == "Finished with 1 error")
    }

    @Test("LRC lyrics to plain text")
    func lyrics() {
        let lrc = """
        [ar:Alicia Bridges]
        [ti:I Love the Nightlife]
        [00:12.34]I love the nightlife
        [00:15.00]I got to <00:15.20>boogie

        [01:02.00]

        [01:05.50]On the disco 'round
        """
        #expect(LyricsText.plain(fromLRC: lrc) == "I love the nightlife\nI got to boogie\n\nOn the disco 'round")
    }

    @Test("Tool versions", arguments: [
        ("gamdl, version 3.9.1", "3.9.1"),
        ("ffmpeg version 9.0.2 Copyright (c) 2000-2026", "9.0.2"),
        ("1.8.0\n", "1.8.0"),
        ("command not found", nil as String?),
    ])
    func versions(output: String, expected: String?) {
        #expect(Diagnostics.parseVersion(output) == expected)
    }

    @Test("Palette: dominant color of a solid image")
    func palette() throws {
        let side = 32
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(ctx.makeImage())
        let p = ImagePalette.extract(from: image)
        #expect(p.colors.count == 1)
        #expect(p.primary.r > 0.95 && p.primary.g < 0.05 && p.primary.b < 0.05)
        // Tamed: brightness clamped below 0.78.
        let tamed = p.primary.tamed()
        #expect(max(tamed.r, tamed.g, tamed.b) <= 0.79)
    }

    @Test("Relative luminance")
    func luminance() {
        #expect(ImagePalette.RGB(r: 1, g: 1, b: 1).luminance > 0.99)
        #expect(ImagePalette.RGB(r: 0, g: 0, b: 0).luminance < 0.01)
    }

    @Test("Tool lookup honors the override path and sets an explicit PATH")
    func toolLocator() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appending(path: "gamdl")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let locator = ToolLocator(searchDirectories: [URL(filePath: "/nexiste"), dir])
        #expect(locator.locate("gamdl") == tool)
        #expect(locator.locate("absent") == nil)
        #expect(locator.locate("gamdl", override: "/nexiste/gamdl") == nil)
        #expect(locator.locate("gamdl", override: tool.path) == tool)

        let env = locator.environment(extra: ["X": "1"])
        #expect(env["PATH"] == "/nexiste:\(dir.path)")
        #expect(env["PYTHONUNBUFFERED"] == "1")
        #expect(env["X"] == "1")
    }
}

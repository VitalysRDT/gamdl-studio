import AppKit
import AVFoundation
import ImageIO

/// In-memory artwork, loaded once and shared by all views.
///
/// Sources: artwork embedded in an m4a's tags (gamdl writes it at 5000 px),
/// an image file, or a remote URL (iTunes preview). Images are downsampled
/// to display size with ImageIO: decoding a 5000 px cover for a 180 px
/// thumbnail would cost ~100 MB of RAM.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        memory.countLimit = 600
    }

    func image(for source: URL, maxPixel: Int = 512) async -> NSImage? {
        let key = "\(source.absoluteString)#\(maxPixel)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        if let running = inFlight[key as String] { return await running.value }

        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard let data = await Self.loadData(from: source) else { return nil }
            return Self.thumbnail(from: data, maxPixel: maxPixel)
        }
        inFlight[key as String] = task
        let result = await task.value
        inFlight[key as String] = nil
        if let result { memory.setObject(result, forKey: key) }
        return result
    }

    private var palettes: [URL: ImagePalette] = [:]

    /// Dominant colors, computed from a 64 px thumbnail.
    func palette(for source: URL) async -> ImagePalette {
        if let hit = palettes[source] { return hit }
        guard let image = await image(for: source, maxPixel: 64) else { return .fallback }
        let palette = ImagePalette.extract(from: image)
        palettes[source] = palette
        return palette
    }

    private static func loadData(from source: URL) async -> Data? {
        if !source.isFileURL {
            return try? await URLSession.shared.data(from: source).0
        }
        let ext = source.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "webp"].contains(ext) {
            return try? Data(contentsOf: source)
        }
        return await embeddedArtwork(of: source)
    }

    /// Artwork stored in an m4a's iTunes tags (`covr` atom).
    static func embeddedArtwork(of file: URL) async -> Data? {
        let asset = AVURLAsset(url: file)
        guard let items = try? await asset.load(.metadata) else { return nil }
        let artwork = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first
            ?? AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).first
        guard let artwork else { return nil }
        return try? await artwork.load(.dataValue)
    }

    static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

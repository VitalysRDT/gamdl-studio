import Foundation

/// Summary shown before downloading: artwork, title, artist, tracks.
struct MediaPreview: Hashable, Sendable, Codable {
    struct Track: Hashable, Sendable, Codable, Identifiable {
        var id: String { "\(disc)-\(number)-\(title)" }
        let number: Int
        let disc: Int
        let title: String
        let durationMs: Int?
        let isExplicit: Bool
    }

    let kind: AppleMusicLink.Kind
    let title: String
    let artist: String?
    /// Parent album when the summary describes a song.
    let album: String?
    let artworkURL: URL?
    let genre: String?
    let releaseDate: Date?
    let trackCount: Int?
    let durationMs: Int?
    let isExplicit: Bool
    let tracks: [Track]

    var releaseYear: Int? {
        releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    var totalDurationMs: Int? {
        if let durationMs { return durationMs }
        let sum = tracks.compactMap(\.durationMs).reduce(0, +)
        return sum > 0 ? sum : nil
    }

    /// "Album · 1978 · Disco · 12 titres · 54 min"
    var summary: String {
        var parts = [kind.label]
        if let releaseYear { parts.append(String(releaseYear)) }
        if let genre { parts.append(genre) }
        if let trackCount, kind != .song { parts.append(Formatters.count(trackCount, "titre")) }
        if let total = totalDurationMs {
            parts.append(kind == .song ? Formatters.duration(milliseconds: total) : Formatters.longDuration(milliseconds: total))
        }
        return parts.joined(separator: " · ")
    }
}

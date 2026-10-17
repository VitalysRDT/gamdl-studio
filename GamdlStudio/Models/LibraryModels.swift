import Foundation

/// A downloaded audio (or video) file.
struct LibraryTrack: Hashable, Sendable, Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
    let trackNumber: Int?
    let discNumber: Int?
    let size: Int64
    let modifiedAt: Date
    /// Lyrics file (.lrc/.srt/.ttml) next to the track.
    let lyricsURL: URL?
    var isVideo: Bool { ["mp4", "m4v"].contains(url.pathExtension.lowercased()) }
}

/// An album folder as gamdl lays it out: `{album_artist}/{album}`,
/// `Compilations/{album}` or `Playlists/{author}`.
struct LibraryAlbum: Hashable, Sendable, Identifiable {
    enum Category: String, Sendable { case album, compilation, playlist }

    var id: URL { folder }
    let folder: URL
    let title: String
    let artist: String?
    let category: Category
    let tracks: [LibraryTrack]
    let coverFile: URL?

    var modifiedAt: Date { tracks.map(\.modifiedAt).max() ?? .distantPast }
    var totalSize: Int64 { tracks.reduce(0) { $0 + $1.size } }
    var artworkSource: URL? { coverFile ?? tracks.first?.url }
    var hasLyrics: Bool { tracks.contains { $0.lyricsURL != nil } }

    var subtitle: String {
        switch category {
        case .compilation: String(localized: "Compilation")
        case .playlist: artist.map { String(localized: "Playlist · \($0)") } ?? String(localized: "Playlist")
        case .album: artist ?? String(localized: "Artiste inconnu")
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmed
        guard !q.isEmpty else { return true }
        let haystack = ([title, artist ?? ""] + tracks.map(\.title)).joined(separator: " ")
        return haystack.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, artist, title, size
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: String(localized: "Ajouts récents")
        case .artist: String(localized: "Artiste")
        case .title: String(localized: "Titre")
        case .size: String(localized: "Taille")
        }
    }

    func sort(_ albums: [LibraryAlbum]) -> [LibraryAlbum] {
        switch self {
        case .recent: albums.sorted { $0.modifiedAt > $1.modifiedAt }
        case .artist:
            // Compilations (no artist) last, then by title.
            albums.sorted { a, b in
                let byArtist = (a.artist ?? "\u{10FFFF}").localizedStandardCompare(b.artist ?? "\u{10FFFF}")
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        case .title: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size: albums.sorted { $0.totalSize > $1.totalSize }
        }
    }
}

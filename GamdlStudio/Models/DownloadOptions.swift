import Foundation

/// Codecs that work with plain browser cookies. gamdl's other values
/// (alac, atmos, "legacy" aac…) require the FairPlay wrapper.
enum SongCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case aacWeb = "aac-web"
    case aacHeWeb = "aac-he-web"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .aacWeb: "AAC 256 kb/s"
        case .aacHeWeb: "HE-AAC 64 kb/s"
        }
    }
    var detail: String {
        switch self {
        case .aacWeb: String(localized: "Qualité Apple Music standard")
        case .aacHeWeb: String(localized: "Fichiers légers, pour l'écoute mobile")
        }
    }
}

enum LyricsFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case lrc, srt, ttml
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum LyricsMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case withAudio, none, lyricsOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .withAudio: String(localized: "Avec le son")
        case .none: String(localized: "Aucunes")
        case .lyricsOnly: String(localized: "Paroles seules")
        }
    }
}

/// What gamdl should grab when given an artist page. Without an answer,
/// gamdl would prompt in a terminal, which the app doesn't have.
enum ArtistSelection: String, CaseIterable, Codable, Sendable, Identifiable {
    case mainAlbums = "main-albums"
    case singlesEPs = "singles-eps"
    case compilationAlbums = "compilation-albums"
    case liveAlbums = "live-albums"
    case allAlbums = "all-albums"
    case topSongs = "top-songs"
    case musicVideos = "music-videos"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mainAlbums: String(localized: "Albums")
        case .singlesEPs: String(localized: "Singles et EP")
        case .compilationAlbums: String(localized: "Compilations")
        case .liveAlbums: String(localized: "Albums live")
        case .allAlbums: String(localized: "Tous les albums")
        case .topSongs: String(localized: "Top morceaux")
        case .musicVideos: String(localized: "Clips")
        }
    }
}

enum CoverSize: Int, CaseIterable, Codable, Sendable, Identifiable {
    case small = 600, medium = 1400, large = 3000, max = 5000
    var id: Int { rawValue }
    var label: String { "\(rawValue) px" }
}

/// Download settings, frozen at enqueue time so a preference change
/// doesn't affect a job that is already running.
struct DownloadOptions: Codable, Hashable, Sendable {
    var codec: SongCodec = .aacWeb
    var lyricsFormat: LyricsFormat = .lrc
    var lyricsMode: LyricsMode = .withAudio
    var coverSize: CoverSize = .max
    var saveCover = false
    var overwrite = false
    var artistSelection: ArtistSelection = .mainAlbums
}

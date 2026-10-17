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
        case .aacWeb: "Qualité Apple Music standard"
        case .aacHeWeb: "Fichiers légers, pour l'écoute mobile"
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
        case .withAudio: "Avec le son"
        case .none: "Aucunes"
        case .lyricsOnly: "Paroles seules"
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
        case .mainAlbums: "Albums"
        case .singlesEPs: "Singles et EP"
        case .compilationAlbums: "Compilations"
        case .liveAlbums: "Albums live"
        case .allAlbums: "Tous les albums"
        case .topSongs: "Top morceaux"
        case .musicVideos: "Clips"
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

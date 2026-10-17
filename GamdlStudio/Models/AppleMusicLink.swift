import Foundation

/// A parsed music.apple.com link: content kind, storefront and identifier.
///
/// Recognized forms:
///   /fr/album/<slug>/1443802477               → album
///   /fr/album/<slug>/1443802477?i=1443802513  → song (`i` wins)
///   /fr/song/<slug>/1443802513                → song
///   /fr/playlist/<slug>/pl.u-xxxx             → playlist
///   /fr/artist/<slug>/123                     → artist
///   /fr/music-video/<slug>/123                → music video
///   /library/playlist/p.xxxx                  → library playlist
struct AppleMusicLink: Hashable, Sendable, Identifiable, Codable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case song, album, playlist, artist, musicVideo, station, unknown

        var label: String {
            switch self {
            case .song: String(localized: "Morceau")
            case .album: String(localized: "Album")
            case .playlist: String(localized: "Playlist")
            case .artist: String(localized: "Artiste")
            case .musicVideo: String(localized: "Clip")
            case .station: String(localized: "Station")
            case .unknown: String(localized: "Lien")
            }
        }

        var symbol: String {
            switch self {
            case .song: "music.note"
            case .album: "square.stack"
            case .playlist: "music.note.list"
            case .artist: "music.microphone"
            case .musicVideo: "play.rectangle"
            case .station: "dot.radiowaves.left.and.right"
            case .unknown: "link"
            }
        }

        /// Stations are streams; gamdl can't download them.
        var isDownloadable: Bool { self != .station && self != .unknown }
    }

    let url: URL
    let kind: Kind
    /// Catalog country code ("fr", "us"…); `nil` for a library link.
    let storefront: String?
    let id: String
    /// Parent album ID when the link points to a track on an album.
    let albumID: String?
    let isLibrary: Bool

    var absoluteString: String { url.absoluteString }

    /// The iTunes Lookup API only knows numeric catalog IDs.
    var lookupID: String? {
        guard !isLibrary, id.allSatisfy(\.isNumber) else { return nil }
        switch kind {
        case .song, .album, .artist, .musicVideo: return id
        default: return nil
        }
    }

    /// gamdl only accepts numeric IDs, catalog playlists (`pl.` + 32 hex) and
    /// user playlists (`pl.u-…`). Anything else, such as personalized mixes
    /// (`pl.pm-…`), is expanded into song links before calling gamdl.
    var needsResolution: Bool {
        kind == .playlist && !isLibrary && !Self.gamdlPlaylistID.matches(id)
    }

    private static let gamdlPlaylistID = TextPatterns.regex(#"^(?:[0-9]+|pl\.[0-9a-z]{32}|pl\.u-[a-zA-Z0-9]+)$"#)

    private static let hosts: Set<String> = [
        "music.apple.com", "beta.music.apple.com", "classical.music.apple.com", "itunes.apple.com",
    ]

    init?(string raw: String) {
        let text = raw.trimmed
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), Self.hosts.contains(host)
        else { return nil }

        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        let isLibrary = parts[0] == "library"
        let storefront: String? = isLibrary ? nil : parts[0].lowercased()
        let typeIndex = 1
        guard parts.count > typeIndex else { return nil }
        let type = parts[typeIndex]
        guard let last = parts.last, parts.count > typeIndex + 1 else { return nil }

        let songParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "i" })?.value

        var kind: Kind
        switch type {
        case "album": kind = .album
        case "song": kind = .song
        case "playlist": kind = .playlist
        case "artist": kind = .artist
        case "music-video": kind = .musicVideo
        case "station": kind = .station
        default: kind = .unknown
        }

        var id = last
        var albumID: String?
        if kind == .album, let songParam, !songParam.isEmpty {
            kind = .song
            albumID = last
            id = songParam
        }

        // A storefront is two letters. "/search?term=" or an editorial page
        // must not pass as a downloadable link.
        if let storefront, storefront.count != 2 { return nil }

        self.url = url
        self.kind = kind
        self.storefront = storefront
        self.id = id
        self.albumID = albumID
        self.isLibrary = isLibrary
    }

    private static let urlPattern = TextPatterns.regex(#"https?://[^\s"'<>]+"#)

    /// Every Apple Music link in free text (drag and drop, multi-line paste),
    /// deduplicated, in order of appearance.
    static func extractAll(from text: String) -> [AppleMusicLink] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return urlPattern.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            // Sentence punctuation stuck to the end of the link.
            let candidate = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)»"))
            guard let link = AppleMusicLink(string: candidate), seen.insert(link.absoluteString).inserted else { return nil }
            return link
        }
    }
}

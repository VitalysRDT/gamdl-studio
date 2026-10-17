import Foundation

protocol MediaPreviewProviding: Sendable {
    func preview(for link: AppleMusicLink) async throws -> MediaPreview?
}

enum MediaPreviewError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): String(localized: "Apple Music a répondu \(code).")
        }
    }
}

/// Preview summary, fetched without an account or cookies.
///
/// - Songs, albums, artists, music videos: public iTunes Lookup API.
/// - Playlists (and everything else): the web page's Open Graph tags, the
///   only public source that describes them (Lookup doesn't know `pl.…` IDs).
struct MediaPreviewService: MediaPreviewProviding {
    var session: URLSession = .shared

    func preview(for link: AppleMusicLink) async throws -> MediaPreview? {
        if let request = Self.lookupURL(for: link) {
            let data = try await fetch(request)
            if let preview = try Self.parseLookup(data, for: link) { return preview }
        }
        let html = try await fetch(link.url)
        return Self.parseOpenGraph(String(decoding: html, as: UTF8.self), kind: link.kind)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("fr-FR,fr;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MediaPreviewError.http(http.statusCode)
        }
        return data
    }

    // MARK: - iTunes Lookup

    static func lookupURL(for link: AppleMusicLink) -> URL? {
        guard let id = link.lookupID else { return nil }
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: link.storefront ?? "fr")]
        // For an album, `entity=song` adds the track list to the response.
        if link.kind == .album { items.append(URLQueryItem(name: "entity", value: "song")) }
        items.append(URLQueryItem(name: "lang", value: "fr_fr"))
        c.queryItems = items
        return c.url
    }

    private struct LookupResponse: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let wrapperType: String?
            let kind: String?
            let trackName: String?
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
            let primaryGenreName: String?
            let releaseDate: String?
            let trackCount: Int?
            let trackNumber: Int?
            let discNumber: Int?
            let trackTimeMillis: Int?
            let trackExplicitness: String?
            let collectionExplicitness: String?
        }
    }

    static func parseLookup(_ data: Data, for link: AppleMusicLink) throws -> MediaPreview? {
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let main = response.results.first else { return nil }

        let tracks = response.results
            .filter { $0.wrapperType == "track" && link.kind == .album }
            .compactMap { item -> MediaPreview.Track? in
                guard let title = item.trackName else { return nil }
                return MediaPreview.Track(
                    number: item.trackNumber ?? 0,
                    disc: item.discNumber ?? 1,
                    title: title,
                    durationMs: item.trackTimeMillis,
                    isExplicit: item.trackExplicitness == "explicit"
                )
            }
            .sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }

        let title: String
        switch link.kind {
        case .album: title = main.collectionName ?? main.trackName ?? String(localized: "Album")
        case .artist: title = main.artistName ?? String(localized: "Artiste")
        default: title = main.trackName ?? main.collectionName ?? String(localized: "Sans titre")
        }

        return MediaPreview(
            kind: link.kind,
            title: title,
            artist: link.kind == .artist ? nil : main.artistName,
            album: link.kind == .song ? main.collectionName : nil,
            artworkURL: main.artworkUrl100.flatMap { upscaledArtwork($0) },
            genre: main.primaryGenreName,
            releaseDate: main.releaseDate.flatMap(parseDate),
            trackCount: link.kind == .album ? (main.trackCount ?? (tracks.isEmpty ? nil : tracks.count)) : nil,
            durationMs: link.kind == .song || link.kind == .musicVideo ? main.trackTimeMillis : nil,
            isExplicit: (main.trackExplicitness ?? main.collectionExplicitness) == "explicit",
            tracks: tracks
        )
    }

    /// Artwork URLs encode their size: "…/100x100bb.jpg".
    static func upscaledArtwork(_ raw: String, size: Int = 1200) -> URL? {
        let pattern = TextPatterns.regex(#"/\d+x\d+(bb|cc|sr)?\.(jpg|png|webp)$"#)
        let range = NSRange(raw.startIndex..., in: raw)
        let replaced = pattern.stringByReplacingMatches(in: raw, range: range, withTemplate: "/\(size)x\(size)bb.jpg")
        return URL(string: replaced)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - Open Graph

    static func parseOpenGraph(_ html: String, kind: AppleMusicLink.Kind) -> MediaPreview? {
        func meta(_ property: String) -> String? {
            // Attribute order varies: property/content or content/property.
            let p = NSRegularExpression.escapedPattern(for: property)
            let patterns = [
                #"<meta[^>]+(?:property|name)="\#(p)"[^>]+content="([^"]*)""#,
                #"<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="\#(p)""#,
            ]
            for pattern in patterns {
                if let value = TextPatterns.regex(pattern, options: .caseInsensitive).captures(in: html)?[1] {
                    return decodeEntities(value)
                }
            }
            return nil
        }

        guard let rawTitle = meta("og:title"), !rawTitle.isEmpty else { return nil }
        // "Disco Classics — Playlist – Apple Music" → title + optional author.
        let cleaned = rawTitle
            .replacingOccurrences(of: " - Apple Music", with: "")
            .replacingOccurrences(of: " – Apple Music", with: "")
            .replacingOccurrences(of: " sur Apple Music", with: "")
            .replacingOccurrences(of: " on Apple Music", with: "")
        let parts = cleaned.components(separatedBy: " par ")
        let title = parts.first?.trimmed ?? cleaned
        let author = parts.count > 1 ? parts.dropFirst().joined(separator: " par ").trimmed : nil

        return MediaPreview(
            kind: kind,
            title: title,
            artist: author,
            album: nil,
            artworkURL: meta("og:image").flatMap { URL(string: $0) },
            genre: nil,
            releaseDate: nil,
            trackCount: nil,
            durationMs: nil,
            isExplicit: false,
            tracks: []
        )
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let table = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, char) in table { out = out.replacingOccurrences(of: entity, with: char) }
        // Numeric entities (&#8217; …).
        let numeric = TextPatterns.regex(#"&#(\d+);"#)
        while let groups = numeric.captures(in: out), let whole = groups[0], let code = groups[1].flatMap(UInt32.init),
              let scalar = Unicode.Scalar(code) {
            out = out.replacingOccurrences(of: whole, with: String(Character(scalar)))
        }
        return out
    }
}

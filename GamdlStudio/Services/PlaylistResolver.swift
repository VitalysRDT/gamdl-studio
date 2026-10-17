import Foundation

/// A playlist expanded into its tracks.
struct ResolvedPlaylist: Decodable, Hashable, Sendable {
    struct Track: Decodable, Hashable, Sendable {
        let id: String
        let type: String?
        let name: String?
        let artist: String?
        let album: String?
        let durationMs: Int?
    }

    let id: String?
    let name: String?
    let curator: String?
    let artworkURL: URL?
    let storefront: String
    let tracks: [Track]

    /// One URL per track, in a form gamdl's parser accepts.
    var trackURLs: [String] {
        tracks.compactMap { track in
            guard track.id.allSatisfy(\.isNumber) else { return nil }
            let path = track.type == "music-videos" ? "music-video" : "song"
            return "https://music.apple.com/\(storefront)/\(path)/\(track.id)"
        }
    }

    func preview(kind: AppleMusicLink.Kind = .playlist) -> MediaPreview {
        MediaPreview(
            kind: kind,
            title: name ?? "Playlist",
            artist: curator,
            album: nil,
            artworkURL: artworkURL,
            genre: nil,
            releaseDate: nil,
            trackCount: tracks.count,
            durationMs: nil,
            isExplicit: false,
            tracks: tracks.enumerated().map { index, track in
                MediaPreview.Track(
                    number: index + 1,
                    disc: 1,
                    title: [track.name, track.artist].compactMap { $0 }.joined(separator: " · "),
                    durationMs: track.durationMs,
                    isExplicit: false
                )
            }
        )
    }
}

enum PlaylistResolverError: LocalizedError {
    case pythonNotFound(URL)
    case scriptMissing
    case failed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .pythonNotFound(let gamdl):
            "Impossible de trouver l'interpréteur Python de gamdl (\(gamdl.displayPath))."
        case .scriptMissing:
            "Script de résolution de playlist absent de l'app."
        case .failed(let message):
            "Lecture de la playlist impossible : \(message)"
        case .empty:
            "La playlist est vide."
        }
    }
}

/// Expands playlists gamdl refuses (personalized mixes such as Replay, `pl.pm-…`)
/// into song URLs, by running a small script with gamdl's own Python and API
/// client. Reusing gamdl's client keeps token handling in one place: when Apple
/// changes how the web token is published, updating gamdl fixes both.
enum PlaylistResolver {
    /// The Python interpreter gamdl runs with, read from its shebang
    /// (`#!/…/pipx/venvs/gamdl/bin/python -E`).
    static func python(forGamdl gamdl: URL) -> URL? {
        let script = gamdl.resolvingSymlinksInPath()
        guard let handle = try? FileHandle(forReadingFrom: script),
              let head = try? handle.read(upToCount: 512) else { return nil }
        try? handle.close()
        return interpreter(fromShebang: String(decoding: head, as: UTF8.self))
    }

    static func interpreter(fromShebang text: String) -> URL? {
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("#!") else { return nil }
        let parts = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        // `#!/usr/bin/env python3` style shebangs name the interpreter second.
        if first.hasSuffix("/env"), parts.count > 1 { return nil }
        let url = URL(filePath: first)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var bundledScript: URL? {
        Bundle.main.url(forResource: "resolve_playlist", withExtension: "py")
    }

    static func parse(_ data: Data) throws -> ResolvedPlaylist {
        let playlist = try JSONDecoder().decode(ResolvedPlaylist.self, from: data)
        guard !playlist.trackURLs.isEmpty else { throw PlaylistResolverError.empty }
        return playlist
    }

    static func resolve(
        _ link: AppleMusicLink,
        gamdl: URL,
        cookies: URL,
        environment: [String: String],
        script: URL? = bundledScript
    ) async throws -> ResolvedPlaylist {
        guard let python = python(forGamdl: gamdl) else { throw PlaylistResolverError.pythonNotFound(gamdl) }
        guard let script else { throw PlaylistResolverError.scriptMissing }

        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let result = try await ProcessRunner().run(
            executable: python,
            // -I: isolated mode, so nothing from the current directory shadows gamdl's modules.
            arguments: ["-I", script.path, cookies.path, link.storefront ?? "us", link.id],
            environment: environment,
            separateErrorOutput: { stderr.append($0) },
            onOutput: { stdout.append($0) }
        )
        guard result.exitCode == 0 else {
            let reason = stderr.value.split(whereSeparator: \.isNewline).last.map(String.init) ?? "code \(result.exitCode)"
            throw PlaylistResolverError.failed(reason)
        }
        return try parse(Data(stdout.value.utf8))
    }
}

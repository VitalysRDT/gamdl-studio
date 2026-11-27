import Foundation

/// Paths gamdl needs for a download.
struct GamdlPaths: Hashable, Sendable {
    var gamdl: URL
    var ffmpeg: URL?
    var cookies: URL
    var output: URL
    var temp: URL
    /// Which command line `gamdl` speaks (read from `gamdl --version`).
    var generation: GamdlGeneration = .v3
    /// gamdl's own Python, to run `gamdl_bridge.py` with (gamdl 4 only).
    var python: URL? = nil
    /// Sign-in and region settings (gamdl 4 only).
    var session = GamdlSession()
}

/// What actually gets launched: gamdl itself, or gamdl 4 through the bridge.
struct GamdlInvocation: Hashable, Sendable {
    let executable: URL
    let arguments: [String]
}

enum GamdlCommandError: LocalizedError, Equatable {
    case lyricsOnlyUnsupported
    /// A setting that only gamdl 4 understands, while gamdl 3 is installed.
    case needsGamdl4(String)
    case invalidWrapperURL(String)
    case playReadyNeedsDevice
    case deviceFileMissing(String)
    /// Personalized playlists are read with the cookies file, even in wrapper mode.
    case playlistNeedsCookies

    var errorDescription: String? {
        switch self {
        case .lyricsOnlyUnsupported:
            String(localized: "gamdl 4 ne sait plus télécharger les paroles seules. Choisis « Avec le son » ou « Aucunes » dans les réglages.")
        case .needsGamdl4(let setting):
            String(localized: "« \(setting) » demande gamdl 4. Mets gamdl à jour depuis l'onglet Diagnostic, ou change ce réglage.")
        case .invalidWrapperURL(let text):
            String(localized: "Adresse du wrapper invalide : \(text). Exemple : http://127.0.0.1:8080")
        case .playReadyNeedsDevice:
            String(localized: "PlayReady demande un fichier d'appareil .prd : choisis-le dans Réglages → Session.")
        case .deviceFileMissing(let path):
            String(localized: "Fichier d'appareil DRM introuvable : \(path)")
        case .playlistNeedsCookies:
            String(localized: "Les playlists personnalisées se lisent avec ton fichier de cookies, même en mode wrapper. Importe-le dans l'onglet Diagnostic.")
        }
    }
}

/// Builds the gamdl command line from the options exposed in the UI.
/// Pure, so it can be tested without launching gamdl.
enum GamdlCommand {
    /// `urls` replaces the link itself when it had to be expanded first
    /// (see `AppleMusicLink.needsResolution`).
    static func arguments(for link: AppleMusicLink, urls: [String]? = nil, options: DownloadOptions, paths: GamdlPaths) -> [String] {
        switch paths.generation {
        case .v3: arguments3(for: link, urls: urls, options: options, paths: paths)
        case .v4: arguments4(for: link, urls: urls, options: options, paths: paths)
        }
    }

    /// Options gamdl can't honor. Checked before launching, so an
    /// unsupported request never falls back to a plain audio download.
    static func validate(_ options: DownloadOptions, session: GamdlSession = GamdlSession(), for generation: GamdlGeneration) throws {
        switch generation {
        case .v4:
            if options.lyricsMode == .lyricsOnly { throw GamdlCommandError.lyricsOnlyUnsupported }
            if session.authMode == .wrapper, WrapperProbe.baseURL(session.wrapperURL) == nil {
                throw GamdlCommandError.invalidWrapperURL(session.wrapperURL)
            }
            // gamdl would prompt for the file, which needs a terminal.
            if session.drmBackend == .playready, session.expandedDevicePath == nil {
                throw GamdlCommandError.playReadyNeedsDevice
            }
        case .v3:
            if session.authMode == .wrapper { throw GamdlCommandError.needsGamdl4(AuthMode.wrapper.label) }
            // These change what gets downloaded; gamdl 3 would silently
            // download something else. gamdl 4's other settings are ignored.
            if let codec = options.songCodecPriority.first(where: { !$0.isWeb }) {
                throw GamdlCommandError.needsGamdl4(codec.label)
            }
            if !options.lyricsFormat.supportedByGamdl3 {
                throw GamdlCommandError.needsGamdl4(options.lyricsFormat.label)
            }
        }
    }

    /// `gamdl rip` options the app never passes, and why. Every other option
    /// of gamdl 4.1.2's `rip` is reachable from the settings (checked by
    /// tests against the recorded option list).
    static let excludedRipOptions: [String: String] = [
        "--select": "interactive menu, needs a terminal",
        "--ask-song-codec": "interactive menu, needs a terminal",
        "--ask-music-video-streams": "interactive menu, needs a terminal",
        "--ask-uploaded-video-quality": "interactive menu, needs a terminal",
        "--max-visible-tracks": "terminal display only; the app always passes --no-progress",
        "--song-codec": "a one-codec --song-codec-priority says the same, and gamdl ignores the priority once it is set",
        "--music-video-codec": "same as --song-codec, for videos",
        "--media-user-token": "would show in the process list, the log and the copied command; the cookies file carries the same token",
    ]

    /// gamdl 4 runs through `gamdl_bridge.py` when its Python is known, so the
    /// app gets live per-track progress; otherwise gamdl runs directly.
    static func invocation(
        for link: AppleMusicLink,
        urls: [String]? = nil,
        options: DownloadOptions,
        paths: GamdlPaths,
        bridge: URL? = bridgeScript
    ) -> GamdlInvocation {
        let args = arguments(for: link, urls: urls, options: options, paths: paths)
        if paths.generation == .v4, let python = paths.python, let bridge {
            // -I keeps the current directory out of sys.path; it also ignores
            // PYTHONUNBUFFERED, hence -u.
            return GamdlInvocation(executable: python, arguments: ["-I", "-u", bridge.path] + args)
        }
        return GamdlInvocation(executable: paths.gamdl, arguments: args)
    }

    static var bridgeScript: URL? {
        Bundle.main.url(forResource: "gamdl_bridge", withExtension: "py")
    }

    /// Environment changes gamdl 4 needs on top of the shared one.
    static func environment(_ base: [String: String], for generation: GamdlGeneration) -> [String: String] {
        guard generation == .v4 else { return base }
        var env = base
        // gamdl 4 prints "✓ Title: downloaded → /path" through Rich, which wraps
        // at COLUMNS and would split long paths across lines.
        env["COLUMNS"] = "10000"
        return env
    }

    // MARK: - gamdl 3

    private static func arguments3(for link: AppleMusicLink, urls: [String]?, options: DownloadOptions, paths: GamdlPaths) -> [String] {
        var args = [
            "--cookies-path", paths.cookies.path,
            "--output-path", paths.output.path,
            "--temp-path", paths.temp.path,
            "--song-codec-priority", options.codec.rawValue,
            "--synced-lyrics-format", options.lyricsFormat.rawValue,
            "--cover-size", String(options.coverSize.rawValue),
            "--log-level", "INFO",
        ]
        if let ffmpeg = paths.ffmpeg { args += ["--ffmpeg-path", ffmpeg.path] }
        if options.saveCover { args.append("--save-cover") }
        if options.overwrite { args.append("--overwrite") }
        switch options.lyricsMode {
        case .withAudio: break
        case .none: args.append("--no-synced-lyrics")
        case .lyricsOnly: args.append("--synced-lyrics-only")
        }
        // Without this choice, gamdl would open an interactive menu on stdin.
        if link.kind == .artist {
            args += ["--artist-auto-select", options.artistSelection.rawValue]
        }
        args += urls ?? [link.absoluteString]
        return args
    }

    // MARK: - gamdl 4

    /// Settings shown in the main screen are always passed, both ways, so
    /// ~/.gamdl/config.yml can't contradict the UI. The rest is passed only
    /// once set: until then gamdl's own configuration applies.
    private static func arguments4(for link: AppleMusicLink, urls: [String]?, options: DownloadOptions, paths: GamdlPaths) -> [String] {
        // Without an explicit mode, gamdl 4 opens its setup wizard, which
        // needs a terminal.
        var args = ["rip", "--auth-mode", paths.session.authMode.rawValue]
        switch paths.session.authMode {
        case .cookies: args += ["--cookies-path", paths.cookies.path]
        case .wrapper: args += ["--wrapper-url", paths.session.wrapperURL.trimmed]
        }
        let storefront = paths.session.storefront.trimmed.lowercased()
        if !storefront.isEmpty { args += ["--storefront", storefront] }
        if !paths.session.language.trimmed.isEmpty { args += ["--language", paths.session.language.trimmed] }
        if let backend = paths.session.drmBackend { args += ["--drm-backend", backend.rawValue] }
        if let device = paths.session.expandedDevicePath { args += ["--device-path", device] }
        args += [
            "--output-dir", paths.output.path,
            "--temp-path", paths.temp.path,
            "--song-codec-priority", options.songCodecPriority.map(\.rawValue).joined(separator: ","),
            "--lyrics-file-format", options.lyricsFormat.rawValue,
            "--embedded-cover-size", coverArgument(options.coverSize),
            "--file-cover-size", coverArgument(options.fileCoverSize ?? options.coverSize),
            // gamdl's default is 2; the app's default stays 1, like gamdl 3.
            "--concurrent-downloads", String(options.concurrentDownloads),
            // The live display draws nothing in a pipe.
            "--no-progress",
            options.saveCover ? "--save-cover" : "--no-save-cover",
            options.overwrite ? "--overwrite" : "--no-overwrite",
        ]
        if options.lyricsMode == .none { args.append("--no-lyrics-file") }
        if let format = options.embeddedLyricsFormat { args += ["--embedded-lyrics-format", format.rawValue] }
        if options.useAlbumDate { args.append("--use-album-date") }

        // Artwork and tags
        if let format = options.coverFormat { args += ["--cover-format", format.rawValue] }
        if !options.writeTags { args.append("--no-tag") }
        if !options.excludedTags.isEmpty { args += ["--exclude-tags", options.excludedTags.joined(separator: ",")] }
        if !options.dateTagTemplate.trimmed.isEmpty { args += ["--date-tag-template", options.dateTagTemplate.trimmed] }

        // Collections. Without a choice, gamdl would open an interactive menu
        // on an artist page.
        if link.kind == .artist {
            args += ["--artist-auto-select", options.artistSelections.map(\.rawValue).joined(separator: ",")]
        }
        if options.savePlaylist { args.append("--save-playlist") }

        // Music videos
        if !options.musicVideoCodecPriority.isEmpty {
            args += ["--music-video-codec-priority", options.musicVideoCodecPriority.map(\.rawValue).joined(separator: ",")]
        }
        if let container = options.musicVideoContainer { args += ["--music-video-container", container.rawValue] }
        if let height = options.maxVideoHeight { args += ["--max-height", String(height)] }
        if let quality = options.uploadedVideoQuality { args += ["--uploaded-video-quality", quality.rawValue] }

        // File names
        for (flag, value) in options.templates.arguments { args += [flag, value] }
        if let length = options.templates.truncate { args += ["--truncate", String(length)] }

        // Advanced
        if let segments = options.segmentConcurrency { args += ["--segment-concurrency", String(segments)] }
        if options.failFast { args.append("--fail-fast") }
        if !options.useDatabase { args.append("--no-database") }
        if !options.databasePath.trimmed.isEmpty {
            args += ["--database-path", (options.databasePath.trimmed as NSString).expandingTildeInPath]
        }
        if options.saveMetadata { args.append("--save-metadata") }
        if !options.showTracebacks { args.append("--no-tracebacks") }

        args += urls ?? [link.absoluteString]
        return args
    }

    private static func coverArgument(_ size: CoverSize) -> String {
        size == .max ? "max" : String(size.rawValue)
    }

    // MARK: - Display

    /// Human-readable command, for the "Copier la commande" button.
    static func shellLine(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@,+"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

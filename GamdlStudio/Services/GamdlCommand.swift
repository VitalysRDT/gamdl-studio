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
}

/// What actually gets launched: gamdl itself, or gamdl 4 through the bridge.
struct GamdlInvocation: Hashable, Sendable {
    let executable: URL
    let arguments: [String]
}

enum GamdlCommandError: LocalizedError, Equatable {
    case lyricsOnlyUnsupported

    var errorDescription: String? {
        switch self {
        case .lyricsOnlyUnsupported:
            String(localized: "gamdl 4 ne sait plus télécharger les paroles seules. Choisis « Avec le son » ou « Aucunes » dans les réglages.")
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
    static func validate(_ options: DownloadOptions, for generation: GamdlGeneration) throws {
        if options.lyricsMode == .lyricsOnly && !generation.supportsLyricsOnly {
            throw GamdlCommandError.lyricsOnlyUnsupported
        }
    }

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

    private static func arguments4(for link: AppleMusicLink, urls: [String]?, options: DownloadOptions, paths: GamdlPaths) -> [String] {
        let cover = options.coverSize == .max ? "max" : String(options.coverSize.rawValue)
        var args = [
            "rip",
            // Without an explicit mode, gamdl 4 opens its setup wizard, which
            // needs a terminal.
            "--auth-mode", "cookies",
            "--cookies-path", paths.cookies.path,
            "--output-dir", paths.output.path,
            "--temp-path", paths.temp.path,
            "--song-codec-priority", options.codec.rawValue,
            "--lyrics-file-format", options.lyricsFormat.rawValue,
            "--embedded-cover-size", cover,
            "--file-cover-size", cover,
            // The job follows one track at a time, as gamdl 3 downloaded them.
            "--concurrent-downloads", "1",
            // The live display draws nothing in a pipe.
            "--no-progress",
            // Explicit both ways, so ~/.gamdl/config.yml can't override the UI.
            options.saveCover ? "--save-cover" : "--no-save-cover",
            options.overwrite ? "--overwrite" : "--no-overwrite",
        ]
        if options.lyricsMode == .none { args.append("--no-lyrics-file") }
        if link.kind == .artist {
            args += ["--artist-auto-select", options.artistSelection.rawValue]
        }
        args += urls ?? [link.absoluteString]
        return args
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

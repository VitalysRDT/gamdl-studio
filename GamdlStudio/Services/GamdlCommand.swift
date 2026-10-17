import Foundation

/// Paths gamdl needs for a download.
struct GamdlPaths: Hashable, Sendable {
    var gamdl: URL
    var ffmpeg: URL?
    var cookies: URL
    var output: URL
    var temp: URL
}

/// Builds the gamdl command line from the options exposed in the UI.
/// Pure, so it can be tested without launching gamdl.
enum GamdlCommand {
    /// `urls` replaces the link itself when it had to be expanded first
    /// (see `AppleMusicLink.needsResolution`).
    static func arguments(for link: AppleMusicLink, urls: [String]? = nil, options: DownloadOptions, paths: GamdlPaths) -> [String] {
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

import Foundation
import Testing
@testable import GamdlStudio

@Suite("gamdl generation")
struct GamdlGenerationTests {
    @Test("Major version picks the command line", arguments: [
        ("3.9.1", GamdlGeneration.v3),
        ("3.10", .v3),
        ("2.8", .v3),
        ("4.0.1", .v4),
        ("4.1.2", .v4),
        ("5.0", .v4),
    ])
    func fromVersion(version: String, expected: GamdlGeneration) {
        #expect(GamdlGeneration(version: version) == expected)
    }

    @Test("Unreadable version is taken as the current gamdl")
    func unknownVersion() {
        #expect(GamdlGeneration(version: nil) == .v4)
        #expect(GamdlGeneration(version: "dev") == .v4)
    }

    @Test("Only gamdl 3 needs ffmpeg and has a lyrics-only mode")
    func capabilities() {
        #expect(GamdlGeneration.v3.needsFFmpeg && GamdlGeneration.v3.supportsLyricsOnly)
        #expect(!GamdlGeneration.v4.needsFFmpeg && !GamdlGeneration.v4.supportsLyricsOnly)
    }

    @Test("gamdl 4 version output: banner on stderr, then the version line", arguments: [
        // `gamdl --version` with stderr merged, as the app captures it (real 4.1.2 output).
        ("Gamdl 4.1.2\n\nGamdl, version 4.1.2\n", "4.1.2"),
        // Same, with stdout arriving first.
        ("Gamdl, version 4.1.2\nGamdl 4.1.2\n\n", "4.1.2"),
        // Banner alone.
        ("Gamdl 4.1.2\n", "4.1.2"),
        ("gamdl, version 3.9.1\n", "3.9.1"),
    ])
    func version4(output: String, expected: String) {
        #expect(Diagnostics.parseVersion(output) == expected)
    }

    @Test("The first version line wins (ffmpeg lists its compiler's version below)")
    func firstVersionLine() {
        let output = "ffmpeg version 9.1 Copyright (c) 2000-2026\nbuilt with Apple clang version 17.0.0\n"
        #expect(Diagnostics.parseVersion(output) == "9.1")
    }
}

@Suite("Diagnostics with gamdl 4")
struct Gamdl4DiagnosticsTests {
    private func report(gamdlVersion: String?, ffmpeg: Bool) -> DiagnosticReport {
        DiagnosticReport(
            gamdl: ToolCheck(name: "gamdl", path: URL(filePath: "/u/.local/bin/gamdl"), version: gamdlVersion),
            ffmpeg: ToolCheck(name: "ffmpeg", path: ffmpeg ? URL(filePath: "/opt/homebrew/bin/ffmpeg") : nil, version: nil),
            pipx: ToolCheck(name: "pipx", path: nil, version: nil),
            cookies: .valid(appleCookies: 3, expiresAt: nil),
            outputExists: true,
            outputWritable: true,
            freeSpace: nil,
            checkedAt: .now
        )
    }

    @Test("ffmpeg is optional with gamdl 4")
    func ffmpegOptional() {
        let r = report(gamdlVersion: "4.1.2", ffmpeg: false)
        #expect(r.generation == .v4)
        #expect(!r.needsFFmpeg)
        #expect(r.isReady)
        #expect(r.problems.isEmpty)
    }

    @Test("ffmpeg is still required with gamdl 3")
    func ffmpegRequired() {
        let r = report(gamdlVersion: "3.9.1", ffmpeg: false)
        #expect(r.generation == .v3)
        #expect(!r.isReady)
        #expect(r.problems == ["ffmpeg introuvable"])
    }

    @Test("Without gamdl there is no generation, and ffmpeg is asked for")
    func noGamdl() {
        let r = DiagnosticReport(
            gamdl: ToolCheck(name: "gamdl", path: nil, version: nil),
            ffmpeg: ToolCheck(name: "ffmpeg", path: nil, version: nil),
            pipx: ToolCheck(name: "pipx", path: nil, version: nil),
            cookies: .valid(appleCookies: 3, expiresAt: nil),
            outputExists: true, outputWritable: true, freeSpace: nil, checkedAt: .now
        )
        #expect(r.generation == nil)
        #expect(r.needsFFmpeg)
    }
}

@Suite("GamdlCommand with gamdl 4")
struct Gamdl4CommandTests {
    private let paths = GamdlPaths(
        gamdl: URL(filePath: "/u/.local/bin/gamdl"),
        ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"),
        cookies: URL(filePath: "/u/cookies.txt"),
        output: URL(filePath: "/u/Music/Gamdl Studio"),
        temp: URL(filePath: "/tmp/g"),
        generation: .v4
    )
    private let album = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test("Default options map to gamdl 4's rip command")
    func defaults() {
        let args = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: paths)
        #expect(args.first == "rip")
        #expect(value(after: "--auth-mode", in: args) == "cookies")
        #expect(value(after: "--cookies-path", in: args) == "/u/cookies.txt")
        #expect(value(after: "--output-dir", in: args) == "/u/Music/Gamdl Studio")
        #expect(value(after: "--temp-path", in: args) == "/tmp/g")
        #expect(value(after: "--song-codec-priority", in: args) == "aac-web")
        #expect(value(after: "--lyrics-file-format", in: args) == "lrc")
        #expect(value(after: "--embedded-cover-size", in: args) == "max")
        #expect(value(after: "--file-cover-size", in: args) == "max")
        #expect(value(after: "--concurrent-downloads", in: args) == "1")
        #expect(args.contains("--no-progress"))
        #expect(args.contains("--no-save-cover") && args.contains("--no-overwrite"))
        #expect(!args.contains("--no-lyrics-file") && !args.contains("--artist-auto-select"))
        #expect(args.last == album.absoluteString)
    }

    @Test("No gamdl 3 option leaks into a gamdl 4 command", arguments: [
        "--output-path", "--cover-size", "--log-level", "--ffmpeg-path",
        "--synced-lyrics-format", "--no-synced-lyrics", "--synced-lyrics-only",
    ])
    func noLegacyFlags(flag: String) {
        var o = DownloadOptions()
        o.lyricsMode = .none
        #expect(!GamdlCommand.arguments(for: album, options: o, paths: paths).contains(flag))
    }

    @Test("Enabled options")
    func flags() {
        var o = DownloadOptions()
        o.codec = .aacHeWeb
        o.saveCover = true
        o.overwrite = true
        o.lyricsMode = .none
        o.lyricsFormat = .ttml
        o.coverSize = .small
        let args = GamdlCommand.arguments(for: album, options: o, paths: paths)
        #expect(value(after: "--song-codec-priority", in: args) == "aac-he-web")
        #expect(value(after: "--embedded-cover-size", in: args) == "600")
        #expect(value(after: "--file-cover-size", in: args) == "600")
        #expect(value(after: "--lyrics-file-format", in: args) == "ttml")
        #expect(args.contains("--save-cover") && !args.contains("--no-save-cover"))
        #expect(args.contains("--overwrite") && !args.contains("--no-overwrite"))
        #expect(args.contains("--no-lyrics-file"))
    }

    @Test("Artist page uses auto-select with gamdl 4's category names", arguments: ArtistSelection.allCases)
    func artist(selection: ArtistSelection) {
        let artist = AppleMusicLink(string: "https://music.apple.com/fr/artist/x/9")!
        var o = DownloadOptions()
        o.artistSelection = selection
        let args = GamdlCommand.arguments(for: artist, options: o, paths: paths)
        // The names gamdl 4.1.2 accepts (gamdl.media.constants.ARTIST_AUTO_SELECT_NAMES).
        let accepted: Set = ["all-albums", "compilation-albums", "live-albums", "main-albums", "music-videos", "singles-eps", "top-songs"]
        #expect(accepted.contains(value(after: "--artist-auto-select", in: args) ?? ""))
    }

    @Test("Expanded playlist: one URL per song replaces the link")
    func expandedURLs() {
        let urls = ["https://music.apple.com/fr/song/111", "https://music.apple.com/fr/song/222"]
        let args = GamdlCommand.arguments(for: album, urls: urls, options: DownloadOptions(), paths: paths)
        #expect(Array(args.suffix(2)) == urls)
        #expect(!args.contains(album.absoluteString))
    }

    @Test("Lyrics only is refused with gamdl 4, accepted with gamdl 3")
    func lyricsOnly() throws {
        var o = DownloadOptions()
        o.lyricsMode = .lyricsOnly
        #expect(throws: GamdlCommandError.lyricsOnlyUnsupported) { try GamdlCommand.validate(o, for: .v4) }
        try GamdlCommand.validate(o, for: .v3)
        try GamdlCommand.validate(DownloadOptions(), for: .v4)
        #expect(GamdlCommandError.lyricsOnlyUnsupported.errorDescription?.contains("gamdl 4") == true)
    }

    @Test("gamdl 4 runs through the bridge when its Python is known")
    func bridged() {
        var p = paths
        p.python = URL(filePath: "/venv/bin/python")
        let bridge = URL(filePath: "/App/gamdl_bridge.py")
        let run = GamdlCommand.invocation(for: album, options: DownloadOptions(), paths: p, bridge: bridge)
        #expect(run.executable == URL(filePath: "/venv/bin/python"))
        #expect(Array(run.arguments.prefix(4)) == ["-I", "-u", "/App/gamdl_bridge.py", "rip"])
        #expect(Array(run.arguments.dropFirst(3)) == GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: p))
    }

    @Test("Without its Python, or without the script, gamdl 4 runs directly")
    func direct() {
        let bridge = URL(filePath: "/App/gamdl_bridge.py")
        let noPython = GamdlCommand.invocation(for: album, options: DownloadOptions(), paths: paths, bridge: bridge)
        #expect(noPython.executable == paths.gamdl)
        #expect(noPython.arguments.first == "rip")

        var p = paths
        p.python = URL(filePath: "/venv/bin/python")
        #expect(GamdlCommand.invocation(for: album, options: DownloadOptions(), paths: p, bridge: nil).executable == paths.gamdl)
    }

    @Test("gamdl 3 is never bridged")
    func v3Direct() {
        var p = paths
        p.generation = .v3
        p.python = URL(filePath: "/venv/bin/python")
        let run = GamdlCommand.invocation(for: album, options: DownloadOptions(), paths: p, bridge: URL(filePath: "/App/gamdl_bridge.py"))
        #expect(run.executable == p.gamdl)
        #expect(run.arguments.first == "--cookies-path")
    }

    @Test("The bundled bridge script ships with the app")
    func bundledBridge() {
        #expect(GamdlCommand.bridgeScript != nil)
    }

    @Test("gamdl 4 gets wide COLUMNS so Rich doesn't wrap paths; gamdl 3 is unchanged")
    func environment() {
        let base = ["COLUMNS": "240", "PATH": "/bin"]
        #expect(GamdlCommand.environment(base, for: .v4)["COLUMNS"] == "10000")
        #expect(GamdlCommand.environment(base, for: .v4)["PATH"] == "/bin")
        #expect(GamdlCommand.environment(base, for: .v3) == base)
    }

    @Test("Lyrics-only is not offered with gamdl 4, unless it is the current choice")
    func lyricsChoices() {
        #expect(LyricsMode.choices(for: .v4, keeping: .withAudio) == [.withAudio, .none])
        #expect(LyricsMode.choices(for: .v4, keeping: .lyricsOnly) == LyricsMode.allCases)
        #expect(LyricsMode.choices(for: .v3, keeping: .withAudio) == LyricsMode.allCases)
        #expect(LyricsMode.choices(for: nil, keeping: .withAudio) == LyricsMode.allCases)
        #expect(LyricsMode.lyricsOnly.isUnsupported(by: .v4))
        #expect(!LyricsMode.lyricsOnly.isUnsupported(by: .v3))
        #expect(!LyricsMode.lyricsOnly.isUnsupported(by: nil))
        #expect(!LyricsMode.none.isUnsupported(by: .v4))
    }
}

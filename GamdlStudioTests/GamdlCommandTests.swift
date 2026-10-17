import Foundation
import Testing
@testable import GamdlStudio

@Suite("GamdlCommand")
struct GamdlCommandTests {
    private let paths = GamdlPaths(
        gamdl: URL(filePath: "/u/.local/bin/gamdl"),
        ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"),
        cookies: URL(filePath: "/u/cookies.txt"),
        output: URL(filePath: "/u/Music/Gamdl Studio"),
        temp: URL(filePath: "/tmp/g")
    )
    private let album = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test("Default options")
    func defaults() {
        let args = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: paths)
        #expect(value(after: "--cookies-path", in: args) == "/u/cookies.txt")
        #expect(value(after: "--output-path", in: args) == "/u/Music/Gamdl Studio")
        #expect(value(after: "--temp-path", in: args) == "/tmp/g")
        #expect(value(after: "--song-codec-priority", in: args) == "aac-web")
        #expect(value(after: "--synced-lyrics-format", in: args) == "lrc")
        #expect(value(after: "--cover-size", in: args) == "5000")
        #expect(value(after: "--ffmpeg-path", in: args) == "/opt/homebrew/bin/ffmpeg")
        #expect(args.last == album.absoluteString)
        #expect(!args.contains("--save-cover") && !args.contains("--overwrite") && !args.contains("--artist-auto-select"))
    }

    @Test("Enabled options")
    func flags() {
        var o = DownloadOptions()
        o.codec = .aacHeWeb
        o.saveCover = true
        o.overwrite = true
        o.lyricsMode = .none
        o.coverSize = .small
        let args = GamdlCommand.arguments(for: album, options: o, paths: paths)
        #expect(value(after: "--song-codec-priority", in: args) == "aac-he-web")
        #expect(value(after: "--cover-size", in: args) == "600")
        #expect(args.contains("--save-cover"))
        #expect(args.contains("--overwrite"))
        #expect(args.contains("--no-synced-lyrics"))
    }

    @Test("Lyrics only")
    func lyricsOnly() {
        var o = DownloadOptions()
        o.lyricsMode = .lyricsOnly
        #expect(GamdlCommand.arguments(for: album, options: o, paths: paths).contains("--synced-lyrics-only"))
    }

    @Test("Artist page uses auto-select, never the interactive menu")
    func artist() {
        let artist = AppleMusicLink(string: "https://music.apple.com/fr/artist/x/9")!
        var o = DownloadOptions()
        o.artistSelection = .singlesEPs
        let args = GamdlCommand.arguments(for: artist, options: o, paths: paths)
        #expect(value(after: "--artist-auto-select", in: args) == "singles-eps")
    }

    @Test("No --ffmpeg-path when ffmpeg is not found")
    func noFFmpeg() {
        var p = paths
        p.ffmpeg = nil
        #expect(!GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: p).contains("--ffmpeg-path"))
    }

    @Test("Copyable shell line quotes only when needed")
    func shellLine() {
        let line = GamdlCommand.shellLine(executable: URL(filePath: "/bin/gamdl"), arguments: ["-o", "/a b", "it's", "plain"])
        #expect(line == #"/bin/gamdl -o '/a b' 'it'\''s' plain"#)
    }
}

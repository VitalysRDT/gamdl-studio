import Foundation
import Testing
@testable import GamdlStudio

/// `gamdl-4.1.2-rip-options.json` is gamdl 4.1.2's own option list, read from
/// its Click command (`gamdl.cli.main.main.commands["rip"].params`).
private struct RipOptions: Decodable {
    struct Option: Decodable {
        let flags: [String]
        let negations: [String]
        let isFlag: Bool
        let multiple: Bool
        let choices: [String]
    }

    let gamdl: String
    let options: [Option]
    let tagNames: [String]

    static func load() throws -> RipOptions {
        try JSONDecoder().decode(RipOptions.self, from: Data(try Fixture.text("gamdl-4.1.2-rip-options.json").utf8))
    }

    func option(_ flag: String) -> Option? {
        options.first { $0.flags.contains(flag) || $0.negations.contains(flag) }
    }
}

private let paths = GamdlPaths(
    gamdl: URL(filePath: "/u/.local/bin/gamdl"), ffmpeg: nil,
    cookies: URL(filePath: "/u/cookies.txt"), output: URL(filePath: "/u/Music/Gamdl Studio"),
    temp: URL(filePath: "/tmp/g"), generation: .v4
)
private let album = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!
private let artist = AppleMusicLink(string: "https://music.apple.com/fr/artist/x/9")!

/// Every setting moved away from its default.
private var everything: DownloadOptions {
    var o = DownloadOptions()
    o.songCodecPriority = [.atmos, .alac, .aacWeb]
    o.useAlbumDate = true
    o.lyricsFormat = .enhancedLrc
    o.lyricsMode = .none
    o.embeddedLyricsFormat = .text
    o.coverSize = .large
    o.fileCoverSize = .small
    o.coverFormat = .png
    o.saveCover = true
    o.writeTags = false
    o.excludedTags = ["comment", "copyright"]
    o.dateTagTemplate = "%Y"
    o.artistSelections = [.mainAlbums, .musicVideos]
    o.savePlaylist = true
    o.musicVideoCodecPriority = [.h265, .h264]
    o.musicVideoContainer = .mp4
    o.maxVideoHeight = 2160
    o.uploadedVideoQuality = .hd720
    o.overwrite = true
    o.templates = FileTemplates(
        albumFolder: "{artist}/{album}", compilationFolder: "C/{album}", noAlbumFolder: "{artist}",
        playlistFolder: "P", singleDiscFile: "{track:02d} - {title}", multiDiscFile: "{disc}{track:02d}",
        noAlbumFile: "{title} ({artist})", playlistFile: "{playlist_title} list", truncate: 80
    )
    o.segmentConcurrency = 4
    o.failFast = true
    o.useDatabase = false
    o.databasePath = "/u/index.sqlite3"
    o.saveMetadata = true
    o.showTracebacks = true
    return o
}

private func value(after flag: String, in args: [String]) -> String? {
    args.firstIndex(of: flag).map { args[$0 + 1] }
}

@Suite("gamdl 4 option coverage (against gamdl 4.1.2's own option list)")
struct Gamdl4OptionCoverageTests {
    private func flags(in args: [String]) -> Set<String> { Set(args.filter { $0.hasPrefix("--") }) }

    @Test("The recorded list is gamdl 4.1.2's rip command")
    func fixture() throws {
        let rip = try RipOptions.load()
        #expect(rip.gamdl == "4.1.2")
        #expect(rip.options.count == 53)
    }

    @Test("Every option the app passes exists in gamdl 4.1.2, with an accepted value")
    func emittedOptionsExist() throws {
        let rip = try RipOptions.load()
        let codecs = try #require(rip.option("--song-codec")).choices
        let videoCodecs = try #require(rip.option("--music-video-codec")).choices
        for options in [DownloadOptions(), everything] {
            for link in [album, artist] {
                let args = GamdlCommand.arguments(for: link, options: options, paths: paths)
                for (i, arg) in args.enumerated() where arg.hasPrefix("--") {
                    let option = try #require(rip.option(arg), "\(arg) isn't a gamdl 4.1.2 rip option")
                    if !option.isFlag {
                        let next = args[i + 1]
                        if !option.choices.isEmpty { #expect(option.choices.contains(next), "\(arg) \(next)") }
                        switch arg {
                        case "--song-codec-priority": #expect(next.split(separator: ",").allSatisfy { codecs.contains(String($0)) })
                        case "--music-video-codec-priority": #expect(next.split(separator: ",").allSatisfy { videoCodecs.contains(String($0)) })
                        case "--exclude-tags": #expect(next.split(separator: ",").allSatisfy { rip.tagNames.contains(String($0)) })
                        default: break
                        }
                    }
                }
            }
        }
    }

    @Test("Every gamdl 4.1.2 rip option is reachable from the settings, or excluded with a reason")
    func everyOptionCovered() throws {
        let rip = try RipOptions.load()
        let emitted = [DownloadOptions(), everything].flatMap { o in
            [album, artist].flatMap { flags(in: GamdlCommand.arguments(for: $0, options: o, paths: paths)) }
        }
        let reachable = Set(emitted)
        for option in rip.options {
            let names = option.flags + option.negations
            let covered = names.contains(where: reachable.contains)
            let excluded = names.contains { GamdlCommand.excludedRipOptions[$0] != nil }
            #expect(covered || excluded, "\(names) is neither passed nor excluded")
            #expect(!(covered && excluded), "\(names) is both passed and excluded")
        }
        // No stale exclusion.
        for flag in GamdlCommand.excludedRipOptions.keys {
            #expect(rip.option(flag) != nil, "\(flag) is excluded but gamdl has no such option")
        }
    }

    @Test("The app's enums match gamdl 4.1.2's choices exactly")
    func enumsMatchGamdl() throws {
        let rip = try RipOptions.load()
        #expect(SongCodec.allCases.map(\.rawValue) == rip.option("--song-codec")?.choices)
        #expect(LyricsFormat.allCases.map(\.rawValue).sorted() == rip.option("--lyrics-file-format")?.choices.sorted())
        #expect(LyricsFormat.allCases.map(\.rawValue).sorted() == rip.option("--embedded-lyrics-format")?.choices.sorted())
        #expect(MusicVideoCodec.allCases.map(\.rawValue) == rip.option("--music-video-codec")?.choices)
        #expect(VideoContainer.allCases.map(\.rawValue) == rip.option("--music-video-container")?.choices)
        #expect(UploadedVideoQuality.allCases.map(\.rawValue) == rip.option("--uploaded-video-quality")?.choices)
        #expect(CoverFormat.allCases.map(\.rawValue) == rip.option("--cover-format")?.choices)
        #expect(MetadataTags.all == rip.tagNames)
    }
}

@Suite("GamdlCommand: every gamdl 4 setting")
struct Gamdl4AllOptionsCommandTests {
    @Test("Defaults pass only the always-explicit settings, plus --no-tracebacks")
    func defaults() {
        let args = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: paths)
        let optional = [
            "--use-album-date", "--embedded-lyrics-format", "--cover-format", "--no-tag", "--exclude-tags",
            "--date-tag-template", "--save-playlist", "--music-video-codec-priority", "--music-video-container",
            "--max-height", "--uploaded-video-quality", "--truncate", "--segment-concurrency", "--fail-fast",
            "--no-database", "--database-path", "--save-metadata", "--album-folder-template",
            "--single-disc-file-template",
        ]
        for flag in optional { #expect(!args.contains(flag), "\(flag)") }
        #expect(args.contains("--no-tracebacks"))
        #expect(value(after: "--song-codec-priority", in: args) == "aac-web")
        #expect(value(after: "--file-cover-size", in: args) == "max")
    }

    @Test("Each setting maps to its gamdl option")
    func mapping() {
        let args = GamdlCommand.arguments(for: artist, options: everything, paths: paths)
        #expect(value(after: "--song-codec-priority", in: args) == "atmos,alac,aac-web")
        #expect(args.contains("--use-album-date"))
        #expect(value(after: "--lyrics-file-format", in: args) == "enhanced-lrc")
        #expect(value(after: "--embedded-lyrics-format", in: args) == "text")
        #expect(value(after: "--embedded-cover-size", in: args) == "3000")
        #expect(value(after: "--file-cover-size", in: args) == "600")
        #expect(value(after: "--cover-format", in: args) == "png")
        #expect(args.contains("--save-cover") && args.contains("--overwrite"))
        #expect(args.contains("--no-tag"))
        #expect(value(after: "--exclude-tags", in: args) == "comment,copyright")
        #expect(value(after: "--date-tag-template", in: args) == "%Y")
        #expect(value(after: "--artist-auto-select", in: args) == "main-albums,music-videos")
        #expect(args.contains("--save-playlist"))
        #expect(value(after: "--music-video-codec-priority", in: args) == "h265,h264")
        #expect(value(after: "--music-video-container", in: args) == "mp4")
        #expect(value(after: "--max-height", in: args) == "2160")
        #expect(value(after: "--uploaded-video-quality", in: args) == "720pHdVideo")
        #expect(value(after: "--album-folder-template", in: args) == "{artist}/{album}")
        #expect(value(after: "--compilation-folder-template", in: args) == "C/{album}")
        #expect(value(after: "--no-album-folder-template", in: args) == "{artist}")
        #expect(value(after: "--playlist-folder-template", in: args) == "P")
        #expect(value(after: "--single-disc-file-template", in: args) == "{track:02d} - {title}")
        #expect(value(after: "--multi-disc-file-template", in: args) == "{disc}{track:02d}")
        #expect(value(after: "--no-album-file-template", in: args) == "{title} ({artist})")
        #expect(value(after: "--playlist-file-template", in: args) == "{playlist_title} list")
        #expect(value(after: "--truncate", in: args) == "80")
        #expect(value(after: "--segment-concurrency", in: args) == "4")
        #expect(args.contains("--fail-fast"))
        #expect(args.contains("--no-database"))
        #expect(value(after: "--database-path", in: args) == "/u/index.sqlite3")
        #expect(args.contains("--save-metadata"))
        #expect(!args.contains("--no-tracebacks"))
        #expect(args.last == artist.absoluteString)
    }

    @Test("Blank text settings are not passed; ~ in the index path is expanded")
    func blankAndTilde() {
        var o = DownloadOptions()
        o.dateTagTemplate = "   "
        o.templates.albumFolder = " "
        o.databasePath = "~/index.sqlite3"
        let args = GamdlCommand.arguments(for: album, options: o, paths: paths)
        #expect(!args.contains("--date-tag-template") && !args.contains("--album-folder-template"))
        #expect(value(after: "--database-path", in: args) == FileManager.default.homeDirectoryForCurrentUser.appending(path: "index.sqlite3").path)
    }

    @Test("gamdl 3's command line is unchanged by the new settings")
    func gamdl3Unchanged() {
        var p = paths
        p.generation = .v3
        var o = everything
        o.songCodecPriority = [.aacHeWeb]
        o.lyricsFormat = .srt
        let args = GamdlCommand.arguments(for: artist, options: o, paths: p)
        var legacy = DownloadOptions()
        legacy.codec = .aacHeWeb
        legacy.lyricsFormat = .srt
        legacy.lyricsMode = .none
        legacy.coverSize = .large
        legacy.saveCover = true
        legacy.overwrite = true
        legacy.artistSelection = .mainAlbums
        #expect(args == GamdlCommand.arguments(for: artist, options: legacy, paths: p))
        #expect(value(after: "--artist-auto-select", in: args) == "main-albums")
    }

    @Test("gamdl 3 refuses what it would download differently", arguments: [
        SongCodec.atmos, .alac, .aac, .aacBinaural,
    ])
    func gamdl3Refuses(codec: SongCodec) {
        var o = DownloadOptions()
        o.songCodecPriority = [.aacWeb, codec]
        #expect(throws: GamdlCommandError.needsGamdl4(codec.label)) { try GamdlCommand.validate(o, for: .v3) }
        #expect(throws: Never.self) { try GamdlCommand.validate(o, for: .v4) }
    }

    @Test("gamdl 3 refuses lyrics formats it can't write")
    func gamdl3Lyrics() throws {
        var o = DownloadOptions()
        o.lyricsFormat = .text
        #expect(throws: GamdlCommandError.needsGamdl4(LyricsFormat.text.label)) { try GamdlCommand.validate(o, for: .v3) }
        o.lyricsFormat = .ttml
        try GamdlCommand.validate(o, for: .v3)
        #expect(GamdlCommandError.needsGamdl4("ALAC").errorDescription?.contains("« ALAC »") == true)
    }
}

@Suite("DownloadOptions")
struct DownloadOptionsTests {
    @Test("Settings saved by 1.x (single codec and artist category) still load")
    func legacyJSON() throws {
        // What DownloadOptions encoded to before this change, byte for byte.
        let json = #"{"codec":"aac-he-web","lyricsFormat":"srt","lyricsMode":"none","coverSize":600,"saveCover":true,"overwrite":true,"artistSelection":"singles-eps"}"#
        let o = try JSONDecoder().decode(DownloadOptions.self, from: Data(json.utf8))
        #expect(o.songCodecPriority == [.aacHeWeb])
        #expect(o.lyricsFormat == .srt)
        #expect(o.lyricsMode == .none)
        #expect(o.coverSize == .small)
        #expect(o.saveCover && o.overwrite)
        #expect(o.artistSelections == [.singlesEPs])
        #expect(o.useDatabase && !o.showTracebacks && o.writeTags)
    }

    @Test("An unknown or broken value falls back to its default, not every setting")
    func tolerant() throws {
        let json = #"{"songCodecPriority":["aac-web","future-codec"],"lyricsFormat":42,"saveCover":true,"maxVideoHeight":"tall","templates":{"albumFolder":"{album}","truncate":"x"}}"#
        let o = try JSONDecoder().decode(DownloadOptions.self, from: Data(json.utf8))
        #expect(o.songCodecPriority == [.aacWeb])
        #expect(o.lyricsFormat == .lrc)
        #expect(o.saveCover)
        #expect(o.maxVideoHeight == nil)
        #expect(o.templates.albumFolder == "{album}")
        #expect(o.templates.truncate == nil)
    }

    @Test("Empty JSON gives the defaults; unknown tag names are dropped")
    func emptyAndTags() throws {
        #expect(try JSONDecoder().decode(DownloadOptions.self, from: Data("{}".utf8)) == DownloadOptions())
        let o = try JSONDecoder().decode(DownloadOptions.self, from: Data(#"{"excludedTags":["genre","nope"]}"#.utf8))
        #expect(o.excludedTags == ["genre"])
    }

    @Test("Round trip keeps every setting")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(everything)
        #expect(try JSONDecoder().decode(DownloadOptions.self, from: data) == everything)
    }

    @Test("Codec priority: set, move, cut")
    func codecPriority() {
        var o = DownloadOptions()
        o.setCodec(.aacWeb, at: 1)            // already first: stays alone
        #expect(o.songCodecPriority == [.aacWeb])
        o.setCodec(.atmos, at: 0)
        #expect(o.songCodecPriority == [.atmos, .aacWeb])
        o.setCodec(.alac, at: 1)
        #expect(o.songCodecPriority == [.atmos, .alac, .aacWeb])
        o.setCodec(.aacWeb, at: 0)            // moved, not duplicated
        #expect(o.songCodecPriority == [.aacWeb, .atmos, .alac])
        o.setCodec(nil, at: 1)
        #expect(o.songCodecPriority == [.aacWeb])
        o.setCodec(nil, at: 0)                // the first one can't be removed
        #expect(o.songCodecPriority == [.aacWeb])
        #expect(o.codec(at: 0) == .aacWeb && o.codec(at: 1) == nil)
        o.songCodecPriority = [.atmos, .aacWeb]
        o.codec = .alac                       // replaces the first, keeps the fallback
        #expect(o.songCodecPriority == [.alac, .aacWeb])
    }

    @Test("Artist categories keep gamdl's order and at least one")
    func artists() {
        var o = DownloadOptions()
        o.setArtist(.musicVideos, included: true)
        o.setArtist(.singlesEPs, included: true)
        #expect(o.artistSelections == [.mainAlbums, .singlesEPs, .musicVideos])
        o.setArtist(.mainAlbums, included: false)
        o.setArtist(.singlesEPs, included: false)
        o.setArtist(.musicVideos, included: false)
        #expect(o.artistSelections == [.musicVideos])
        o.artistSelection = .topSongs
        #expect(o.artistSelections == [.topSongs])
    }

    @Test("Excluded tags keep gamdl's order")
    func tags() {
        var o = DownloadOptions()
        o.setTag("lyrics", excluded: true)
        o.setTag("title", excluded: true)
        #expect(o.excludedTags == ["title", "lyrics"])
        o.setTag("title", excluded: false)
        #expect(o.excludes(tag: "lyrics") && !o.excludes(tag: "title"))
    }

    @Test("Codec families and what needs the wrapper (measured with gamdl 4.1.2)")
    func codecs() {
        #expect(SongCodec.Family.allCases.flatMap(\.codecs).count == SongCodec.allCases.count)
        #expect(SongCodec.allCases.filter(\.needsWrapper) == [.alac, .alacLossless, .alacHiRes])
        #expect(!SongCodec.atmos.needsWrapper && SongCodec.atmos.family == .spatial)
        #expect(SongCodec.allCases.filter(\.isWeb) == [.aacWeb, .aacHeWeb])
        #expect(LyricsFormat.allCases.filter(\.supportedByGamdl3) == [.lrc, .srt, .ttml])
    }
}

@Suite("gamdl 4 failure messages")
struct Gamdl4FailureMessageTests {
    @Test("A refused ALAC license and a missing codec get explained (real gamdl 4.1.2 messages)")
    func human() {
        #expect(Gamdl4OutputParser.humanFailure("Unable to acquire or process decryption key").contains("wrapper"))
        #expect(Gamdl4OutputParser.humanFailure("Requested codec or stream unavailable").contains("codec de secours"))
        #expect(Gamdl4OutputParser.humanFailure("Something else") == "Something else")
    }

    @Test("Real failure row: ALAC with plain cookies")
    func alacRow() {
        var parser = Gamdl4OutputParser()
        let events = parser.feed("Errors (1):\n  ✗ BIRDS OF A FEATHER: Unable to acquire or process decryption key (DrmLicenseError)\n")
        #expect(events.first == .trackFailed(nil, title: "BIRDS OF A FEATHER"))
        #expect(events.last == .log(LogLine(level: .error, text: "BIRDS OF A FEATHER : " + Gamdl4OutputParser.humanFailure("decryption key"))))
    }
}

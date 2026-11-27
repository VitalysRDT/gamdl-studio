import Foundation

/// Song codecs, named as gamdl 4 names them (`gamdl.media.song.SongCodec`).
///
/// What works with plain browser cookies was measured with real downloads
/// (gamdl 4.1.2, 2026-11-27): AAC, binaural and Dolby Atmos do; ALAC is
/// refused by Apple's license server and needs gamdl's wrapper.
enum SongCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case aacWeb = "aac-web"
    case aacHeWeb = "aac-he-web"
    case aac = "aac"
    case aacHe = "aac-he"
    case aacBinaural = "aac-binaural"
    case aacDownmix = "aac-downmix"
    case aacHeBinaural = "aac-he-binaural"
    case aacHeDownmix = "aac-he-downmix"
    case atmos = "atmos"
    case ac3 = "ac3"
    case alac = "alac"
    case alacLossless = "alac-lossless"
    case alacHiRes = "alac-hires"

    enum Family: CaseIterable, Sendable {
        case stereo, spatial, lossless

        var label: String {
            switch self {
            case .stereo: String(localized: "Stéréo")
            case .spatial: String(localized: "Audio spatial")
            case .lossless: String(localized: "Sans perte")
            }
        }

        var codecs: [SongCodec] { SongCodec.allCases.filter { $0.family == self } }
    }

    var id: String { rawValue }

    var family: Family {
        switch self {
        case .aacWeb, .aacHeWeb, .aac, .aacHe: .stereo
        case .aacBinaural, .aacDownmix, .aacHeBinaural, .aacHeDownmix, .atmos, .ac3: .spatial
        case .alac, .alacLossless, .alacHiRes: .lossless
        }
    }

    var label: String {
        switch self {
        case .aacWeb: "AAC 256 kb/s"
        case .aacHeWeb: "HE-AAC 64 kb/s"
        case .aac: String(localized: "AAC (flux de l'app Musique)")
        case .aacHe: String(localized: "HE-AAC (flux de l'app Musique)")
        case .aacBinaural: String(localized: "AAC binaural")
        case .aacDownmix: String(localized: "AAC stéréo (mixage spatial)")
        case .aacHeBinaural: String(localized: "HE-AAC binaural")
        case .aacHeDownmix: String(localized: "HE-AAC stéréo (mixage spatial)")
        case .atmos: "Dolby Atmos"
        case .ac3: "Dolby Digital (AC-3)"
        case .alac: "ALAC"
        case .alacLossless: "ALAC 48 kHz"
        case .alacHiRes: "ALAC Hi-Res"
        }
    }

    var detail: String {
        switch self {
        case .aacWeb: String(localized: "Qualité Apple Music standard")
        case .aacHeWeb: String(localized: "Fichiers légers, pour l'écoute mobile")
        case .aac, .aacHe: String(localized: "Le flux que lit l'app Musique")
        case .aacBinaural, .aacHeBinaural: String(localized: "Audio spatial rendu pour un casque")
        case .aacDownmix, .aacHeDownmix: String(localized: "Mixage spatial ramené en stéréo")
        case .atmos: String(localized: "E-AC-3 5.1 à 768 kb/s, pour les morceaux mixés en Atmos")
        case .ac3: String(localized: "Pour les morceaux qui le proposent")
        case .alac: String(localized: "Sans perte, à la meilleure résolution disponible")
        case .alacLossless: String(localized: "Sans perte, jusqu'à 24 bits / 48 kHz")
        case .alacHiRes: String(localized: "Sans perte, jusqu'à 24 bits / 192 kHz")
        }
    }

    /// The two codecs gamdl 3 could download with plain cookies, and the only
    /// ones the app drives with gamdl 3.
    var isWeb: Bool { self == .aacWeb || self == .aacHeWeb }

    /// Apple refuses the Widevine license for ALAC: it takes the wrapper.
    var needsWrapper: Bool { family == .lossless }
}

enum LyricsFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case lrc, srt, ttml
    case enhancedLrc = "enhanced-lrc"
    case enhancedTtml = "enhanced-ttml"
    case text

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lrc, .srt, .ttml: rawValue.uppercased()
        case .enhancedLrc: String(localized: "LRC mot à mot")
        case .enhancedTtml: String(localized: "TTML mot à mot")
        case .text: String(localized: "Texte brut")
        }
    }

    /// gamdl 3 only writes these.
    var supportedByGamdl3: Bool { self == .lrc || self == .srt || self == .ttml }
}

enum LyricsMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case withAudio, none, lyricsOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .withAudio: String(localized: "Avec le son")
        case .none: String(localized: "Aucunes")
        case .lyricsOnly: String(localized: "Paroles seules")
        }
    }

    /// Modes the installed gamdl can honor. The current choice stays listed so
    /// the picker never shows a blank value; the queue refuses it if needed.
    static func choices(for generation: GamdlGeneration?, keeping current: LyricsMode) -> [LyricsMode] {
        allCases.filter { $0 != .lyricsOnly || (generation?.supportsLyricsOnly ?? true) || $0 == current }
    }

    /// Whether this choice can't be used with the installed gamdl.
    func isUnsupported(by generation: GamdlGeneration?) -> Bool {
        self == .lyricsOnly && generation?.supportsLyricsOnly == false
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
        case .mainAlbums: String(localized: "Albums")
        case .singlesEPs: String(localized: "Singles et EP")
        case .compilationAlbums: String(localized: "Compilations")
        case .liveAlbums: String(localized: "Albums live")
        case .allAlbums: String(localized: "Tous les albums")
        case .topSongs: String(localized: "Top morceaux")
        case .musicVideos: String(localized: "Clips")
        }
    }
}

enum CoverSize: Int, CaseIterable, Codable, Sendable, Identifiable {
    case small = 600, medium = 1400, large = 3000, max = 5000
    var id: Int { rawValue }
    var label: String { self == .max ? String(localized: "Maximale") : "\(rawValue) px" }
}

enum CoverFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case jpg, png
    var id: String { rawValue }
    var label: String { self == .jpg ? "JPEG" : "PNG" }
}

enum MusicVideoCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case h264, h265
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "H.265 (HEVC)" }
}

enum VideoContainer: String, CaseIterable, Codable, Sendable, Identifiable {
    case m4v, mp4
    var id: String { rawValue }
    var label: String { "." + rawValue }
}

enum UploadedVideoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case hd1080 = "1080pHdVideo"
    case hd720 = "720pHdVideo"
    case sdPlusAudio = "sdVideoWithPlusAudio"
    case sd = "sdVideo"
    case sd480 = "sd480pVideo"
    case provisional = "provisionalUploadVideo"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hd1080: "1080p HD"
        case .hd720: "720p HD"
        case .sdPlusAudio: String(localized: "SD, son amélioré")
        case .sd: "SD"
        case .sd480: "SD 480p"
        case .provisional: String(localized: "Version provisoire")
        }
    }
}

/// Metadata fields gamdl 4 can leave out (`gamdl.cli.options.TAG_NAMES`).
enum MetadataTags {
    static let all = [
        "title", "artist", "album", "album_artist", "title_id", "artist_id", "album_id",
        "track_number", "track_total", "disc_number", "disc_total", "release_date", "genre",
        "genre_id", "isrc", "xid", "title_sort", "artist_sort", "album_sort", "composer",
        "composer_id", "composer_sort", "copyright", "comment", "compilation", "gapless",
        "explicit", "storefront", "media_type", "rating", "lyrics", "cover",
    ]
}

/// gamdl 4's folder and file name templates. Empty: gamdl's own (config.yml
/// or built-in default) applies.
struct FileTemplates: Codable, Hashable, Sendable {
    var albumFolder = ""
    var compilationFolder = ""
    var noAlbumFolder = ""
    var playlistFolder = ""
    var singleDiscFile = ""
    var multiDiscFile = ""
    var noAlbumFile = ""
    var playlistFile = ""
    /// Maximum length of each path component.
    var truncate: Int?

    /// gamdl 4.1.2's defaults, shown as placeholders.
    static let gamdlDefaults = FileTemplates(
        albumFolder: "{album_artist}/{album}",
        compilationFolder: "Compilations/{album}",
        noAlbumFolder: "{artist}/Unknown Album",
        playlistFolder: "Playlists/{playlist_artist}",
        singleDiscFile: "{track:02d} {title}",
        multiDiscFile: "{disc}-{track:02d} {title}",
        noAlbumFile: "{title}",
        playlistFile: "{playlist_title}"
    )

    /// Variables gamdl 4 fills in (`gamdl.download.paths`).
    static let variables = [
        "album", "album_artist", "album_id", "artist", "artist_id", "composer", "composer_id",
        "date", "disc", "disc_total", "media_type", "playlist_artist", "playlist_id",
        "playlist_title", "playlist_track", "title", "title_id", "track", "track_total",
    ]

    /// (gamdl option, value) for every template that is set.
    var arguments: [(flag: String, value: String)] {
        [
            ("--album-folder-template", albumFolder),
            ("--compilation-folder-template", compilationFolder),
            ("--no-album-folder-template", noAlbumFolder),
            ("--playlist-folder-template", playlistFolder),
            ("--single-disc-file-template", singleDiscFile),
            ("--multi-disc-file-template", multiDiscFile),
            ("--no-album-file-template", noAlbumFile),
            ("--playlist-file-template", playlistFile),
        ].filter { !$0.1.trimmed.isEmpty }.map { ($0.0, $0.1.trimmed) }
    }

    init(
        albumFolder: String = "", compilationFolder: String = "", noAlbumFolder: String = "",
        playlistFolder: String = "", singleDiscFile: String = "", multiDiscFile: String = "",
        noAlbumFile: String = "", playlistFile: String = "", truncate: Int? = nil
    ) {
        self.albumFolder = albumFolder
        self.compilationFolder = compilationFolder
        self.noAlbumFolder = noAlbumFolder
        self.playlistFolder = playlistFolder
        self.singleDiscFile = singleDiscFile
        self.multiDiscFile = multiDiscFile
        self.noAlbumFile = noAlbumFile
        self.playlistFile = playlistFile
        self.truncate = truncate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil ?? "" }
        albumFolder = text(.albumFolder)
        compilationFolder = text(.compilationFolder)
        noAlbumFolder = text(.noAlbumFolder)
        playlistFolder = text(.playlistFolder)
        singleDiscFile = text(.singleDiscFile)
        multiDiscFile = text(.multiDiscFile)
        noAlbumFile = text(.noAlbumFile)
        playlistFile = text(.playlistFile)
        truncate = (try? c.decodeIfPresent(Int.self, forKey: .truncate)) ?? nil
    }
}

/// Download settings, frozen at enqueue time so a preference change
/// doesn't affect a job that is already running.
///
/// Settings added for gamdl 4 default to "leave it to gamdl": `nil`, empty
/// or the gamdl default, so they are only passed once the user sets them and
/// ~/.gamdl/config.yml keeps applying otherwise.
struct DownloadOptions: Codable, Hashable, Sendable {
    // Audio
    /// In order of preference. gamdl takes the first one the song exists in.
    var songCodecPriority: [SongCodec] = [.aacWeb]
    var useAlbumDate = false

    // Lyrics
    var lyricsFormat: LyricsFormat = .lrc
    var lyricsMode: LyricsMode = .withAudio
    var embeddedLyricsFormat: LyricsFormat?

    // Artwork
    var coverSize: CoverSize = .max
    /// Size of the separate Cover file; `nil`: same as the embedded one.
    var fileCoverSize: CoverSize?
    var coverFormat: CoverFormat?
    var saveCover = false

    // Tags
    var writeTags = true
    var excludedTags: [String] = []
    var dateTagTemplate = ""

    // Collections
    var artistSelections: [ArtistSelection] = [.mainAlbums]
    var savePlaylist = false

    // Music videos
    /// Empty: gamdl's default order.
    var musicVideoCodecPriority: [MusicVideoCodec] = []
    var musicVideoContainer: VideoContainer?
    var maxVideoHeight: Int?
    var uploadedVideoQuality: UploadedVideoQuality?

    // Files
    var overwrite = false
    var templates = FileTemplates()

    // Advanced
    var segmentConcurrency: Int?
    var failFast = false
    var useDatabase = true
    var databasePath = ""
    var saveMetadata = false
    /// gamdl warns that its tracebacks may contain signed URLs and account
    /// details, so they stay out of the log unless asked for.
    var showTracebacks = false

    static let videoHeights = [480, 720, 1080, 1440, 2160]
    static let segmentConcurrencies = [1, 2, 4, 8, 16, 32]
    static let truncateLengths = [40, 60, 80, 100, 150, 200]

    /// First codec. Setting it keeps the fallbacks.
    var codec: SongCodec {
        get { songCodecPriority.first ?? .aacWeb }
        set { songCodecPriority = [newValue] + songCodecPriority.dropFirst().filter { $0 != newValue } }
    }

    /// First artist category, for gamdl 3 (one choice only).
    var artistSelection: ArtistSelection {
        get { artistSelections.first ?? .mainAlbums }
        set { artistSelections = [newValue] }
    }

    /// Codec at a position of the priority list, `nil` past its end.
    func codec(at index: Int) -> SongCodec? {
        songCodecPriority.indices.contains(index) ? songCodecPriority[index] : nil
    }

    /// Sets (or, with `nil`, removes from there on) the codec at a position.
    /// A codec appears once: picking one already listed moves it.
    mutating func setCodec(_ codec: SongCodec?, at index: Int) {
        var list = songCodecPriority
        guard let codec else {
            if index > 0, index < list.count { list.removeSubrange(index...) }
            songCodecPriority = list.isEmpty ? [.aacWeb] : list
            return
        }
        list.removeAll { $0 == codec }
        list.insert(codec, at: min(index, list.count))
        songCodecPriority = list
    }

    func includesArtist(_ selection: ArtistSelection) -> Bool { artistSelections.contains(selection) }

    /// Adds or removes a category, keeping gamdl's order and at least one.
    mutating func setArtist(_ selection: ArtistSelection, included: Bool) {
        var set = Set(artistSelections)
        if included { set.insert(selection) } else { set.remove(selection) }
        guard !set.isEmpty else { return }
        artistSelections = ArtistSelection.allCases.filter(set.contains)
    }

    func excludes(tag: String) -> Bool { excludedTags.contains(tag) }

    mutating func setTag(_ tag: String, excluded: Bool) {
        var set = Set(excludedTags)
        if excluded { set.insert(tag) } else { set.remove(tag) }
        excludedTags = MetadataTags.all.filter(set.contains)
    }

    init() {}

    // MARK: - Decoding settings saved by earlier versions

    private enum CodingKeys: String, CodingKey {
        case songCodecPriority, useAlbumDate, lyricsFormat, lyricsMode, embeddedLyricsFormat
        case coverSize, fileCoverSize, coverFormat, saveCover, writeTags, excludedTags, dateTagTemplate
        case artistSelections, savePlaylist, musicVideoCodecPriority, musicVideoContainer, maxVideoHeight
        case uploadedVideoQuality, overwrite, templates, segmentConcurrency, failFast, useDatabase
        case databasePath, saveMetadata, showTracebacks
    }

    /// Keys of the 1.x format, which had a single codec and artist category.
    private enum LegacyKeys: String, CodingKey { case codec, artistSelection }

    /// Settings are decoded field by field: an unknown or missing value falls
    /// back to its default instead of resetting every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let d = DownloadOptions()

        if let list = value(.songCodecPriority, [SongCodec].self), !list.isEmpty {
            songCodecPriority = list
        } else if let single = (try? legacy.decodeIfPresent(SongCodec.self, forKey: .codec)) ?? nil {
            songCodecPriority = [single]
        }
        useAlbumDate = value(.useAlbumDate, Bool.self) ?? d.useAlbumDate
        lyricsFormat = value(.lyricsFormat, LyricsFormat.self) ?? d.lyricsFormat
        lyricsMode = value(.lyricsMode, LyricsMode.self) ?? d.lyricsMode
        embeddedLyricsFormat = value(.embeddedLyricsFormat, LyricsFormat.self)
        coverSize = value(.coverSize, CoverSize.self) ?? d.coverSize
        fileCoverSize = value(.fileCoverSize, CoverSize.self)
        coverFormat = value(.coverFormat, CoverFormat.self)
        saveCover = value(.saveCover, Bool.self) ?? d.saveCover
        writeTags = value(.writeTags, Bool.self) ?? d.writeTags
        excludedTags = (value(.excludedTags, [String].self) ?? []).filter(MetadataTags.all.contains)
        dateTagTemplate = value(.dateTagTemplate, String.self) ?? d.dateTagTemplate
        if let list = value(.artistSelections, [ArtistSelection].self), !list.isEmpty {
            artistSelections = list
        } else if let single = (try? legacy.decodeIfPresent(ArtistSelection.self, forKey: .artistSelection)) ?? nil {
            artistSelections = [single]
        }
        savePlaylist = value(.savePlaylist, Bool.self) ?? d.savePlaylist
        musicVideoCodecPriority = value(.musicVideoCodecPriority, [MusicVideoCodec].self) ?? d.musicVideoCodecPriority
        musicVideoContainer = value(.musicVideoContainer, VideoContainer.self)
        maxVideoHeight = value(.maxVideoHeight, Int.self)
        uploadedVideoQuality = value(.uploadedVideoQuality, UploadedVideoQuality.self)
        overwrite = value(.overwrite, Bool.self) ?? d.overwrite
        templates = value(.templates, FileTemplates.self) ?? d.templates
        segmentConcurrency = value(.segmentConcurrency, Int.self)
        failFast = value(.failFast, Bool.self) ?? d.failFast
        useDatabase = value(.useDatabase, Bool.self) ?? d.useDatabase
        databasePath = value(.databasePath, String.self) ?? d.databasePath
        saveMetadata = value(.saveMetadata, Bool.self) ?? d.saveMetadata
        showTracebacks = value(.showTracebacks, Bool.self) ?? d.showTracebacks
    }
}

import Foundation
import Testing
@testable import GamdlStudio

@Suite("MediaPreviewService")
struct MediaPreviewServiceTests {
    private let album = AppleMusicLink(string: "https://music.apple.com/fr/album/the-collection/1443802477")!
    private let song = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1443802477?i=1443802513")!
    private let playlist = AppleMusicLink(string: "https://music.apple.com/fr/playlist/disco/pl.u-1")!

    @Test("Lookup URL: album with tracks, single song, no Lookup for playlists")
    func lookupURL() throws {
        let a = try #require(MediaPreviewService.lookupURL(for: album)?.absoluteString)
        #expect(a.contains("id=1443802477") && a.contains("country=fr") && a.contains("entity=song"))
        let s = try #require(MediaPreviewService.lookupURL(for: song)?.absoluteString)
        #expect(s.contains("id=1443802513") && !s.contains("entity="))
        #expect(MediaPreviewService.lookupURL(for: playlist) == nil)
    }

    @Test("Album Lookup response: title, artist, sorted tracks")
    func parseAlbum() throws {
        let json = """
        {"resultCount":3,"results":[
          {"wrapperType":"collection","collectionName":"Alicia Bridges: The Collection","artistName":"Alicia Bridges",
           "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music/x/100x100bb.jpg","primaryGenreName":"Disco",
           "releaseDate":"1978-01-01T08:00:00Z","trackCount":2,"collectionExplicitness":"notExplicit"},
          {"wrapperType":"track","kind":"song","trackName":"Body Heat","trackNumber":2,"discNumber":1,"trackTimeMillis":200000},
          {"wrapperType":"track","kind":"song","trackName":"I Love the Nightlife","trackNumber":1,"discNumber":1,"trackTimeMillis":339834,"trackExplicitness":"notExplicit"}
        ]}
        """
        let p = try #require(try MediaPreviewService.parseLookup(Data(json.utf8), for: album))
        #expect(p.title == "Alicia Bridges: The Collection")
        #expect(p.artist == "Alicia Bridges")
        #expect(p.tracks.map(\.title) == ["I Love the Nightlife", "Body Heat"])
        #expect(p.trackCount == 2)
        #expect(p.releaseYear == 1978)
        #expect(p.artworkURL?.absoluteString.hasSuffix("/1200x1200bb.jpg") == true)
        #expect(p.summary == "Album · 1978 · Disco · 2 titres · 9 min")
    }

    @Test("Song Lookup response: parent album and duration")
    func parseSong() throws {
        let json = """
        {"resultCount":1,"results":[{"wrapperType":"track","kind":"song","trackName":"I Love the Nightlife (Disco 'Round)",
          "collectionName":"The Collection","artistName":"Alicia Bridges","trackTimeMillis":339834,"trackExplicitness":"explicit"}]}
        """
        let p = try #require(try MediaPreviewService.parseLookup(Data(json.utf8), for: song))
        #expect(p.title == "I Love the Nightlife (Disco 'Round)")
        #expect(p.album == "The Collection")
        #expect(p.isExplicit)
        #expect(p.tracks.isEmpty)
        #expect(p.summary == "Morceau · 5:40")
    }

    @Test("Empty response gives no preview")
    func empty() throws {
        #expect(try MediaPreviewService.parseLookup(Data(#"{"resultCount":0,"results":[]}"#.utf8), for: album) == nil)
    }

    @Test("Playlist Open Graph tags with attributes in either order")
    func openGraph() throws {
        let html = """
        <html><head>
        <meta property="og:title" content="Disco Classics par Apple Music Disco - Apple Music">
        <meta content="https://is1-ssl.mzstatic.com/image/thumb/x/1200x630cw.png" property="og:image">
        </head></html>
        """
        let p = try #require(MediaPreviewService.parseOpenGraph(html, kind: .playlist))
        #expect(p.title == "Disco Classics")
        #expect(p.artist == "Apple Music Disco")
        #expect(p.artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/1200x630cw.png")
        #expect(MediaPreviewService.parseOpenGraph("<html></html>", kind: .playlist) == nil)
    }

    @Test("HTML entities", arguments: [
        ("Rock &amp; Roll", "Rock & Roll"), ("L&#39;été", "L'été"), ("Don&#8217;t", "Don\u{2019}t"), ("&quot;x&quot;", "\"x\""),
    ])
    func entities(input: String, expected: String) {
        #expect(MediaPreviewService.decodeEntities(input) == expected)
    }

    @Test("Upscaling artwork URLs")
    func upscale() {
        #expect(MediaPreviewService.upscaledArtwork("https://a/b/100x100bb.jpg", size: 600)?.absoluteString == "https://a/b/600x600bb.jpg")
        #expect(MediaPreviewService.upscaledArtwork("https://a/b/60x60.png", size: 600)?.absoluteString == "https://a/b/600x600bb.jpg")
    }
}

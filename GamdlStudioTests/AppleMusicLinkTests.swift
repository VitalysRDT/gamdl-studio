import Foundation
import Testing
@testable import GamdlStudio

@Suite("AppleMusicLink")
struct AppleMusicLinkTests {
    @Test("Album link with ?i= becomes a song link")
    func songInAlbum() throws {
        let link = try #require(AppleMusicLink(string: "https://music.apple.com/fr/album/i-love-the-nightlife-disco-round/1443802477?i=1443802513"))
        #expect(link.kind == .song)
        #expect(link.id == "1443802513")
        #expect(link.albumID == "1443802477")
        #expect(link.storefront == "fr")
        #expect(link.lookupID == "1443802513")
    }

    @Test("Album without an i parameter")
    func album() throws {
        let link = try #require(AppleMusicLink(string: "https://music.apple.com/us/album/the-collection/1443802477"))
        #expect(link.kind == .album)
        #expect(link.id == "1443802477")
        #expect(link.albumID == nil)
    }

    @Test("Album without a slug")
    func albumWithoutSlug() throws {
        let link = try #require(AppleMusicLink(string: "https://music.apple.com/fr/album/1443802477"))
        #expect(link.kind == .album)
        #expect(link.id == "1443802477")
    }

    @Test("Playlist has no Lookup ID")
    func playlist() throws {
        let link = try #require(AppleMusicLink(string: "https://music.apple.com/fr/playlist/disco-classics/pl.u-abc123"))
        #expect(link.kind == .playlist)
        #expect(link.id == "pl.u-abc123")
        #expect(link.lookupID == nil)
    }

    @Test("Library playlist has no storefront")
    func libraryPlaylist() throws {
        let link = try #require(AppleMusicLink(string: "https://music.apple.com/library/playlist/p.XYZ"))
        #expect(link.kind == .playlist)
        #expect(link.isLibrary)
        #expect(link.storefront == nil)
        #expect(link.lookupID == nil)
    }

    @Test("Artist, music video, station and song kinds", arguments: [
        ("https://music.apple.com/fr/artist/alicia-bridges/123", AppleMusicLink.Kind.artist),
        ("https://music.apple.com/fr/music-video/thing/456", .musicVideo),
        ("https://music.apple.com/fr/station/disco/ra.789", .station),
        ("https://music.apple.com/fr/song/thing/111", .song),
    ])
    func kinds(url: String, kind: AppleMusicLink.Kind) throws {
        #expect(try #require(AppleMusicLink(string: url)).kind == kind)
    }

    @Test("Stations are not downloadable")
    func stationNotDownloadable() {
        #expect(!AppleMusicLink.Kind.station.isDownloadable)
        #expect(AppleMusicLink.Kind.playlist.isDownloadable)
    }

    @Test("Rejects anything that is not an Apple Music link", arguments: [
        "", "bonjour", "https://open.spotify.com/track/123", "https://music.apple.com/",
        "https://music.apple.com/fr", "ftp://music.apple.com/fr/album/x/1", "https://music.apple.com/search/album/1",
    ])
    func rejects(_ text: String) {
        #expect(AppleMusicLink(string: text) == nil)
    }

    @Test("Surrounding whitespace is trimmed")
    func trims() {
        #expect(AppleMusicLink(string: "  https://music.apple.com/fr/album/x/1\n") != nil)
    }

    @Test("Extracts multiple links from free text without duplicates")
    func extractAll() {
        let text = """
        Écoute ça : https://music.apple.com/fr/album/a/1.
        Et https://music.apple.com/fr/playlist/b/pl.2, puis encore https://music.apple.com/fr/album/a/1
        Spotify : https://open.spotify.com/track/3
        """
        let links = AppleMusicLink.extractAll(from: text)
        #expect(links.map(\.id) == ["1", "pl.2"])
        #expect(links.map(\.kind) == [.album, .playlist])
    }
}

import Foundation
import Testing
@testable import GamdlStudio

@Suite("Library")
struct LibraryTests {
    @Test("gamdl file names", arguments: [
        ("01 I Love the Nightlife (Disco 'Round)", 1, nil as Int?, "I Love the Nightlife (Disco 'Round)"),
        ("2-05 Titre", 5, 2, "Titre"),
        ("Sans numéro", nil, nil, "Sans numéro"),
    ])
    func fileNames(base: String, track: Int?, disc: Int?, title: String) {
        let p = LibraryScanner.parseFileName(base)
        #expect(p.track == track)
        #expect(p.disc == disc)
        #expect(p.title == title)
    }

    @Test("Folder classification")
    func classify() {
        #expect(LibraryScanner.classify(["Compilations", "Alicia Bridges_ The Collection"]) == (.compilation, nil))
        #expect(LibraryScanner.classify(["Coldplay", "Parachutes"]) == (.album, "Coldplay"))
        #expect(LibraryScanner.classify(["Playlists", "Apple Music", "Disco"]) == (.playlist, "Apple Music"))
    }

    // MARK: - Integration on a real directory tree

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)")
        let fm = FileManager.default
        func touch(_ path: String, bytes: Int = 10, date: Date? = nil) throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: bytes).write(to: url)
            if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try touch("Coldplay/Parachutes/02 Yellow.m4a", bytes: 300, date: old)
        try touch("Coldplay/Parachutes/01 Don't Panic.m4a", bytes: 200, date: old)
        try touch("Coldplay/Parachutes/01 Don't Panic.lrc")
        try touch("Coldplay/Parachutes/Cover.jpg")
        try touch("Compilations/Alicia Bridges_ The Collection/01 I Love the Nightlife (Disco 'Round).m4a", bytes: 400)
        try touch("Compilations/Alicia Bridges_ The Collection/notes.txt")
        try touch(".gamdl-temp/partial.m4a")
        return root
    }

    @Test("Scan groups by album, sorts tracks, finds lyrics and cover")
    func scan() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let albums = try LibraryScanner.scan(root: root)
        #expect(albums.count == 2) // hidden folder is ignored

        let parachutes = try #require(albums.first { $0.title == "Parachutes" })
        #expect(parachutes.artist == "Coldplay")
        #expect(parachutes.category == .album)
        #expect(parachutes.tracks.map(\.title) == ["Don't Panic", "Yellow"])
        #expect(parachutes.tracks[0].lyricsURL != nil)
        #expect(parachutes.tracks[1].lyricsURL == nil)
        #expect(parachutes.coverFile?.lastPathComponent == "Cover.jpg")
        #expect(parachutes.totalSize == 500)

        let comp = try #require(albums.first { $0.category == .compilation })
        #expect(comp.subtitle == "Compilation")
        #expect(comp.tracks.count == 1)
        #expect(comp.artworkSource == comp.tracks[0].url) // no Cover.jpg, so the m4a's embedded artwork
    }

    @Test("Sorting by recently added and diacritic-insensitive search")
    func sortAndSearch() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let albums = try LibraryScanner.scan(root: root)

        #expect(LibrarySort.recent.sort(albums).first?.category == .compilation)
        #expect(LibrarySort.artist.sort(albums).map(\.title) == ["Parachutes", "Alicia Bridges_ The Collection"])
        #expect(LibrarySort.size.sort(albums).first?.title == "Parachutes")

        #expect(albums.filter { $0.matches("nightlife") }.count == 1)
        #expect(albums.filter { $0.matches("PANIC") }.count == 1)
        #expect(albums.filter { $0.matches("") }.count == 2)
        #expect(albums.filter { $0.matches("cöldplay") }.count == 1)
    }

    @Test("Missing folder gives an empty library, not an error")
    func missingRoot() throws {
        #expect(try LibraryScanner.scan(root: URL(filePath: "/nexiste/pas/\(UUID().uuidString)")).isEmpty)
    }

    @MainActor
    @Test("LibraryStore async scan and albums modified since a date")
    func store() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore()
        await store.refresh(root: root).value
        #expect(store.albums.count == 2)
        #expect(store.trackCount == 3)
        #expect(!store.isScanning)
        let recent = store.albums(modifiedSince: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(recent.map(\.category) == [.compilation])
    }
}

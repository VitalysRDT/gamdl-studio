import Foundation
import Testing
@testable import GamdlStudio

@Suite("Personalized playlists")
struct PlaylistResolverTests {
    private let json = """
    {"id":"pl.pm-20e9f373919da080c4b396962bf55294","name":"En boucle","curator":"Apple Music",
     "artworkURL":"https://is1-ssl.mzstatic.com/image/thumb/x/1200x1200bb.jpg","storefront":"fr",
     "tracks":[
       {"id":"1439279592","type":"songs","name":"Don't Leave Me This Way","artist":"Thelma Houston","album":"Any Way You Like It","durationMs":342360},
       {"id":"1443813894","type":"songs","name":"I Need You","artist":"Sylvester","album":"Sell My Soul","durationMs":276373},
       {"id":"1500000001","type":"music-videos","name":"Clip","artist":"X","album":null,"durationMs":null},
       {"id":"i.abcdef","type":"library-songs","name":"Uploaded","artist":"Y","album":null,"durationMs":null}
     ]}
    """

    @Test("Which playlist IDs gamdl rejects", arguments: [
        ("https://music.apple.com/fr/playlist/en-boucle/pl.pm-20e9f373919da080c4b396962bf55294", true),
        ("https://music.apple.com/fr/playlist/top/pl.f4d106fed2bd41149aaacabb233eb5eb", false),
        ("https://music.apple.com/fr/playlist/mine/pl.u-aZb0kLzsoPvXyR", false),
        ("https://music.apple.com/library/playlist/p.XYZ", false),
        ("https://music.apple.com/fr/album/x/1443802477", false),
    ])
    func needsResolution(url: String, expected: Bool) throws {
        #expect(try #require(AppleMusicLink(string: url)).needsResolution == expected)
    }

    @Test("Parsed tracks become URLs gamdl accepts")
    func trackURLs() throws {
        let playlist = try PlaylistResolver.parse(Data(json.utf8))
        #expect(playlist.name == "En boucle")
        #expect(playlist.tracks.count == 4)
        #expect(playlist.trackURLs == [
            "https://music.apple.com/fr/song/1439279592",
            "https://music.apple.com/fr/song/1443813894",
            "https://music.apple.com/fr/music-video/1500000001",
        ])
    }

    @Test("Preview lists the tracks with their artist")
    func preview() throws {
        let preview = try PlaylistResolver.parse(Data(json.utf8)).preview()
        #expect(preview.kind == .playlist)
        #expect(preview.title == "En boucle")
        #expect(preview.trackCount == 4)
        #expect(preview.tracks.first?.title == "Don't Leave Me This Way · Thelma Houston")
        #expect(preview.tracks.map(\.number) == [1, 2, 3, 4])
    }

    @Test("A playlist with no downloadable track is an error")
    func empty() {
        let empty = #"{"id":null,"name":"Vide","curator":null,"artworkURL":null,"storefront":"fr","tracks":[]}"#
        #expect(throws: PlaylistResolverError.self) { try PlaylistResolver.parse(Data(empty.utf8)) }
    }

    @Test("Interpreter read from gamdl's shebang")
    func shebang() throws {
        let python = URL(filePath: "/bin/sh") // any executable stands in for the venv's python
        #expect(PlaylistResolver.interpreter(fromShebang: "#!/bin/sh -E\nimport sys") == python)
        #expect(PlaylistResolver.interpreter(fromShebang: "#!/usr/bin/env python3\n") == nil)
        #expect(PlaylistResolver.interpreter(fromShebang: "print('no shebang')") == nil)
        #expect(PlaylistResolver.interpreter(fromShebang: "#!/nonexistent/python\n") == nil)
    }

    // MARK: - Functional: a fake gamdl whose "python" prints the JSON

    private struct FakeInstall {
        let dir: URL
        let gamdl: URL
        let script: URL

        init(pythonBody: String) throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "fake-python-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let python = dir.appending(path: "python")
            try ("#!/bin/bash\n" + pythonBody).write(to: python, atomically: true, encoding: .utf8)
            gamdl = dir.appending(path: "gamdl")
            try "#!\(python.path) -E\n".write(to: gamdl, atomically: true, encoding: .utf8)
            for file in [python, gamdl] {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            script = dir.appending(path: "resolve_playlist.py")
            try "".write(to: script, atomically: true, encoding: .utf8)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private let link = AppleMusicLink(string: "https://music.apple.com/fr/playlist/en-boucle/pl.pm-20e9f373919da080c4b396962bf55294")!

    @Test("Resolver runs gamdl's Python and reads JSON from stdout only")
    func resolveWithFakePython() async throws {
        let install = try FakeInstall(pythonBody: """
        echo "$@" > "$(dirname "$0")/args.txt"
        echo "2026-10-17 [debug] noisy log line" >&2
        cat "$(dirname "$0")/playlist.json"
        """)
        defer { install.cleanup() }
        try json.write(to: install.dir.appending(path: "playlist.json"), atomically: true, encoding: .utf8)

        let playlist = try await PlaylistResolver.resolve(
            link, gamdl: install.gamdl, cookies: URL(filePath: "/tmp/cookies.txt"), environment: [:], script: install.script
        )
        #expect(playlist.trackURLs.count == 3)

        let args = try String(contentsOf: install.dir.appending(path: "args.txt"), encoding: .utf8)
        #expect(args.trimmed == "-I \(install.script.path) /tmp/cookies.txt fr pl.pm-20e9f373919da080c4b396962bf55294")
    }

    @Test("Resolver failure surfaces the script's last error line")
    func resolveFailure() async throws {
        let install = try FakeInstall(pythonBody: """
        echo "Traceback..." >&2
        echo "GamdlApiResponseError: Error fetching from AMP API" >&2
        exit 1
        """)
        defer { install.cleanup() }

        do {
            _ = try await PlaylistResolver.resolve(link, gamdl: install.gamdl, cookies: URL(filePath: "/tmp/c"), environment: [:], script: install.script)
            Issue.record("expected an error")
        } catch let error as PlaylistResolverError {
            #expect(error.localizedDescription.contains("Error fetching from AMP API"))
        }
    }

    @Test("The bundled resolver script ships with the app")
    func bundledScript() {
        #expect(PlaylistResolver.bundledScript != nil)
    }
}

@MainActor
@Suite("Multi-URL jobs")
struct MultiURLJobTests {
    private func makeJob(_ url: String = "https://music.apple.com/fr/playlist/x/pl.pm-1") -> DownloadJob {
        DownloadJob(link: AppleMusicLink(string: url)!, options: DownloadOptions())
    }

    @Test("Progress is counted in URLs when gamdl gets one URL per song")
    func progressAcrossURLs() {
        let job = makeJob()
        job.state = .running
        job.apply(.processingURL(index: 3, total: 4, url: "https://music.apple.com/fr/song/3"))
        job.apply(.trackStarted(TrackPosition(index: 1, total: 1), title: "C"))
        job.apply(.progress(TransferProgress(fraction: 0.5, size: nil, speed: nil, eta: nil, isComplete: false)))
        #expect(job.trackIndex == 3)
        #expect(job.trackTotal == 4)
        #expect(abs(job.overallFraction - 2.5 / 4) < 0.0001)
        #expect(job.tracks.last?.index == 3)
    }

    @Test("A rejected URL with nothing downloaded is a failure, not a success")
    func rejectedURL() {
        let job = makeJob()
        job.apply(.urlFailed(message: GamdlOutputParser.humanURLError("URL is not valid or supported: https://…")))
        job.apply(.finished(errorCount: 0))
        #expect(job.state == .failed("Lien non pris en charge par gamdl"))
    }

    @Test("Rejected URLs count as errors when other URLs worked")
    func partialFailure() {
        let job = makeJob()
        job.apply(.processingURL(index: 1, total: 2, url: "a"))
        job.apply(.trackStarted(TrackPosition(index: 1, total: 1), title: "A"))
        job.apply(.processingURL(index: 2, total: 2, url: "b"))
        job.apply(.urlFailed(message: "bad"))
        job.apply(.finished(errorCount: 0))
        #expect(job.state == .completed(errors: 1))
    }
}

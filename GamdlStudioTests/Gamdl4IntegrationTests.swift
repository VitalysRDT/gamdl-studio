import Foundation
import Testing
@testable import GamdlStudio

/// A Python 3 to run the app's real scripts against stub `gamdl` packages.
private enum Python {
    static let path: URL? = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        .map { URL(filePath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// A temporary folder holding fake executables and stub Python packages.
private struct Sandbox {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "gamdl4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relativePath: String, _ content: String, executable: Bool = false) throws -> URL {
        let url = dir.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: dir.appending(path: relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: relativePath).path)
    }

    /// Stands in for gamdl's venv Python: records its arguments, drops -I
    /// (which would ignore PYTHONPATH) and runs the real interpreter on the
    /// stub packages under `stub/`.
    func python(real: URL) throws -> URL {
        try write("venv/bin/python", """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(dir.path)/python-args.txt'
        args=()
        for a in "$@"; do [ "$a" = "-I" ] || args+=("$a"); done
        export PYTHONPATH='\(dir.appending(path: "stub").path)'
        export PYTHONDONTWRITEBYTECODE=1
        exec '\(real.path)' "${args[@]}"
        """, executable: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Finding gamdl's Python")
struct GamdlPythonTests {
    @Test("pipx's /bin/sh trampoline names the interpreter on its second line (regression)")
    func pipxTrampoline() throws {
        // pipx now installs under ~/Library/Application Support, a path with a
        // space, so pip writes this launcher instead of a #! line. The app used
        // to take /bin/sh for gamdl's Python.
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let python = try sandbox.write("Application Support/pipx/venvs/gamdl/bin/python", "#!/bin/sh\n", executable: true)
        let launcher = """
        #!/bin/sh
        '''exec' '\(python.path)' "$0" "$@"
        ' '''
        # -*- coding: utf-8 -*-
        import sys
        from gamdl.cli.main import main
        """
        #expect(PlaylistResolver.interpreter(fromShebang: launcher) == python)

        let gamdl = try sandbox.write("bin/gamdl", launcher, executable: true)
        #expect(PlaylistResolver.python(forGamdl: gamdl) == python)
    }

    @Test("A trampoline naming a missing interpreter gives nothing")
    func missingTrampolineTarget() {
        let launcher = "#!/bin/sh\n'''exec' '/nonexistent/python' \"$0\" \"$@\"\n' '''\n"
        #expect(PlaylistResolver.interpreter(fromShebang: launcher) == nil)
    }
}

@MainActor
@Suite("DownloadQueue with gamdl 4 (integration)")
struct Gamdl4QueueTests {
    private struct NoPreview: MediaPreviewProviding {
        func preview(for link: AppleMusicLink) async throws -> MediaPreview? { nil }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func queue(paths: GamdlPaths) -> DownloadQueue {
        let env = DownloadEnvironment(paths: { paths }, processEnvironment: ToolLocator.standard.environment())
        let queue = DownloadQueue(environment: { env }, previews: NoPreview(), historyStore: nil)
        queue.playSound = false
        queue.notifyOnCompletion = false
        return queue
    }

    private func paths(_ sandbox: Sandbox, gamdl: URL, python: URL? = nil) -> GamdlPaths {
        GamdlPaths(
            gamdl: gamdl, ffmpeg: nil, cookies: URL(filePath: "/tmp/c.txt"),
            output: sandbox.dir.appending(path: "out"), temp: sandbox.dir.appending(path: "temp"),
            generation: .v4, python: python
        )
    }

    private let album = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1443802477")!

    @Test("gamdl 4 run directly: rip arguments, wide COLUMNS, job result from its output")
    func direct() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let plain = try Fixture.text("gamdl-4.1.2-synthetic-album.txt")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(Gamdl4OutputParser.marker) }
            .joined(separator: "\n")
        try sandbox.write("output.txt", plain)
        let gamdl = try sandbox.write("gamdl", """
        #!/bin/bash
        printf '%s\\n' "$@" > "$(dirname "$0")/args.txt"
        echo "$COLUMNS" > "$(dirname "$0")/columns.txt"
        cat "$(dirname "$0")/output.txt"
        exit 1
        """, executable: true)

        let queue = queue(paths: paths(sandbox, gamdl: gamdl))
        var finished = false
        queue.onJobFinished = { _ in finished = true }
        let job = queue.enqueue(album, options: DownloadOptions())
        try await waitUntil { finished }

        let args = (sandbox.read("args.txt") ?? "").split(separator: "\n").map(String.init)
        #expect(args.first == "rip")
        #expect(args.contains("--auth-mode") && args.contains("--output-dir"))
        #expect(args.last == album.absoluteString)
        #expect(sandbox.read("columns.txt")?.trimmed == "10000")
        #expect(job.commandLine?.hasPrefix(gamdl.path + " rip ") == true)
        #expect(job.state == .completed(errors: 1))
        #expect(job.downloadedCount == 1 && job.skippedCount == 2 && job.failedCount == 1)
    }

    @Test("Lyrics only with gamdl 4 fails clearly and never launches gamdl")
    func lyricsOnlyRefused() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let gamdl = try sandbox.write("gamdl", "#!/bin/bash\ntouch \"$(dirname \"$0\")/launched\"\n", executable: true)
        let queue = queue(paths: paths(sandbox, gamdl: gamdl))
        var o = DownloadOptions()
        o.lyricsMode = .lyricsOnly
        let job = queue.enqueue(album, options: o)
        try await waitUntil { job.state.isFinished }
        #expect(job.state == .failed(GamdlCommandError.lyricsOnlyUnsupported.localizedDescription))
        #expect(!sandbox.exists("launched"))
    }

    // MARK: - The real bridge script, run by Python against a stub gamdl

    private static let stubMain = """
    import os
    import sys

    from gamdl.cli.progress import RipProgress


    class _Progress:
        def __init__(self, percentage):
            self.percentage = percentage
            self.emitted_bytes = int(percentage * 1000)
            self.total_bytes = 100000
            self.elapsed_seconds = 1.0


    class _Event:
        def __init__(self, percentage):
            self.progress = _Progress(percentage)


    def main():
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "..", "..", "gamdl-args.txt"), "w") as f:
            f.write("\\n".join(sys.argv))
        print("Gamdl 4.1.2", file=sys.stderr)
        print(file=sys.stderr)
        print("✓ Authenticated")
        p = RipProgress()
        p.add(1, "Un")
        p.event(1, "Un", _Event(50.0))
        p.event(1, "Un", _Event(100.0))
        p.finish(1, "Un", "downloaded", path="/M/01 Un.m4a")
        p.add(2, "Deux")
        p.event(2, "Deux", _Event(30.0))
        p.finish(2, "Deux", "failed", "Unable to fetch stream")
        print("Finished: 1 downloaded, 0 overwritten, 0 skipped, 1 failed, 0 finalization failures (2 discovered)")
        print("Errors (1):")
        print("  ✗ Deux: Unable to fetch stream")
        return 1
    """

    private static let stubProgress = """
    class RipProgress:
        def add(self, occurrence, title, *, tracks=("audio",)):
            pass

        def event(self, occurrence, title, event):
            pass

        def finish(self, occurrence, title, status, message=None, *, path=None):
            if status == "failed":
                return
            line = "✓ " + title + ": " + status
            if path:
                line += " → " + path
            print(line)
    """

    private func stubGamdl(_ sandbox: Sandbox, progress: String, main: String) throws {
        try sandbox.write("stub/gamdl/__init__.py", "")
        try sandbox.write("stub/gamdl/cli/__init__.py", "")
        try sandbox.write("stub/gamdl/cli/progress.py", progress)
        try sandbox.write("stub/gamdl/cli/main.py", main)
    }

    @Test("Through the bridge: live track positions and progress reach the job", .enabled(if: Python.path != nil))
    func bridged() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        try stubGamdl(sandbox, progress: Self.stubProgress, main: Self.stubMain)
        let python = try sandbox.python(real: try #require(Python.path))
        let bridge = try #require(GamdlCommand.bridgeScript)

        let queue = queue(paths: paths(sandbox, gamdl: URL(filePath: "/never/run/gamdl"), python: python))
        var finished = false
        queue.onJobFinished = { _ in finished = true }
        let job = queue.enqueue(album, options: DownloadOptions())
        try await waitUntil { finished }

        let pythonArgs = (sandbox.read("python-args.txt") ?? "").split(separator: "\n").map(String.init)
        #expect(Array(pythonArgs.prefix(4)) == ["-I", "-u", bridge.path, "rip"])
        // gamdl's own entry point got the arguments, under its own name.
        let gamdlArgs = (sandbox.read("gamdl-args.txt") ?? "").split(separator: "\n").map(String.init)
        #expect(gamdlArgs.first == "gamdl")
        #expect(Array(gamdlArgs.dropFirst()) == Array(pythonArgs.dropFirst(3)))

        #expect(job.gamdlVersion == "4.1.2")
        #expect(job.state == .completed(errors: 1))
        #expect(job.tracks.map(\.index) == [1, 2])
        #expect(job.tracks.map(\.status) == [.done, .failed])
        #expect(job.size == Formatters.bytes(100_000))
        #expect(job.log.filter { $0.text == "Échec du téléchargement de « Deux »" }.count == 1)
        #expect(job.log.contains { $0.text == "Deux : Unable to fetch stream" })
        #expect(!job.log.contains { $0.text.contains(Gamdl4OutputParser.marker) })
    }

    @Test("If gamdl's display changed, the bridge runs gamdl untouched", .enabled(if: Python.path != nil))
    func bridgeFallback() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        // A later gamdl without RipProgress: the hooks can't be installed.
        let renamed = Self.stubProgress.replacingOccurrences(of: "class RipProgress", with: "class TrackDisplay")
        let main = Self.stubMain.replacingOccurrences(of: "RipProgress", with: "TrackDisplay")
        try stubGamdl(sandbox, progress: renamed, main: main)
        let python = try sandbox.python(real: try #require(Python.path))

        let queue = queue(paths: paths(sandbox, gamdl: URL(filePath: "/never/run/gamdl"), python: python))
        var finished = false
        queue.onJobFinished = { _ in finished = true }
        let job = queue.enqueue(album, options: DownloadOptions())
        try await waitUntil { finished }

        #expect(sandbox.exists("gamdl-args.txt"))
        #expect(job.state == .completed(errors: 1))
        #expect(job.tracks.map(\.title) == ["Un", "Deux"])
        #expect(job.tracks.allSatisfy { $0.index == nil })
        #expect(job.size == nil)
    }
}

@Suite("resolve_playlist.py with gamdl 3 and 4 (integration)")
struct ResolvePlaylistScriptTests {
    private let link = AppleMusicLink(string: "https://music.apple.com/fr/playlist/replay/pl.pm-20e9f373919da080c4b396962bf55294")!

    private static func api(_ methods: String) -> String {
        """
        import os

        HERE = os.path.dirname(os.path.abspath(__file__))
        ROOT = os.path.join(HERE, "..", "..", "..", "..")


        def _note(name, value=""):
            with open(os.path.join(ROOT, name), "w") as f:
                f.write(value)


        PLAYLIST = {"data": [{
            "id": "pl.pm-1",
            "attributes": {"name": "Replay 2026", "curatorName": "Apple Music", "artwork": {"url": "https://a/{w}x{h}.jpg"}},
            "relationships": {"tracks": {
                "data": [{"id": "1", "type": "songs", "attributes": {"name": "A", "artistName": "X", "albumName": "Al", "durationInMillis": 1000}}],
                "next": "/v1/me/next?offset=1",
            }},
        }]}
        PAGE = {"data": [{"id": "2", "type": "songs", "attributes": {"name": "B", "artistName": "Y"}}]}


        class AppleMusicApi:
            def __init__(self):
                self.storefront = "us"

            async def get_playlist(self, playlist_id):
                _note("playlist-id.txt", playlist_id)
                return PLAYLIST

        \(methods)
        """
    }

    private static let gamdl4 = api("""
        AppleMusicApi.from_cookies = classmethod(lambda cls, path, **kw: _create(cls, path))


        async def _create(cls, path):
            _note("cookies.txt", path)
            return cls()


        async def _enter(self):
            return self


        async def _exit(self, *exc):
            _note("closed.txt")


        async def _page(self, url):
            _note("page-url.txt", url)
            return PAGE


        AppleMusicApi.__aenter__ = _enter
        AppleMusicApi.__aexit__ = _exit
        AppleMusicApi.get_extended_api_data = _page
        """)

    private static let gamdl3 = api("""
        async def _create(cookies_path):
            _note("cookies.txt", cookies_path)
            return AppleMusicApi()


        async def _amp(self, url):
            _note("page-url.txt", url)
            return PAGE


        AppleMusicApi.create_from_netscape_cookies = staticmethod(_create)
        AppleMusicApi._amp_request = _amp
        """)

    private func resolve(with api: String) async throws -> (ResolvedPlaylist, Sandbox) {
        let sandbox = try Sandbox()
        try sandbox.write("stub/gamdl/__init__.py", "")
        try sandbox.write("stub/gamdl/api/__init__.py", "")
        try sandbox.write("stub/gamdl/api/apple_music/__init__.py", api)
        let python = try sandbox.python(real: try #require(Python.path))
        let gamdl = try sandbox.write("bin/gamdl", "#!\(python.path)\n", executable: true)
        let playlist = try await PlaylistResolver.resolve(
            link, gamdl: gamdl, cookies: URL(filePath: "/tmp/cookies.txt"),
            environment: ToolLocator.standard.environment(), script: try #require(PlaylistResolver.bundledScript)
        )
        return (playlist, sandbox)
    }

    @Test("gamdl 4 API: from_cookies, closed connection, get_extended_api_data pages", .enabled(if: Python.path != nil))
    func gamdl4API() async throws {
        let (playlist, sandbox) = try await resolve(with: Self.gamdl4)
        defer { sandbox.cleanup() }
        #expect(playlist.name == "Replay 2026")
        #expect(playlist.storefront == "fr")
        #expect(playlist.tracks.map(\.id) == ["1", "2"])
        #expect(playlist.trackURLs == ["https://music.apple.com/fr/song/1", "https://music.apple.com/fr/song/2"])
        #expect(playlist.artworkURL == URL(string: "https://a/1200x1200.jpg"))
        #expect(sandbox.read("cookies.txt") == "/tmp/cookies.txt")
        #expect(sandbox.read("playlist-id.txt") == link.id)
        #expect(sandbox.read("page-url.txt") == "/v1/me/next?offset=1")
        #expect(sandbox.exists("closed.txt"))
    }

    @Test("gamdl 3 API still works: create_from_netscape_cookies and _amp_request", .enabled(if: Python.path != nil))
    func gamdl3API() async throws {
        let (playlist, sandbox) = try await resolve(with: Self.gamdl3)
        defer { sandbox.cleanup() }
        #expect(playlist.tracks.map(\.id) == ["1", "2"])
        #expect(sandbox.read("cookies.txt") == "/tmp/cookies.txt")
        #expect(sandbox.read("page-url.txt") == "/v1/me/next?offset=1")
    }
}

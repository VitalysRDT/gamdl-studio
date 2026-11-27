import Foundation
import Testing
@testable import GamdlStudio

private func bridge(_ json: String) -> String { Gamdl4OutputParser.marker + json + "\n" }

@Suite("Bridge outcomes (gamdl 4)")
struct BridgeOutcomeTests {
    @Test("Every outcome arrives with its track number and file")
    func outcomes() {
        var parser = Gamdl4OutputParser()
        let events = parser.feed(
            bridge(#"{"e": "done", "i": 2, "title": "B", "status": "downloaded", "message": null, "path": "/M/02 B.m4a"}"#)
            + bridge(#"{"e": "done", "i": 3, "title": "C", "status": "skipped", "message": null, "path": "/M/03 C.m4a"}"#)
            + bridge(#"{"e": "done", "i": 4, "title": "D", "status": "skipped", "message": "Media is not streamable", "path": null}"#)
            + bridge(#"{"e": "done", "i": 5, "title": "E", "status": "failed", "message": "boom", "path": null}"#)
            + bridge(#"{"e": "done", "i": 6, "title": "F", "status": "partial", "message": "tags", "path": "/M/06 F.m4a"}"#)
        )
        #expect(events == [
            .trackCompleted(TrackPosition(index: 2, total: nil), title: "B", file: URL(filePath: "/M/02 B.m4a")),
            .trackSkipped(TrackPosition(index: 3, total: nil), title: "C", reason: "Déjà dans la bibliothèque", existingFile: URL(filePath: "/M/03 C.m4a")),
            .trackSkipped(TrackPosition(index: 4, total: nil), title: "D", reason: "Indisponible en streaming", existingFile: nil),
            .trackFailed(TrackPosition(index: 5, total: nil), title: "E"),
            .trackCompleted(TrackPosition(index: 6, total: nil), title: "F", file: URL(filePath: "/M/06 F.m4a")),
        ])
    }

    @Test("gamdl's own line for an outcome the bridge reported is not counted twice")
    func noEcho() {
        var parser = Gamdl4OutputParser()
        let events = parser.feed(
            bridge(#"{"e": "done", "i": 1, "title": "A", "status": "downloaded", "message": null, "path": "/M/01 A.m4a"}"#)
            + "✓ A: downloaded → /M/01 A.m4a\n"
            + bridge(#"{"e": "done", "i": 2, "title": "B", "status": "skipped", "message": null, "path": "/M/02 B.m4a"}"#)
            + "↷ B: skipped → /M/02 B.m4a\n"
        )
        #expect(events.count == 2)
        // Without a bridge report, gamdl's line still counts.
        #expect(parser.feed("✓ C: downloaded\n") == [.trackCompleted(nil, title: "C", file: nil)])
    }

    @Test("Progress carries its track number")
    func progressIndex() throws {
        var parser = Gamdl4OutputParser()
        let events = parser.feed(bridge(#"{"e": "progress", "i": 7, "pct": 40.0, "bytes": 4, "total": 10, "elapsed": 1}"#))
        guard case .progress(let p) = try #require(events.first) else { Issue.record("\(events)"); return }
        #expect(p.trackIndex == 7)
        #expect(p.fraction == 0.4)
    }
}

@MainActor
@Suite("Parallel downloads in a job (functional)")
struct ParallelJobTests {
    private func job(total: Int? = nil) -> DownloadJob {
        let job = DownloadJob(link: AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!, options: DownloadOptions())
        job.reportsEachTrack = true
        job.markStarted(commandLine: "gamdl rip …")
        job.trackTotal = total
        return job
    }

    private func feed(_ job: DownloadJob, _ text: String) {
        var parser = Gamdl4OutputParser()
        (parser.feed(text) + parser.flush()).forEach(job.apply)
    }

    @Test("Two tracks at once: each keeps its progress and ends on its own row")
    func interleaved() {
        let job = job(total: 4)
        feed(job, bridge(#"{"e": "track", "i": 1, "title": "A"}"#)
            + bridge(#"{"e": "track", "i": 2, "title": "B"}"#)
            + bridge(#"{"e": "progress", "i": 2, "pct": 50.0, "bytes": 5, "total": 10, "elapsed": 1}"#)
            + bridge(#"{"e": "progress", "i": 1, "pct": 30.0, "bytes": 3, "total": 10, "elapsed": 1}"#))
        #expect(job.tracks.map(\.status) == [.downloading, .downloading])
        #expect(job.tracks.map(\.fraction) == [0.3, 0.5])
        #expect(abs(job.overallFraction - 0.8 / 4) < 0.0001)

        feed(job, bridge(#"{"e": "done", "i": 2, "title": "B", "status": "downloaded", "message": null, "path": "/M/02 B.m4a"}"#))
        #expect(job.tracks.map(\.status) == [.downloading, .done])
        #expect(abs(job.overallFraction - 1.3 / 4) < 0.0001)
    }

    @Test("Two tracks with the same title end on the right rows")
    func sameTitle() {
        let job = job()
        feed(job, bridge(#"{"e": "track", "i": 1, "title": "Intro"}"#)
            + bridge(#"{"e": "track", "i": 5, "title": "Intro"}"#)
            + bridge(#"{"e": "done", "i": 1, "title": "Intro", "status": "failed", "message": "x", "path": null}"#)
            + bridge(#"{"e": "done", "i": 5, "title": "Intro", "status": "downloaded", "message": null, "path": "/M/05 Intro.m4a"}"#))
        #expect(job.tracks.map(\.index) == [1, 5])
        #expect(job.tracks.map(\.status) == [.failed, .done])
    }

    @Test("A track starting doesn't end the one before; the summary closes what's left")
    func noImplicitClose() {
        let job = job()
        feed(job, bridge(#"{"e": "track", "i": 1, "title": "A"}"#) + bridge(#"{"e": "track", "i": 2, "title": "B"}"#))
        #expect(job.downloadedCount == 0)
        feed(job, "Finished: 2 downloaded, 0 overwritten, 0 skipped, 0 failed, 0 finalization failures (2 discovered)\n")
        #expect(job.state == .completed(errors: 0))
        #expect(job.tracks.allSatisfy { $0.status == .done })
    }

    @Test("gamdl 3 jobs keep closing the previous track when the next starts")
    func gamdl3Unchanged() {
        let job = DownloadJob(link: AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!, options: DownloadOptions())
        job.apply(.trackStarted(TrackPosition(index: 1, total: 2), title: "A"))
        job.apply(.trackStarted(TrackPosition(index: 2, total: 2), title: "B"))
        #expect(job.tracks.map(\.status) == [.done, .downloading])
    }
}

@Suite("Parallel downloads setting")
struct ParallelSettingTests {
    private let paths = GamdlPaths(
        gamdl: URL(filePath: "/u/gamdl"), ffmpeg: nil, cookies: URL(filePath: "/u/c.txt"),
        output: URL(filePath: "/u/M"), temp: URL(filePath: "/tmp/g"), generation: .v4
    )

    @Test("Passed to gamdl 4; one by default")
    func argument() {
        let album = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!
        var o = DownloadOptions()
        let args = GamdlCommand.arguments(for: album, options: o, paths: paths)
        #expect(args[args.firstIndex(of: "--concurrent-downloads")! + 1] == "1")
        o.concurrentDownloads = 3
        let more = GamdlCommand.arguments(for: album, options: o, paths: paths)
        #expect(more[more.firstIndex(of: "--concurrent-downloads")! + 1] == "3")
    }

    @Test("Saved value is kept within 1…4")
    func clamp() throws {
        for (saved, expected) in [(0, 1), (2, 2), (9, 4)] {
            let o = try JSONDecoder().decode(DownloadOptions.self, from: Data(#"{"concurrentDownloads":\#(saved)}"#.utf8))
            #expect(o.concurrentDownloads == expected)
        }
    }
}

/// The real bridge, run by Python against a stub gamdl that ends two
/// parallel tracks out of order, the way gamdl 4's runner calls RipProgress.
@MainActor
@Suite("Parallel tracks through the real bridge (integration)")
struct ParallelBridgeIntegrationTests {
    private static let python: URL? = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        .map { URL(filePath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    private struct NoPreview: MediaPreviewProviding {
        func preview(for link: AppleMusicLink) async throws -> MediaPreview? { nil }
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    @Test("Outcomes land on their own rows, once each", .enabled(if: python != nil))
    func outOfOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "parallel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("", to: dir.appending(path: "stub/gamdl/__init__.py"))
        try write("", to: dir.appending(path: "stub/gamdl/cli/__init__.py"))
        try write("""
        class RipProgress:
            def add(self, occurrence, title, *, tracks=("audio",)):
                pass

            def event(self, occurrence, title, event):
                pass

            def finish(self, occurrence, title, status, message=None, *, path=None):
                if status == "failed":
                    return
                line = ("↷ " if status == "skipped" else "✓ ") + title + ": " + status
                if path:
                    line += " → " + str(path)
                print(line)
        """, to: dir.appending(path: "stub/gamdl/cli/progress.py"))
        try write("""
        import sys
        from pathlib import Path
        from gamdl.cli.progress import RipProgress


        class _P:
            def __init__(self, pct):
                self.percentage = pct
                self.emitted_bytes = int(pct)
                self.total_bytes = 100
                self.elapsed_seconds = 1.0


        class _E:
            def __init__(self, pct):
                self.progress = _P(pct)


        def main():
            print("Gamdl 4.1.2", file=sys.stderr)
            p = RipProgress()
            p.add(1, "Intro")
            p.add(2, "Intro")
            p.event(2, "Intro", _E(60.0))
            p.event(1, "Intro", _E(20.0))
            p.finish(2, "Intro", "downloaded", path=Path("/M/02 Intro.m4a"))
            p.finish(1, "Intro", "skipped", path=Path("/M/01 Intro.m4a"))
            print("Finished: 1 downloaded, 0 overwritten, 1 skipped, 0 failed, 0 finalization failures (2 discovered)")
            return 0
        """, to: dir.appending(path: "stub/gamdl/cli/main.py"))
        let real = try #require(Self.python)
        let python = dir.appending(path: "venv/bin/python")
        try write("""
        #!/bin/bash
        args=(); for a in "$@"; do [ "$a" = "-I" ] || args+=("$a"); done
        export PYTHONPATH='\(dir.appending(path: "stub").path)' PYTHONDONTWRITEBYTECODE=1
        exec '\(real.path)' "${args[@]}"
        """, to: python, executable: true)

        var options = DownloadOptions()
        options.concurrentDownloads = 2
        let paths = GamdlPaths(
            gamdl: URL(filePath: "/never/run/gamdl"), ffmpeg: nil, cookies: URL(filePath: "/tmp/c.txt"),
            output: dir.appending(path: "out"), temp: dir.appending(path: "temp"), generation: .v4, python: python
        )
        let env = DownloadEnvironment(paths: { paths }, processEnvironment: ToolLocator.standard.environment())
        let queue = DownloadQueue(environment: { env }, previews: NoPreview(), historyStore: nil)
        queue.playSound = false
        queue.notifyOnCompletion = false
        var finished = false
        queue.onJobFinished = { _ in finished = true }
        let job = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!, options: options)
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(20)) }

        #expect(job.state == .completed(errors: 0))
        #expect(job.tracks.map(\.index) == [1, 2])
        #expect(job.tracks.map(\.status) == [.skipped("Déjà dans la bibliothèque"), .done])
        #expect(job.tracks[0].existingFile == URL(filePath: "/M/01 Intro.m4a"))
        #expect(job.downloadedCount == 1 && job.skippedCount == 1)
        #expect(job.commandLine?.contains("--concurrent-downloads 2") == true)
    }
}

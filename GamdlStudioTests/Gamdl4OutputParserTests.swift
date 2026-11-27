import Foundation
import Testing
@testable import GamdlStudio

/// Fixtures:
/// - `gamdl-4.1.2-single-track.txt` and `gamdl-4.1.2-already-downloaded.txt`
///   are real runs of gamdl 4.1.2 through `gamdl_bridge.py`, with the app's
///   exact arguments and a signed-in session: one song downloaded, then the
///   same song again into the same folder. Paths anonymized.
/// - `gamdl-4.1.2-session-error.txt` is real gamdl 4.1.2 output (`gamdl rip`
///   with the app's arguments and a cookies file without a media-user-token),
///   with the home folder anonymized.
/// - `gamdl-4.1.2-synthetic-album.txt` was printed by gamdl 4.1.2's own output
///   code (banner, RipProgress, the runner's summary and failure report)
///   through `gamdl_bridge.py`, fed with made-up download events. No real
///   download produced it.
@Suite("Gamdl4OutputParser")
struct Gamdl4OutputParserTests {
    private func parse(_ lines: String...) -> [GamdlEvent] {
        var parser = Gamdl4OutputParser()
        return parser.feed(lines.joined(separator: "\n") + "\n") + parser.flush()
    }

    @Test("Banner gives the gamdl version")
    func banner() {
        #expect(parse("Gamdl 4.1.2") == [.started(version: "4.1.2")])
    }

    @Test("Downloaded track with its file")
    func downloaded() {
        let events = parse("✓ I Love the Nightlife (Disco 'Round): downloaded → /M/A/01 I Love the Nightlife (Disco 'Round).m4a")
        #expect(events == [.trackCompleted(nil, title: "I Love the Nightlife (Disco 'Round)", file: URL(filePath: "/M/A/01 I Love the Nightlife (Disco 'Round).m4a"))])
    }

    @Test("Overwritten and partially finalized tracks count as completed")
    func otherCompletions() {
        #expect(parse("✓ A: overwritten → /M/a.m4a") == [.trackCompleted(nil, title: "A", file: URL(filePath: "/M/a.m4a"))])
        #expect(parse("✓ B: media saved (finalization incomplete) → /M/b.m4a") == [.trackCompleted(nil, title: "B", file: URL(filePath: "/M/b.m4a"))])
        #expect(parse("✓ C: downloaded") == [.trackCompleted(nil, title: "C", file: nil)])
    }

    @Test("Skipped without a reason: the file is already there")
    func skippedExisting() {
        let events = parse("↷ Déjà là: skipped → /M/03 Déjà là.m4a")
        #expect(events == [.trackSkipped(nil, title: "Déjà là", reason: "Déjà dans la bibliothèque", existingFile: URL(filePath: "/M/03 Déjà là.m4a"))])
    }

    @Test("Skipped with a reason gets it translated, and has no file")
    func skippedReason() {
        let events = parse("↷ Pas en streaming: skipped (Media is not streamable)")
        #expect(events == [.trackSkipped(nil, title: "Pas en streaming", reason: "Indisponible en streaming", existingFile: nil)])
    }

    @Test("A path with parentheses after a reason stays whole")
    func pathWithParentheses() {
        let events = parse("↷ T: skipped (Some reason) → /M/Album (Deluxe)/01 T.m4a")
        #expect(events == [.trackSkipped(nil, title: "T", reason: "Some reason", existingFile: URL(filePath: "/M/Album (Deluxe)/01 T.m4a"))])
    }

    @Test("The summary is held back until the process ends, after the failures")
    func summaryAfterFailures() {
        var parser = Gamdl4OutputParser()
        let early = parser.feed("""
        Finished: 1 downloaded, 0 overwritten, 0 skipped, 2 failed, 1 finalization failures (3 discovered)
        Errors (2):
          ✗ A: Unable to fetch stream
          ✗ B: Boom (KeyError)

        """)
        #expect(!early.contains { if case .finished = $0 { true } else { false } })
        #expect(early.contains(.trackFailed(nil, title: "A")))
        #expect(early.contains(.log(LogLine(level: .error, text: "A : Unable to fetch stream"))))
        // The exception type gamdl appends to unexpected errors is dropped.
        #expect(early.contains(.log(LogLine(level: .error, text: "B : Boom"))))
        #expect(parser.flush() == [.finished(errorCount: 3)])
    }

    @Test("A colon inside a known title isn't taken as the separator")
    func colonInTitle() {
        var parser = Gamdl4OutputParser()
        _ = parser.feed(#"@gamdl-studio {"e": "track", "i": 2, "title": "Interlude: Le Retour"}"# + "\n")
        let events = parser.feed("Errors (1):\n  ✗ Interlude: Le Retour: Unable to fetch stream\n")
        #expect(events.contains(.trackFailed(nil, title: "Interlude: Le Retour")))
        #expect(events.contains(.log(LogLine(level: .error, text: "Interlude: Le Retour : Unable to fetch stream"))))
    }

    @Test("A failure the bridge already reported is only logged")
    func noDuplicateFailure() {
        var parser = Gamdl4OutputParser()
        let live = parser.feed(#"@gamdl-studio {"e": "failed", "i": 2, "title": "A", "message": "x"}"# + "\n")
        #expect(live == [.trackFailed(TrackPosition(index: 2, total: nil), title: "A")])
        let report = parser.feed("Errors (1):\n  ✗ A: x\n")
        #expect(report == [.log(LogLine(level: .error, text: "A : x"))])
    }

    @Test("Session failure: the whole run failed, the message is kept")
    func session() {
        let events = parse("Errors (1):", "  ✗ Session: Authentication failed (check cookies or wrapper login)")
        #expect(events == [.log(LogLine(level: .error, text: "Session Apple Music : Authentication failed (check cookies or wrapper login)"))])
    }

    @Test("Source failure is a rejected link, not a track error")
    func source() {
        let events = parse(
            "Finished: 0 downloaded, 0 overwritten, 0 skipped, 1 failed, 0 finalization failures (0 discovered)",
            "Errors (1):",
            "  ✗ Source: URL is not valid or supported"
        )
        #expect(events.contains(.urlFailed(message: "Lien non pris en charge par gamdl")))
        #expect(events.last == .finished(errorCount: 0))
    }

    @Test("Nothing found at the link")
    func nothingFound() {
        #expect(parse("No supported media found at this URL.") == [.urlFailed(message: "Aucun média téléchargeable à ce lien")])
    }

    @Test("Symbols map to log levels")
    func levels() {
        #expect(parse("✓ Authenticated") == [.log(LogLine(level: .info, text: "Authenticated"))])
        #expect(parse("! An active Apple Music subscription was not confirmed") == [.log(LogLine(level: .warning, text: "An active Apple Music subscription was not confirmed"))])
        #expect(parse("✗ No such option '--bogus'.") == [.log(LogLine(level: .error, text: "No such option '--bogus'."))])
        #expect(parse("• Something") == [.log(LogLine(level: .info, text: "Something"))])
        #expect(parse("Created config at /u/.gamdl/config.yml") == [.log(LogLine(level: .plain, text: "Created config at /u/.gamdl/config.yml"))])
    }

    @Test("Traceback lines are plain log, never failures")
    func tracebacks() {
        let events = parse("Exception tracebacks (1):", "  ✗ A", "Traceback (most recent call last):")
        #expect(events == [
            .log(LogLine(level: .error, text: "Exception tracebacks (1):")),
            .log(LogLine(level: .plain, text: "✗ A")),
            .log(LogLine(level: .plain, text: "Traceback (most recent call last):")),
        ])
    }

    @Test("Bridge: track start carries its position")
    func bridgeTrack() {
        #expect(parse(#"@gamdl-studio {"e": "track", "i": 3, "title": "Titre"}"#) == [.trackStarted(TrackPosition(index: 3, total: nil), title: "Titre")])
    }

    @Test("Bridge: progress with size, speed and time left")
    func bridgeProgress() throws {
        let events = parse(#"@gamdl-studio {"e": "progress", "i": 1, "pct": 25.0, "bytes": 3000000, "total": 12000000, "elapsed": 1.5}"#)
        guard case .progress(let p) = try #require(events.first) else { Issue.record("\(events)"); return }
        #expect(p.fraction == 0.25)
        #expect(!p.isComplete)
        #expect(p.size == Formatters.bytes(12_000_000))
        #expect(p.speed == Formatters.bytes(2_000_000) + "/s")
        #expect(p.eta == "0:05")
    }

    @Test("Bridge: complete progress without byte counts")
    func bridgeProgressComplete() throws {
        let events = parse(#"@gamdl-studio {"e": "progress", "i": 1, "pct": 100.0, "bytes": null, "total": null, "elapsed": 0}"#)
        guard case .progress(let p) = try #require(events.first) else { Issue.record("\(events)"); return }
        #expect(p == TransferProgress(fraction: 1, size: nil, speed: nil, eta: nil, isComplete: true, trackIndex: 1))
    }

    @Test("Bridge: a malformed line goes to the raw log")
    func bridgeMalformed() {
        #expect(parse("@gamdl-studio {oops") == [.log(LogLine(level: .plain, text: "@gamdl-studio {oops"))])
        #expect(parse(#"@gamdl-studio {"e": "later"}"#) == [])
    }

    @Test("Splits on \\r and \\n and buffers incomplete lines")
    func buffering() {
        var parser = Gamdl4OutputParser()
        #expect(parser.feed("✓ A: downl") == [])
        #expect(parser.feed("oaded\r✓ B: downloaded") == [.trackCompleted(nil, title: "A", file: nil)])
        #expect(parser.flush() == [.trackCompleted(nil, title: "B", file: nil)])
    }

    @Test("ANSI codes are ignored")
    func ansi() {
        #expect(parse("\u{1B}[32m✓\u{1B}[0m A: downloaded") == [.trackCompleted(nil, title: "A", file: nil)])
    }
}

@MainActor
@Suite("Replaying gamdl 4 output (functional)")
struct Gamdl4ReplayTests {
    private func replay(_ text: String, exitCode: Int32) -> DownloadJob {
        let job = DownloadJob(link: AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!, options: DownloadOptions())
        job.markStarted(commandLine: "gamdl rip …")
        var parser = Gamdl4OutputParser()
        // Fed in uneven chunks, as a pipe delivers it.
        var rest = Substring(text)
        while !rest.isEmpty {
            let chunk = rest.prefix(37)
            rest = rest.dropFirst(37)
            parser.feed(String(chunk)).forEach(job.apply)
        }
        parser.flush().forEach(job.apply)
        job.markProcessEnded(ProcessResult(exitCode: exitCode, wasCancelled: false))
        return job
    }

    @Test("Album through the bridge: live tracks, then the failure report")
    func albumWithBridge() throws {
        // gamdl 4 exits with 1 when a track failed; the summary decides.
        let job = replay(try Fixture.text("gamdl-4.1.2-synthetic-album.txt"), exitCode: 1)
        #expect(job.state == .completed(errors: 1))
        #expect(job.gamdlVersion == "4.1.2")
        #expect(job.tracks.map(\.index) == [1, 2, 3, 4])
        #expect(job.tracks.map(\.title) == ["I Love the Nightlife (Disco 'Round)", "Interlude: Le Retour", "Déjà là", "Pas en streaming"])
        #expect(job.downloadedCount == 1)
        #expect(job.skippedCount == 2)
        #expect(job.failedCount == 1)
        #expect(job.tracks[1].status == .failed)
        #expect(job.tracks[2].existingFile?.lastPathComponent == "03 Déjà là.m4a")
        #expect(job.tracks[3].status == .skipped("Indisponible en streaming"))
        // One failure line, plus gamdl's message.
        #expect(job.log.filter { $0.text == "Échec du téléchargement de « Interlude: Le Retour »" }.count == 1)
        #expect(job.log.contains { $0.text == "Interlude: Le Retour : Unable to fetch stream" })
    }

    @Test("Album without the bridge: only finished tracks, same result")
    func albumWithoutBridge() throws {
        let plain = try Fixture.text("gamdl-4.1.2-synthetic-album.txt")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(Gamdl4OutputParser.marker) }
            .joined(separator: "\n")
        let job = replay(plain, exitCode: 1)
        #expect(job.state == .completed(errors: 1))
        #expect(job.downloadedCount == 1)
        #expect(job.skippedCount == 2)
        #expect(job.failedCount == 1)
        #expect(job.tracks.allSatisfy { $0.index == nil })
        #expect(job.tracks.first?.title == "I Love the Nightlife (Disco 'Round)")
    }

    @Test("Real gamdl 4.1.2 download through the bridge (regression)")
    func realDownload() throws {
        let job = replay(try Fixture.text("gamdl-4.1.2-single-track.txt"), exitCode: 0)
        #expect(job.state == .completed(errors: 0))
        #expect(job.gamdlVersion == "4.1.2")
        #expect(job.tracks.map(\.index) == [1])
        #expect(job.tracks.map(\.status) == [.done])
        #expect(job.tracks.first?.title == "I Love the Nightlife (Disco 'Round)")
        // Size and speed come from the bridge's progress lines.
        #expect(job.size == Formatters.bytes(13_207_478))
        #expect(job.speed != nil)
        #expect(job.trackFraction == 1)
        #expect(job.log.contains { $0.level == .plain && $0.text == "Created database at /Users/me/.gamdl/media.sqlite3" })
        #expect(!job.log.contains { $0.text.contains(Gamdl4OutputParser.marker) })
    }

    @Test("Real gamdl 4.1.2 run on a song already in the folder (regression)")
    func realAlreadyDownloaded() throws {
        let job = replay(try Fixture.text("gamdl-4.1.2-already-downloaded.txt"), exitCode: 0)
        #expect(job.state == .completed(errors: 0))
        #expect(job.downloadedCount == 0)
        #expect(job.skippedCount == 1)
        #expect(job.tracks.first?.status == .skipped("Déjà dans la bibliothèque"))
        #expect(job.tracks.first?.existingFile == URL(filePath: "/Users/me/Music/Gamdl Studio/Compilations/Alicia Bridges_ The Collection/01 I Love the Nightlife (Disco 'Round).m4a"))
        #expect(job.existingFolders.map(\.lastPathComponent) == ["Alicia Bridges_ The Collection"])
    }

    @Test("Real gamdl 4.1.2 output: rejected cookies fail the job with gamdl's reason")
    func sessionError() throws {
        let job = replay(try Fixture.text("gamdl-4.1.2-session-error.txt"), exitCode: 1)
        guard case .failed(let message) = job.state else { Issue.record("state \(job.state)"); return }
        #expect(message == "Session Apple Music : Authentication failed (check cookies or wrapper login)")
        #expect(job.gamdlVersion == "4.1.2")
        #expect(job.tracks.isEmpty)
    }

    @Test("Nothing found at the link fails the job")
    func nothingFound() {
        let job = replay("Gamdl 4.1.2\n\n✓ Authenticated\nNo supported media found at this URL.\n", exitCode: 1)
        #expect(job.state == .failed("Aucun média téléchargeable à ce lien"))
    }

    @Test("Expanded playlist: the known total drives overall progress")
    func knownTotal() {
        let job = DownloadJob(link: AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!, options: DownloadOptions())
        job.markStarted(commandLine: "gamdl rip …")
        job.trackTotal = 4
        var parser = Gamdl4OutputParser()
        parser.feed("""
        @gamdl-studio {"e": "track", "i": 1, "title": "A"}
        ✓ A: downloaded
        @gamdl-studio {"e": "track", "i": 2, "title": "B"}
        @gamdl-studio {"e": "progress", "i": 2, "pct": 50.0, "bytes": 1, "total": 2, "elapsed": 1}

        """).forEach(job.apply)
        #expect(job.trackIndex == 2)
        #expect(job.trackTotal == 4)
        #expect(abs(job.overallFraction - 1.5 / 4) < 0.0001)
    }
}

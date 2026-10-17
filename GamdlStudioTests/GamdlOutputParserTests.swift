import Foundation
import Testing
@testable import GamdlStudio

@Suite("GamdlOutputParser")
struct GamdlOutputParserTests {
    @Test("Startup line gives the gamdl version")
    func started() {
        #expect(GamdlOutputParser.parseLine("[INFO     19:09:35] Starting Gamdl 3.9.1") == .started(version: "3.9.1"))
    }

    @Test("ANSI color codes are ignored")
    func ansi() {
        let line = "\u{1B}[32m[INFO     19:09:35]\u{1B}[0m Starting Gamdl 3.9.1"
        #expect(GamdlOutputParser.parseLine(line) == .started(version: "3.9.1"))
    }

    @Test("Processing URL")
    func processing() {
        let line = #"[INFO     19:09:35] [URL   1/3  ] Processing "https://music.apple.com/fr/album/x/1""#
        #expect(GamdlOutputParser.parseLine(line) == .processingURL(index: 1, total: 3, url: "https://music.apple.com/fr/album/x/1"))
    }

    @Test("Track start with position")
    func trackStarted() {
        let line = #"[INFO     19:09:36] [Track   4/12 ] Downloading "I Love the Nightlife (Disco 'Round)""#
        #expect(GamdlOutputParser.parseLine(line) == .trackStarted(TrackPosition(index: 4, total: 12), title: "I Love the Nightlife (Disco 'Round)"))
    }

    @Test("Unknown total (\"-\")")
    func unknownTotal() {
        let line = #"[INFO     19:09:36] [Track   2/-  ] Downloading "Titre""#
        #expect(GamdlOutputParser.parseLine(line) == .trackStarted(TrackPosition(index: 2, total: nil), title: "Titre"))
    }

    @Test("Skipped track gets a translated reason")
    func skipped() {
        // Actual gamdl 3.9.1 message (GamdlDownloaderMediaFileExistsError).
        let line = #"[WARNING  19:10:01] [Track   2/12 ] Skipping "Body Heat": Media file already exists: /x/Alicia Bridges/02 Body Heat.m4a"#
        #expect(GamdlOutputParser.parseLine(line) == .trackSkipped(
            TrackPosition(index: 2, total: 12), title: "Body Heat", reason: "Déjà dans la bibliothèque",
            existingFile: URL(filePath: "/x/Alicia Bridges/02 Body Heat.m4a")
        ))
    }

    @Test("Track skipped for another reason has no file")
    func skippedWithoutFile() {
        let line = #"[WARNING  19:10:01] [Track   1/1  ] Skipping "X": Media is not streamable"#
        #expect(GamdlOutputParser.parseLine(line) == .trackSkipped(TrackPosition(index: 1, total: 1), title: "X", reason: "Indisponible en streaming", existingFile: nil))
    }

    @Test("Track failure")
    func trackFailed() {
        let line = #"[ERROR    19:10:01] [Track   3/12 ] Error downloading "Broken""#
        #expect(GamdlOutputParser.parseLine(line) == .trackFailed(TrackPosition(index: 3, total: 12), title: "Broken"))
    }

    @Test("URL-level error")
    func urlFailed() {
        let line = "[ERROR    19:10:01] [URL   1/1  ] Invalid URL: foo"
        #expect(GamdlOutputParser.parseLine(line) == .urlFailed(message: "Invalid URL: foo"))
    }

    @Test("Final summary")
    func finished() {
        #expect(GamdlOutputParser.parseLine("[INFO     19:09:40] Finished with 2 error(s)") == .finished(errorCount: 2))
    }

    @Test("Fragment count takes precedence over the estimated percentage")
    func progressFragments() throws {
        let event = GamdlOutputParser.parseLine("[download]   1.4% of ~  68.77KiB at      0.00B/s ETA Unknown (frag 7/35)")
        guard case .progress(let p) = event else { Issue.record("pas une progression : \(String(describing: event))"); return }
        #expect(abs(p.fraction - 0.2) < 0.0001)
        #expect(!p.isComplete)
        #expect(p.size == "68.77KiB")
        #expect(p.eta == nil) // "Unknown" is not a duration
    }

    @Test("Completed progress")
    func progressComplete() throws {
        let event = GamdlOutputParser.parseLine("[download] 100% of   12.60MiB in 00:00:00 at 56.11MiB/s")
        guard case .progress(let p) = event else { Issue.record("pas une progression"); return }
        #expect(p.fraction == 1)
        #expect(p.isComplete)
        #expect(p.speed == "56.11MiB/s")
        #expect(p.size == "12.60MiB")
    }

    @Test("Progress without fragments uses the percentage")
    func progressPercent() throws {
        guard case .progress(let p) = GamdlOutputParser.parseLine("[download]  42.0% of 10.00MiB at 2.00MiB/s ETA 00:03") else {
            Issue.record("pas une progression"); return
        }
        #expect(abs(p.fraction - 0.42) < 0.0001)
        #expect(p.eta == "00:03")
    }

    @Test("Unrecognized line goes to the raw log")
    func plain() {
        #expect(GamdlOutputParser.parseLine("Traceback (most recent call last):") == .log(LogLine(level: .plain, text: "Traceback (most recent call last):")))
        #expect(GamdlOutputParser.parseLine("   ") == nil)
    }

    @Test("Splits on \\r and \\n and buffers incomplete lines")
    func feedSplitsAndBuffers() {
        var parser = GamdlOutputParser()
        let first = parser.feed("[download]  10.0% of 1.00MiB\r[download]  20.0% of 1.0")
        #expect(first.count == 1)
        let second = parser.feed("0MiB\r[INFO     19:09:40] Finished with 0 error(s)")
        #expect(second.count == 1)
        #expect(parser.flush() == [.finished(errorCount: 0)])
        #expect(parser.flush().isEmpty)
    }

    @Test("Replaying real gamdl 3.9.1 output (regression)")
    func realFixture() throws {
        var parser = GamdlOutputParser()
        let events = parser.feed(try Fixture.text("gamdl-3.9.1-single-track.txt")) + parser.flush()

        #expect(events.contains(.started(version: "3.9.1")))
        #expect(events.contains(.trackStarted(TrackPosition(index: 1, total: 1), title: "I Love the Nightlife (Disco 'Round)")))
        #expect(events.contains(.finished(errorCount: 0)))

        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        #expect(progress.count > 20)
        #expect(progress.last?.isComplete == true)
        // Fragment-based progress never goes backwards.
        let fractions = progress.map(\.fraction)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Unrecognized reasons keep the original text")
    func unknownReason() {
        #expect(GamdlOutputParser.humanReason("Something odd") == "Something odd")
        #expect(GamdlOutputParser.humanReason("Media is not streamable") == "Indisponible en streaming")
    }
}

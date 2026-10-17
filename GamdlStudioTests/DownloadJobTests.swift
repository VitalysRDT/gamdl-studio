import Foundation
import Testing
@testable import GamdlStudio

@MainActor
@Suite("DownloadJob state machine")
struct DownloadJobTests {
    private func makeJob() -> DownloadJob {
        DownloadJob(link: AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!, options: DownloadOptions())
    }

    @Test("Replaying real output: one track downloaded, no errors")
    func replayFixture() throws {
        let job = makeJob()
        job.markStarted(commandLine: "gamdl …")
        var parser = GamdlOutputParser()
        (parser.feed(try Fixture.text("gamdl-3.9.1-single-track.txt")) + parser.flush()).forEach(job.apply)

        #expect(job.state == .completed(errors: 0))
        #expect(job.gamdlVersion == "3.9.1")
        #expect(job.tracks.count == 1)
        #expect(job.tracks.first?.status == .done)
        #expect(job.downloadedCount == 1)
        #expect(job.overallFraction == 1)
        #expect(job.finishedAt != nil)
    }

    @Test("Overall progress on a 4-track album")
    func overallProgress() {
        let job = makeJob()
        job.state = .running
        job.apply(.trackStarted(TrackPosition(index: 3, total: 4), title: "C"))
        job.apply(.progress(TransferProgress(fraction: 0.5, size: nil, speed: "1MiB/s", eta: "00:02", isComplete: false)))
        #expect(abs(job.overallFraction - 2.5 / 4) < 0.0001)
        #expect(job.speed == "1MiB/s")
    }

    @Test("Track progress never goes backwards")
    func monotonic() {
        let job = makeJob()
        job.state = .running
        job.apply(.trackStarted(nil, title: "A"))
        job.apply(.progress(TransferProgress(fraction: 0.6, size: nil, speed: nil, eta: nil, isComplete: false)))
        job.apply(.progress(TransferProgress(fraction: 0.3, size: nil, speed: nil, eta: nil, isComplete: false)))
        #expect(job.trackFraction == 0.6)
    }

    @Test("Starting a track marks the previous one done")
    func nextTrackClosesPrevious() {
        let job = makeJob()
        job.apply(.trackStarted(TrackPosition(index: 1, total: 2), title: "A"))
        job.apply(.trackStarted(TrackPosition(index: 2, total: 2), title: "B"))
        #expect(job.tracks.map(\.status) == [.done, .downloading])
        #expect(job.currentTrackTitle == "B")
    }

    @Test("Skipped track without a prior Downloading line")
    func skippedAlone() {
        let job = makeJob()
        job.apply(.trackSkipped(TrackPosition(index: 1, total: 3), title: "A", reason: "Déjà dans la bibliothèque", existingFile: nil))
        #expect(job.skippedCount == 1)
        #expect(job.trackIndex == 1)
        #expect(job.trackTotal == 3)
    }

    @Test("Skipped track after Downloading updates the same row")
    func skippedAfterStart() {
        let job = makeJob()
        job.apply(.trackStarted(nil, title: "A"))
        job.apply(.trackSkipped(nil, title: "A", reason: "x", existingFile: URL(filePath: "/m/Alb/01 A.m4a")))
        #expect(job.tracks.count == 1)
        #expect(job.tracks[0].status == .skipped("x"))
        #expect(job.existingFolders.map(\.path) == ["/m/Alb"])
    }

    @Test("Failed track followed by the summary")
    func failedTrack() {
        let job = makeJob()
        job.apply(.trackStarted(nil, title: "A"))
        job.apply(.trackFailed(nil, title: "A"))
        job.apply(.finished(errorCount: 1))
        #expect(job.failedCount == 1)
        #expect(job.state == .completed(errors: 1))
    }

    @Test("Non-zero exit without a summary fails with the last error")
    func crash() {
        let job = makeJob()
        job.state = .running
        job.apply(.urlFailed(message: "Invalid URL"))
        job.markProcessEnded(ProcessResult(exitCode: 1, wasCancelled: false))
        #expect(job.state == .failed("Invalid URL"))
    }

    @Test("Zero exit without a summary completes")
    func exitZeroWithoutFinished() {
        let job = makeJob()
        job.state = .running
        job.apply(.trackStarted(nil, title: "A"))
        job.markProcessEnded(ProcessResult(exitCode: 0, wasCancelled: false))
        #expect(job.state == .completed(errors: 0))
        #expect(job.tracks[0].status == .done)
    }

    @Test("Cancelling marks the current track as failed")
    func cancelled() {
        let job = makeJob()
        job.state = .running
        job.apply(.trackStarted(nil, title: "A"))
        job.markProcessEnded(ProcessResult(exitCode: 130, wasCancelled: true))
        #expect(job.state == .cancelled)
        #expect(job.tracks[0].status == .failed)
    }

    @Test("A received summary is not overridden by the process exit")
    func finishedWins() {
        let job = makeJob()
        job.apply(.finished(errorCount: 0))
        job.markProcessEnded(ProcessResult(exitCode: 1, wasCancelled: false))
        #expect(job.state == .completed(errors: 0))
    }

    @Test("Log size is capped")
    func logLimit() {
        let job = makeJob()
        for i in 0..<(DownloadJob.logLimit + 50) { job.apply(.log(LogLine(level: .plain, text: "\(i)"))) }
        #expect(job.log.count == DownloadJob.logLimit)
        #expect(job.log.last?.text == "\(DownloadJob.logLimit + 49)")
    }

    @Test("History entry has a readable summary")
    func historyEntry() throws {
        let job = makeJob()
        job.apply(.trackStarted(nil, title: "A"))
        job.apply(.trackSkipped(nil, title: "B", reason: "x", existingFile: nil))
        job.apply(.finished(errorCount: 0))
        let entry = try #require(HistoryEntry(job: job))
        #expect(entry.outcome == .completed)
        #expect(entry.summary == "1 titre téléchargé · 1 déjà présent")
        #expect(HistoryEntry(job: makeJob()) == nil) // still queued
    }
}

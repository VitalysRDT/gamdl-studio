import Foundation
import Testing
@testable import GamdlStudio

/// A fake gamdl: a bash script that replays recorded real output, or simulates
/// an error, a long wait or an interactive prompt.
private struct FakeGamdl {
    let dir: URL
    let executable: URL

    init(script: String) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fake-gamdl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        executable = dir.appending(path: "gamdl")
        try ("#!/bin/bash\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    /// Replays the reference output, then exits with `exitCode`.
    static func replaying(exitCode: Int = 0) throws -> FakeGamdl {
        let fixture = Fixture.directory.appending(path: "gamdl-3.9.1-single-track.txt").path
        return try FakeGamdl(script: """
        # Save the received arguments so the test can check them.
        printf '%s\\n' "$@" > "$(dirname "$0")/args.txt"
        cat '\(fixture)'
        exit \(exitCode)
        """)
    }

    var receivedArguments: [String] {
        (try? String(contentsOf: dir.appending(path: "args.txt"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("ProcessRunner (functional)")
struct ProcessRunnerTests {
    @Test("Streams the full output and returns the exit code")
    func streamsOutput() async throws {
        let fake = try FakeGamdl.replaying(exitCode: 0)
        defer { fake.cleanup() }
        let collected = OutputCollector()
        let result = try await ProcessRunner().run(executable: fake.executable, arguments: ["x"], environment: ToolLocator.standard.environment()) {
            collected.append($0)
        }
        #expect(result.succeeded)
        #expect(collected.value == (try Fixture.text("gamdl-3.9.1-single-track.txt")))
    }

    @Test("Non-zero exit code")
    func exitCode() async throws {
        let fake = try FakeGamdl(script: "echo boom >&2; exit 3")
        defer { fake.cleanup() }
        let collected = OutputCollector()
        let result = try await ProcessRunner().run(executable: fake.executable, arguments: [], environment: [:]) { collected.append($0) }
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(collected.value.contains("boom")) // stderr is merged into stdout
    }

    @Test("Closed stdin keeps an interactive prompt from hanging")
    func stdinIsClosed() async throws {
        let fake = try FakeGamdl(script: #"read -r answer; echo "lu:[$answer]""#)
        defer { fake.cleanup() }
        let collected = OutputCollector()
        _ = try await ProcessRunner().run(executable: fake.executable, arguments: [], environment: [:]) { collected.append($0) }
        #expect(collected.value.trimmed == "lu:[]")
    }

    @Test("Cancel sends SIGINT and marks the result cancelled")
    func cancel() async throws {
        let fake = try FakeGamdl(script: "echo start; sleep 30")
        defer { fake.cleanup() }
        let runner = ProcessRunner()
        let started = OutputCollector()
        let task = Task {
            try await runner.run(executable: fake.executable, arguments: [], environment: [:]) { started.append($0) }
        }
        // Wait until the script has actually started.
        for _ in 0..<100 where started.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let begin = Date()
        runner.cancel()
        let result = try await task.value
        #expect(result.wasCancelled)
        #expect(Date().timeIntervalSince(begin) < 5)
    }

    @Test("Cancel also stops child processes")
    func cancelKillsChildren() async throws {
        // The script starts a background child that would write output later.
        let fake = try FakeGamdl(script: "sleep 60 & echo $! > \"$(dirname \"$0\")/child.pid\"; echo go; wait")
        defer { fake.cleanup() }
        let runner = ProcessRunner()
        let out = OutputCollector()
        let task = Task { try await runner.run(executable: fake.executable, arguments: [], environment: [:]) { out.append($0) } }
        for _ in 0..<100 where out.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let child = try #require(Int32((try String(contentsOf: fake.dir.appending(path: "child.pid"), encoding: .utf8)).trimmed))
        #expect(ProcessRunner.descendants(of: runner.processIdentifier).contains(child))

        runner.cancel()
        _ = try await task.value
        // Background jobs ignore SIGINT in a non-interactive bash, so this one
        // goes away at the SIGTERM step, 3 s later.
        for _ in 0..<80 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kill(child, 0) != 0) // the child is gone
    }

    @Test("A runner cannot be started twice")
    func singleUse() async throws {
        let fake = try FakeGamdl(script: "exit 0")
        defer { fake.cleanup() }
        let runner = ProcessRunner()
        _ = try await runner.run(executable: fake.executable, arguments: [], environment: [:]) { _ in }
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run(executable: fake.executable, arguments: [], environment: [:]) { _ in }
        }
    }

    @Test("Missing executable fails to launch")
    func launchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner().run(executable: URL(filePath: "/nexiste/pas"), arguments: [], environment: [:]) { _ in }
        }
    }
}

@MainActor
@Suite("DownloadQueue (integration)")
struct DownloadQueueTests {
    @Test("Personalized playlist: resolved first, then one URL per song")
    func personalizedPlaylist() async throws {
        let fake = try FakeGamdl.replaying()
        defer { fake.cleanup() }
        var env = environment(for: fake, output: fake.dir.appending(path: "out"))
        env.resolvePlaylist = { _, _ in
            ResolvedPlaylist(
                id: "pl.pm-1", name: "En boucle", curator: "Apple Music", artworkURL: nil, storefront: "fr",
                tracks: [
                    .init(id: "111", type: "songs", name: "A", artist: "X", album: nil, durationMs: nil),
                    .init(id: "222", type: "songs", name: "B", artist: "Y", album: nil, durationMs: nil),
                ]
            )
        }
        let queue = DownloadQueue(environment: { env }, previews: NoPreview(), historyStore: nil)
        queue.playSound = false
        var finished = false
        queue.onJobFinished = { _ in finished = true }

        let link = AppleMusicLink(string: "https://music.apple.com/fr/playlist/en-boucle/pl.pm-20e9f373919da080c4b396962bf55294")!
        let job = queue.enqueue(link, options: DownloadOptions())
        try await waitUntil { finished }

        let args = fake.receivedArguments
        #expect(Array(args.suffix(2)) == ["https://music.apple.com/fr/song/111", "https://music.apple.com/fr/song/222"])
        #expect(!args.contains(link.absoluteString))
        #expect(job.preview?.title == "En boucle")
        #expect(job.expandedURLs?.count == 2)
    }

    @Test("Separate stderr keeps stdout clean")
    func separateErrorOutput() async throws {
        let fake = try FakeGamdl(script: "echo log >&2; echo '{\"ok\":true}'")
        defer { fake.cleanup() }
        let out = OutputCollector()
        let err = OutputCollector()
        let result = try await ProcessRunner().run(
            executable: fake.executable, arguments: [], environment: [:],
            separateErrorOutput: { err.append($0) }, onOutput: { out.append($0) }
        )
        #expect(result.succeeded)
        #expect(out.value.trimmed == #"{"ok":true}"#)
        #expect(err.value.trimmed == "log")
    }

    private func environment(for fake: FakeGamdl, output: URL) -> DownloadEnvironment {
        DownloadEnvironment(
            paths: {
                GamdlPaths(gamdl: fake.executable, ffmpeg: nil, cookies: URL(filePath: "/tmp/c.txt"), output: output, temp: fake.dir.appending(path: "temp"))
            },
            processEnvironment: ToolLocator.standard.environment()
        )
    }

    private struct NoPreview: MediaPreviewProviding {
        func preview(for link: AppleMusicLink) async throws -> MediaPreview? { nil }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("End to end with a fake gamdl: job completes, history is written, arguments are passed")
    func endToEnd() async throws {
        let fake = try FakeGamdl.replaying()
        defer { fake.cleanup() }
        let historyFile = fake.dir.appending(path: "history.json")
        let output = fake.dir.appending(path: "out")
        let queue = DownloadQueue(environment: { environment(for: fake, output: output) }, previews: NoPreview(), historyStore: HistoryStore(file: historyFile))
        queue.playSound = false
        queue.notifyOnCompletion = false
        var finishedJobs: [UUID] = []
        queue.onJobFinished = { finishedJobs.append($0.id) }

        let link = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1443802477?i=1443802513")!
        let job = queue.enqueue(link, options: DownloadOptions())
        // "Finished" arrives before the process exits, so wait for the queue's
        // own completion signal rather than just the job state.
        try await waitUntil { !finishedJobs.isEmpty }

        #expect(job.state == .completed(errors: 0))
        #expect(job.downloadedCount == 1)
        #expect(job.gamdlVersion == "3.9.1")
        #expect(finishedJobs == [job.id])
        #expect(queue.history.first?.id == job.id)
        #expect(HistoryStore(file: historyFile).load().first?.downloaded == 1)
        #expect(fake.receivedArguments.last == link.absoluteString)
        #expect(fake.receivedArguments.contains(output.path))
        // The job's temp subfolder is cleaned up.
        #expect(!FileManager.default.fileExists(atPath: fake.dir.appending(path: "temp/\(job.id.uuidString)").path))
    }

    @Test("Runs one gamdl at a time by default, in order")
    func sequential() async throws {
        let fake = try FakeGamdl(script: "sleep 0.3; echo '[INFO     10:00:00] Finished with 0 error(s)'")
        defer { fake.cleanup() }
        let queue = DownloadQueue(environment: { environment(for: fake, output: fake.dir) }, previews: NoPreview(), historyStore: nil)
        queue.playSound = false
        let a = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/a/1")!, options: DownloadOptions())
        let b = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/b/2")!, options: DownloadOptions())
        #expect(a.state == .running)
        #expect(b.state == .queued)
        try await waitUntil { b.state.isFinished }
        #expect(a.state == .completed(errors: 0))
        #expect(b.state == .completed(errors: 0))
        #expect(try #require(a.finishedAt) <= (try #require(b.startedAt)))
    }

    @Test("Cancelling a pending job never launches gamdl")
    func cancelQueued() async throws {
        let fake = try FakeGamdl(script: "sleep 0.5")
        defer { fake.cleanup() }
        let queue = DownloadQueue(environment: { environment(for: fake, output: fake.dir) }, previews: NoPreview(), historyStore: nil)
        queue.playSound = false
        let a = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/a/1")!, options: DownloadOptions())
        let b = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/b/2")!, options: DownloadOptions())
        queue.cancel(b)
        #expect(b.state == .cancelled)
        #expect(b.startedAt == nil)
        try await waitUntil { a.state.isFinished }
        #expect(queue.pendingCount == 0)
    }

    @Test("Invalid environment fails with a readable error and the queue moves on")
    func environmentError() async throws {
        let queue = DownloadQueue(
            environment: { DownloadEnvironment(paths: { throw DownloadQueueError.cookies(.noMediaUserToken) }, processEnvironment: [:]) },
            previews: NoPreview(), historyStore: nil
        )
        queue.playSound = false
        let job = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/a/1")!, options: DownloadOptions())
        try await waitUntil { job.state.isFinished }
        guard case .failed(let message) = job.state else { Issue.record("état \(job.state)"); return }
        #expect(message.contains("media-user-token"))
    }

    @Test("Retry and move up in the queue")
    func retryAndMove() async throws {
        let fake = try FakeGamdl(script: "sleep 0.4; exit 1")
        defer { fake.cleanup() }
        let queue = DownloadQueue(environment: { environment(for: fake, output: fake.dir) }, previews: NoPreview(), historyStore: nil)
        queue.playSound = false
        let a = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/a/1")!, options: DownloadOptions())
        let b = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/b/2")!, options: DownloadOptions())
        let c = queue.enqueue(AppleMusicLink(string: "https://music.apple.com/fr/album/c/3")!, options: DownloadOptions())
        queue.moveUp(c)
        #expect(queue.queued.map(\.id) == [c.id, b.id])

        try await waitUntil { a.state.isFinished }
        guard case .failed = a.state else { Issue.record("attendu : échec"); return }
        queue.retry(a)
        #expect(!queue.jobs.contains { $0.id == a.id })
        #expect(queue.jobs.last?.link == a.link)
        queue.cancelAll()
    }
}

import AppKit
import Foundation
import Observation
import UserNotifications

/// What the queue needs to launch gamdl. Injected so tests can substitute
/// a fake executable.
struct DownloadEnvironment: Sendable {
    var paths: @Sendable () async throws -> GamdlPaths
    var processEnvironment: [String: String]
    var makeRunner: @Sendable () -> ProcessRunner = { ProcessRunner() }
    /// Expands a playlist gamdl rejects (see `AppleMusicLink.needsResolution`).
    var resolvePlaylist: @Sendable (AppleMusicLink, GamdlPaths) async throws -> ResolvedPlaylist = { link, paths in
        try await PlaylistResolver.resolve(link, gamdl: paths.gamdl, cookies: paths.cookies, environment: ToolLocator.standard.environment())
    }

    static func live(settings: SettingsSnapshot, locator: ToolLocator = .standard) -> DownloadEnvironment {
        DownloadEnvironment(
            paths: {
                guard let gamdl = locator.locate("gamdl", override: settings.gamdlOverride) else {
                    throw DownloadQueueError.gamdlMissing
                }
                let cookies = CookieInspector.status(ofFileAt: settings.cookies)
                guard cookies.isUsable else { throw DownloadQueueError.cookies(cookies) }
                try FileManager.default.createDirectory(at: settings.output, withIntermediateDirectories: true)
                return GamdlPaths(
                    gamdl: gamdl,
                    ffmpeg: locator.locate("ffmpeg"),
                    cookies: settings.cookies,
                    output: settings.output,
                    temp: settings.temp
                )
            },
            processEnvironment: locator.environment(),
            resolvePlaylist: { link, paths in
                try await PlaylistResolver.resolve(link, gamdl: paths.gamdl, cookies: paths.cookies, environment: locator.environment())
            }
        )
    }
}

enum DownloadQueueError: LocalizedError {
    case gamdlMissing
    case cookies(CookieStatus)

    var errorDescription: String? {
        switch self {
        case .gamdlMissing: String(localized: "gamdl est introuvable. Installe-le avec « pipx install gamdl ».")
        case .cookies(let status): status.message
        }
    }
}

/// Download queue: runs one or more gamdl processes at a time, in order.
@MainActor
@Observable
final class DownloadQueue {
    private(set) var jobs: [DownloadJob] = []
    private(set) var history: [HistoryEntry] = []
    var maxConcurrent = 1 { didSet { pump() } }

    /// Called after each job finishes (to refresh the library, etc.).
    var onJobFinished: ((DownloadJob) -> Void)?
    var notifyOnCompletion = true
    var playSound = true

    private var runners: [UUID: ProcessRunner] = [:]
    private let environment: () -> DownloadEnvironment
    private let previews: MediaPreviewProviding
    private let historyStore: HistoryStore?

    init(
        environment: @escaping () -> DownloadEnvironment,
        previews: MediaPreviewProviding = MediaPreviewService(),
        historyStore: HistoryStore? = .standard
    ) {
        self.environment = environment
        self.previews = previews
        self.historyStore = historyStore
        history = historyStore?.load() ?? []
    }

    var active: [DownloadJob] { jobs.filter { $0.state.isActive } }
    var queued: [DownloadJob] { jobs.filter { $0.state == .queued } }
    var finished: [DownloadJob] { jobs.filter { $0.state.isFinished }.reversed() }
    var pendingCount: Int { jobs.filter { !$0.state.isFinished }.count }

    /// Overall progress of everything not yet finished (Dock badge).
    var aggregateFraction: Double? {
        let pending = jobs.filter { !$0.state.isFinished }
        guard !pending.isEmpty else { return nil }
        return pending.map(\.overallFraction).reduce(0, +) / Double(pending.count)
    }

    @discardableResult
    func enqueue(_ link: AppleMusicLink, options: DownloadOptions, preview: MediaPreview? = nil) -> DownloadJob {
        let job = DownloadJob(link: link, options: options, preview: preview)
        jobs.append(job)
        if preview == nil { loadPreview(for: job) }
        pump()
        updateDockBadge()
        return job
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .queued:
            job.markProcessEnded(ProcessResult(exitCode: 130, wasCancelled: true))
            finish(job)
        case .running:
            runners[job.id]?.cancel()
        default:
            break
        }
    }

    func cancelAll() {
        jobs.filter { !$0.state.isFinished }.forEach(cancel)
    }

    func retry(_ job: DownloadJob) {
        remove(job)
        enqueue(job.link, options: job.options, preview: job.preview)
    }

    func remove(_ job: DownloadJob) {
        guard job.state.isFinished else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    func clearHistory() {
        history.removeAll()
        historyStore?.save(history)
    }

    /// Moves a pending job up one position.
    func moveUp(_ job: DownloadJob) {
        guard job.state == .queued, let i = jobs.firstIndex(where: { $0.id == job.id }), i > 0,
              let target = jobs[..<i].lastIndex(where: { $0.state == .queued }) else { return }
        jobs.swapAt(i, target)
    }

    // MARK: - Engine

    private func pump() {
        while active.count < maxConcurrent, let next = jobs.first(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ job: DownloadJob) {
        job.state = .running
        job.startedAt = .now
        let env = environment()
        let runner = env.makeRunner()
        runners[job.id] = runner

        Task {
            do {
                var paths = try await env.paths()
                // One temporary subfolder per job, so two concurrent gamdl runs
                // don't clobber each other's partial files.
                paths.temp = paths.temp.appending(path: job.id.uuidString)
                try FileManager.default.createDirectory(at: paths.temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: paths.temp) }

                if job.link.needsResolution {
                    job.note(String(localized: "Lecture de la playlist personnalisée…"))
                    let playlist = try await env.resolvePlaylist(job.link, paths)
                    job.expandedURLs = playlist.trackURLs
                    if job.preview?.tracks.isEmpty ?? true { job.preview = playlist.preview() }
                    job.note(String(localized: "\(playlist.trackURLs.count) morceaux à télécharger"))
                }

                let args = GamdlCommand.arguments(for: job.link, urls: job.expandedURLs, options: job.options, paths: paths)
                job.markStarted(commandLine: GamdlCommand.shellLine(executable: paths.gamdl, arguments: args))

                let parser = ParserBox()
                let result = try await runner.run(
                    executable: paths.gamdl,
                    arguments: args,
                    environment: env.processEnvironment,
                    onOutput: { text in
                        let events = parser.feed(text)
                        guard !events.isEmpty else { return }
                        Task { @MainActor in events.forEach(job.apply) }
                    }
                )
                let tail = parser.flush()
                // Events reach the main thread in order: this block is queued
                // behind the ones already sent by `onOutput`.
                await MainActor.run {
                    tail.forEach(job.apply)
                    job.markProcessEnded(result)
                }
            } catch {
                job.markFailed(error.localizedDescription)
            }
            runners[job.id] = nil
            finish(job)
        }
    }

    private func finish(_ job: DownloadJob) {
        if let entry = HistoryEntry(job: job) {
            history.removeAll { $0.id == entry.id }
            history.insert(entry, at: 0)
            historyStore?.save(history)
        }
        onJobFinished?(job)
        announce(job)
        updateDockBadge()
        pump()
    }

    private func loadPreview(for job: DownloadJob) {
        let link = job.link
        Task {
            if let preview = try? await previews.preview(for: link) {
                job.preview = preview
            }
        }
    }

    // MARK: - User feedback

    private func updateDockBadge() {
        let n = pendingCount
        NSApp?.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    private func announce(_ job: DownloadJob) {
        guard case .completed = job.state else { return }
        if playSound { NSSound(named: "Glass")?.play() }
        guard notifyOnCompletion, NSApp?.isActive == false else { return }
        let content = UNMutableNotificationContent()
        content.title = job.title
        content.body = HistoryEntry(job: job)?.summary ?? String(localized: "Téléchargement terminé")
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// The parser is stateful (incomplete line) and lives on the reading thread.
    private final class ParserBox: @unchecked Sendable {
        private var parser = GamdlOutputParser()
        private let lock = NSLock()
        func feed(_ s: String) -> [GamdlEvent] { lock.withLock { parser.feed(s) } }
        func flush() -> [GamdlEvent] { lock.withLock { parser.flush() } }
    }
}

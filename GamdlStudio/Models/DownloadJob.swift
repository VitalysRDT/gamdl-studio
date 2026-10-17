import Foundation
import Observation

/// A track as it appears in gamdl's output during a job.
struct JobTrack: Hashable, Identifiable, Sendable {
    enum Status: Hashable, Sendable {
        case downloading, done, skipped(String), failed
    }
    let id = UUID()
    let index: Int?
    let title: String
    var status: Status
    /// File on disk when gamdl skipped the track because it already existed.
    var existingFile: URL? = nil
}

/// One download (one URL), from enqueueing to result.
///
/// `apply(_:)` is the state machine. It depends only on parser events, so
/// it can be tested by replaying real gamdl output.
@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum State: Hashable {
        case queued
        case running
        case completed(errors: Int)
        case failed(String)
        case cancelled

        var isActive: Bool { self == .running }
        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            default: false
            }
        }
    }

    let id = UUID()
    let link: AppleMusicLink
    let options: DownloadOptions
    let createdAt = Date()

    var preview: MediaPreview?
    var state: State = .queued
    var tracks: [JobTrack] = []
    var trackIndex: Int?
    var trackTotal: Int?
    var trackFraction: Double = 0
    var speed: String?
    var eta: String?
    var size: String?
    var gamdlVersion: String?
    var startedAt: Date?
    var finishedAt: Date?
    var commandLine: String?
    /// Album folders written or completed during this job.
    var resultFolders: [URL] = []
    /// Song URLs gamdl is given instead of the link, when the link had to be
    /// expanded first (personalized playlists).
    var expandedURLs: [String]?
    private(set) var log: [LogLine] = []
    private(set) var lastError: String?
    /// URLs gamdl rejected outright. gamdl does not count these in its
    /// "Finished with N error(s)" summary.
    private(set) var urlFailures = 0
    private var urlIndex: Int?
    private var urlTotal: Int?

    static let logLimit = 3000

    init(link: AppleMusicLink, options: DownloadOptions, preview: MediaPreview? = nil) {
        self.link = link
        self.options = options
        self.preview = preview
    }

    var title: String { preview?.title ?? currentTrackTitle ?? link.kind.label }
    var subtitle: String? { preview?.artist }
    var currentTrackTitle: String? { tracks.last(where: { $0.status == .downloading })?.title ?? tracks.last?.title }

    var downloadedCount: Int { tracks.filter { $0.status == .done }.count }
    var skippedCount: Int { tracks.filter { if case .skipped = $0.status { true } else { false } }.count }
    var failedCount: Int { tracks.filter { $0.status == .failed }.count }

    /// Overall progress, 0…1. With a known total: (finished tracks + current
    /// track) / total; otherwise the current track's progress alone.
    var overallFraction: Double {
        switch state {
        case .completed: return 1
        case .queued: return 0
        default: break
        }
        guard let total = trackTotal, total > 0 else { return trackFraction }
        let finished = Double(max((trackIndex ?? 1) - 1, 0))
        return min((finished + trackFraction) / Double(total), 1)
    }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? .now).timeIntervalSince(startedAt)
    }

    // MARK: - Transitions

    func markStarted(commandLine: String) {
        state = .running
        startedAt = .now
        self.commandLine = commandLine
        append(LogLine(level: .plain, text: "$ " + commandLine))
    }

    func apply(_ event: GamdlEvent) {
        switch event {
        case .started(let version):
            gamdlVersion = version
            append(LogLine(level: .info, text: "gamdl \(version)"))

        case let .processingURL(index, total, url):
            urlIndex = index
            urlTotal = total
            if total > 1 {
                // One URL per song: progress is counted in URLs, each reported as "Track 1/1".
                trackIndex = index
                trackTotal = total
                trackFraction = 0
            }
            append(LogLine(level: .info, text: String(localized: "Analyse de \(url)")))

        case let .trackStarted(position, title):
            closeCurrentTrack(as: .done)
            tracks.append(JobTrack(index: multiURL ? urlIndex : position?.index, title: title, status: .downloading))
            updatePosition(position)
            trackFraction = 0
            speed = nil; eta = nil; size = nil
            append(LogLine(level: .info, text: String(localized: "Téléchargement de « \(title) »")))

        case .progress(let p):
            // yt-dlp sometimes revises its estimate downward; never go backwards.
            trackFraction = max(trackFraction, p.fraction)
            speed = p.speed ?? speed
            eta = p.isComplete ? nil : (p.eta ?? eta)
            size = p.size ?? size

        case let .trackSkipped(position, title, reason, file):
            if let i = tracks.lastIndex(where: { $0.title == title && $0.status == .downloading }) {
                tracks[i].status = .skipped(reason)
                tracks[i].existingFile = file
            } else {
                closeCurrentTrack(as: .done)
                tracks.append(JobTrack(index: multiURL ? urlIndex : position?.index, title: title, status: .skipped(reason), existingFile: file))
            }
            updatePosition(position)
            trackFraction = 1
            append(LogLine(level: .warning, text: String(localized: "« \(title) » ignoré : \(reason)")))

        case let .trackFailed(position, title):
            if let i = tracks.lastIndex(where: { $0.title == title }) {
                tracks[i].status = .failed
            } else {
                tracks.append(JobTrack(index: position?.index, title: title, status: .failed))
            }
            lastError = String(localized: "Échec sur « \(title) »")
            append(LogLine(level: .error, text: String(localized: "Échec du téléchargement de « \(title) »")))

        case .urlFailed(let message):
            lastError = message
            urlFailures += 1
            append(LogLine(level: .error, text: message))

        case .finished(let errors):
            closeCurrentTrack(as: .done)
            trackFraction = 1
            finishedAt = .now
            if urlFailures > 0 && tracks.isEmpty {
                // Every URL was rejected: nothing was attempted, so this is a failure.
                state = .failed(lastError ?? String(localized: "Lien refusé par gamdl"))
            } else {
                state = .completed(errors: errors + urlFailures)
            }
            append(LogLine(level: .info, text: String(localized: "Terminé avec \(errors) erreurs")))

        case .log(let line):
            if line.level == .error { lastError = line.text }
            append(line)
        }
    }

    /// Adds an app-side message to the log.
    func note(_ text: String) {
        append(LogLine(level: .info, text: text))
    }

    private var multiURL: Bool { (urlTotal ?? 1) > 1 }

    private func updatePosition(_ position: TrackPosition?) {
        guard !multiURL, let position else { return }
        trackIndex = position.index
        trackTotal = position.total ?? trackTotal
    }

    /// Process exit. gamdl prints "Finished" before exiting; if it didn't,
    /// the run ended abnormally (crash, cancellation, signal).
    func markProcessEnded(_ result: ProcessResult) {
        finishedAt = finishedAt ?? .now
        if result.wasCancelled {
            closeCurrentTrack(as: .failed)
            state = .cancelled
            append(LogLine(level: .warning, text: String(localized: "Annulé")))
            return
        }
        guard !state.isFinished else { return }
        if result.exitCode == 0 {
            closeCurrentTrack(as: .done)
            state = .completed(errors: failedCount)
        } else {
            closeCurrentTrack(as: .failed)
            state = .failed(lastError ?? String(localized: "gamdl s'est arrêté (code \(result.exitCode))"))
        }
    }

    func markFailed(_ message: String) {
        lastError = message
        finishedAt = .now
        state = .failed(message)
        append(LogLine(level: .error, text: message))
    }

    private func closeCurrentTrack(as status: JobTrack.Status) {
        if let i = tracks.lastIndex(where: { $0.status == .downloading }) { tracks[i].status = status }
    }

    private func append(_ line: LogLine) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// Folders of tracks skipped as already present. The job wrote nothing
    /// there, but that is where the requested content lives.
    var existingFolders: [URL] {
        var seen = Set<URL>()
        return tracks.compactMap { $0.existingFile?.deletingLastPathComponent().standardizedFileURL }
            .filter { seen.insert($0).inserted }
    }

    var logText: String { log.map(\.text).joined(separator: "\n") }
}

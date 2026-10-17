import Foundation

/// Persistent record of a finished download, for the history.
struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    var id: UUID
    let url: String
    let kind: AppleMusicLink.Kind
    let title: String
    let artist: String?
    let artworkURL: URL?
    let outcome: Outcome
    let downloaded: Int
    let skipped: Int
    let failed: Int
    let finishedAt: Date
    let folders: [URL]

    var summary: String {
        switch outcome {
        case .cancelled: return String(localized: "Annulé")
        case .failed: return String(localized: "Échec")
        case .completed:
            var parts: [String] = []
            if downloaded > 0 { parts.append(String(localized: "\(downloaded) titres téléchargés")) }
            if skipped > 0 { parts.append(String(localized: "\(skipped) déjà présents")) }
            if failed > 0 { parts.append(String(localized: "\(failed) erreurs")) }
            return parts.isEmpty ? String(localized: "Rien de nouveau") : parts.joined(separator: " · ")
        }
    }
}

/// History stored as JSON in Application Support, capped at the last 300 entries.
struct HistoryStore: Sendable {
    let file: URL
    static let limit = 300

    static var standard: HistoryStore {
        HistoryStore(file: AppSettings.applicationSupport.appending(path: "history.json"))
    }

    func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    func save(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(entries.prefix(Self.limit))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension HistoryEntry {
    @MainActor init?(job: DownloadJob) {
        let outcome: Outcome
        switch job.state {
        case .completed: outcome = .completed
        case .failed: outcome = .failed
        case .cancelled: outcome = .cancelled
        default: return nil
        }
        self.init(
            id: job.id,
            url: job.link.absoluteString,
            kind: job.link.kind,
            title: job.title,
            artist: job.subtitle,
            artworkURL: job.preview?.artworkURL,
            outcome: outcome,
            downloaded: job.downloadedCount,
            skipped: job.skippedCount,
            failed: job.failedCount,
            finishedAt: job.finishedAt ?? .now,
            folders: job.resultFolders
        )
    }
}

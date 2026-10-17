import Foundation

enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error, plain

    init(gamdlLabel: String) {
        switch gamdlLabel.uppercased() {
        case "DEBUG": self = .debug
        case "INFO", "SUCCESS": self = .info
        case "WARNING": self = .warning
        case "ERROR", "CRITICAL": self = .error
        default: self = .plain
        }
    }
}

struct LogLine: Hashable, Sendable, Codable, Identifiable {
    var id = UUID()
    let level: LogLevel
    let text: String
    var date = Date()

    static func == (a: LogLine, b: LogLine) -> Bool { a.level == b.level && a.text == b.text }
    func hash(into h: inout Hasher) { h.combine(level); h.combine(text) }
}

/// Position of a track in the current batch ("Track   3/12").
/// `total` is `nil` while gamdl doesn't know it yet (it prints "-").
struct TrackPosition: Hashable, Sendable {
    let index: Int
    let total: Int?
}

/// Transfer progress as reported by yt-dlp.
struct TransferProgress: Hashable, Sendable {
    /// 0…1. Based on HLS fragments when known: yt-dlp's raw percentage goes
    /// backwards whenever its size estimate grows.
    let fraction: Double
    let size: String?
    let speed: String?
    let eta: String?
    let isComplete: Bool
}

/// What the UI can react to in gamdl's output.
enum GamdlEvent: Hashable, Sendable {
    case started(version: String)
    case processingURL(index: Int, total: Int, url: String)
    case trackStarted(TrackPosition?, title: String)
    case progress(TransferProgress)
    case trackSkipped(TrackPosition?, title: String, reason: String, existingFile: URL?)
    case trackFailed(TrackPosition?, title: String)
    case urlFailed(message: String)
    case finished(errorCount: Int)
    case log(LogLine)
}

/// Turns raw gamdl 3.9 output into events.
///
/// Observed format (output redirected, so no TTY):
///
///     [INFO     19:09:35] Starting Gamdl 3.9.1
///     [INFO     19:09:35] [URL   1/1  ] Processing "https://…"
///     [INFO     19:09:36] [Track   1/1  ] Downloading "I Love the Nightlife"
///     [download]   2.9% of ~  34.35KiB at 0.00B/s ETA Unknown (frag 0/35)\r
///     [download] 100% of   12.60MiB in 00:00:00 at 56.11MiB/s
///     [WARNING  …] [Track   2/12 ] Skipping "Titre": Media file already exists…
///     [INFO     19:09:40] Finished with 0 error(s)
///
/// yt-dlp progress rewrites the same line with `\r`, so lines are split
/// on `\r` as well as `\n`.
struct GamdlOutputParser {
    private var buffer = ""

    mutating func feed(_ chunk: String) -> [GamdlEvent] {
        buffer += chunk
        var events: [GamdlEvent] = []
        while let cut = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<cut])
            buffer = String(buffer[buffer.index(after: cut)...])
            if let event = Self.parseLine(line) { events.append(event) }
        }
        return events
    }

    /// Last line without a trailing newline (at process exit).
    mutating func flush() -> [GamdlEvent] {
        defer { buffer = "" }
        return Self.parseLine(buffer).map { [$0] } ?? []
    }

    // MARK: - Line by line

    private static let header = TextPatterns.regex(
        #"^\[(DEBUG|INFO|SUCCESS|WARNING|ERROR|CRITICAL)\s+[0-9:]+\]\s*(?:\[(URL|Track)\s+(\d+)/\s*(\S+?)\s*\])?\s?(.*)$"#
    )
    private static let starting = TextPatterns.regex(#"^Starting Gamdl (\S+)"#)
    private static let processing = TextPatterns.regex(#"^Processing "(.*)"$"#)
    private static let downloading = TextPatterns.regex(#"^Downloading "(.*)"$"#)
    private static let skipping = TextPatterns.regex(#"^Skipping "(.*?)": (.*)$"#)
    /// "Media file already exists: /path/01 Title.m4a"
    private static let existingFile = TextPatterns.regex(#"already exists:?\s+(?:at\s+)?(.+)$"#)
    private static let trackError = TextPatterns.regex(#"^Error downloading "(.*)""#)
    private static let finished = TextPatterns.regex(#"^Finished with (\d+) error\(s\)"#)

    private static let downloadLine = TextPatterns.regex(#"^\[download\]\s+(.*)$"#)
    private static let percent = TextPatterns.regex(#"([0-9.]+)%"#)
    private static let size = TextPatterns.regex(#"of\s+(~?)\s*([0-9.]+\s?[KMGT]?i?B)"#)
    private static let speed = TextPatterns.regex(#"at\s+([0-9.]+\s?[KMGT]?i?B/s)"#)
    private static let eta = TextPatterns.regex(#"ETA\s+([0-9:]+)"#)
    private static let fragments = TextPatterns.regex(#"\(frag (\d+)/(\d+)\)"#)

    static func parseLine(_ raw: String) -> GamdlEvent? {
        let line = TextPatterns.stripANSI(raw).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        if let groups = downloadLine.captures(in: line), let body = groups[1] {
            return parseProgress(body)
        }

        guard let groups = header.captures(in: line) else {
            // Unformatted lines: Python tracebacks, ffmpeg warnings…
            return .log(LogLine(level: .plain, text: line))
        }

        let level = LogLevel(gamdlLabel: groups[1] ?? "")
        let action = groups[2]
        let index = groups[3].flatMap(Int.init)
        let total = groups[4].flatMap(Int.init) // "-" → nil
        let message = groups[5] ?? ""
        let position = (action == "Track" && index != nil) ? TrackPosition(index: index!, total: total) : nil

        if let m = starting.captures(in: message), let version = m[1] {
            return .started(version: version)
        }
        if action == "URL", let m = processing.captures(in: message), let url = m[1] {
            return .processingURL(index: index ?? 1, total: total ?? 1, url: url)
        }
        if let m = downloading.captures(in: message), let title = m[1] {
            return .trackStarted(position, title: title)
        }
        if let m = skipping.captures(in: message), let title = m[1] {
            let raw = m[2] ?? ""
            let file = existingFile.captures(in: raw)?[1].map { URL(filePath: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))) }
            return .trackSkipped(position, title: title, reason: humanReason(raw), existingFile: file)
        }
        if let m = trackError.captures(in: message), let title = m[1] {
            return .trackFailed(position, title: title)
        }
        if let m = finished.captures(in: message), let n = m[1].flatMap(Int.init) {
            return .finished(errorCount: n)
        }
        if action == "URL", level == .error {
            return .urlFailed(message: humanURLError(message))
        }
        return .log(LogLine(level: level, text: message.isEmpty ? line : message))
    }

    private static func parseProgress(_ body: String) -> GamdlEvent {
        let pct = percent.captures(in: body)?[1].flatMap(Double.init)
        let sizeGroups = size.captures(in: body)
        let isEstimate = (sizeGroups?[1] ?? "") == "~"
        let sizeText = sizeGroups?[2]
        let speedText = speed.captures(in: body)?[1]
        let etaText = eta.captures(in: body)?[1]

        var fraction = (pct ?? 0) / 100
        if let frag = fragments.captures(in: body),
           let done = frag[1].flatMap(Double.init), let all = frag[2].flatMap(Double.init), all > 0 {
            fraction = done / all
        }
        let complete = (pct ?? 0) >= 100 && !isEstimate
        if complete { fraction = 1 }

        return .progress(TransferProgress(
            fraction: min(max(fraction, 0), 1),
            size: sizeText,
            speed: speedText,
            eta: etaText,
            isComplete: complete
        ))
    }

    /// gamdl's reasons are English exception messages. The most common ones
    /// are translated; the rest pass through unchanged.
    static func humanURLError(_ message: String) -> String {
        if message.lowercased().contains("not valid or supported") { return String(localized: "Lien non pris en charge par gamdl") }
        return message
    }

    static func humanReason(_ reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("already exists") { return String(localized: "Déjà dans la bibliothèque") }
        if lower.contains("not streamable") { return String(localized: "Indisponible en streaming") }
        if lower.contains("format not available") || lower.contains("codec") { return String(localized: "Format demandé indisponible") }
        if lower.contains("decryption") { return String(localized: "Déchiffrement impossible sans wrapper") }
        if lower.contains("synced lyrics") { return String(localized: "Pas de paroles synchronisées") }
        if lower.contains("not found") && lower.contains("dependency") { return String(localized: "Dépendance manquante (ffmpeg ?)") }
        return reason
    }
}

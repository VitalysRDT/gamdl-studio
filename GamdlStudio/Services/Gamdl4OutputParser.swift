import Foundation

/// Turns gamdl 4 output into the same events as gamdl 3's.
///
/// gamdl 4 draws its progress with a transient Rich display, which prints
/// nothing when the output is a pipe. What remains are permanent lines:
///
///     Gamdl 4.1.2
///     ✓ Authenticated
///     ✓ I Love the Nightlife: downloaded → /Music/…/01 I Love the Nightlife.m4a
///     ↷ Titre: skipped → /Music/…/02 Titre.m4a
///     ↷ Autre: skipped (Media is not streamable)
///     Finished: 1 downloaded, 0 overwritten, 2 skipped, 1 failed, 0 finalization failures (4 discovered)
///     Errors (1):
///       ✗ Cassé: Unable to fetch stream
///
/// When gamdl runs through `gamdl_bridge.py`, track starts, transfer progress
/// and failures also arrive as `@gamdl-studio {json}` lines.
///
/// gamdl 4 lists failures after its summary, so the summary is held back and
/// emitted by `flush()`, once the process has exited.
struct Gamdl4OutputParser {
    static let marker = "@gamdl-studio "

    private enum Section { case main, errors, tracebacks }

    private var buffer = ""
    private var section = Section.main
    private var summary: (failed: Int, finalization: Int)?
    /// "Source" rows: gamdl counts them as failures, the job counts them as
    /// rejected links.
    private var sourceFailures = 0
    /// Titles announced by the bridge, to split "✗ Title: with colon: message".
    private var knownTitles: [String] = []
    /// Failures the bridge already reported as they happened.
    private var reportedFailures: Set<String> = []

    mutating func feed(_ chunk: String) -> [GamdlEvent] {
        buffer += chunk
        var events: [GamdlEvent] = []
        while let cut = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<cut])
            buffer = String(buffer[buffer.index(after: cut)...])
            events += parseLine(line)
        }
        return events
    }

    /// Last line without a trailing newline, then the held-back summary.
    mutating func flush() -> [GamdlEvent] {
        var events = parseLine(buffer)
        buffer = ""
        if let summary {
            let errors = max(summary.failed + summary.finalization - sourceFailures, 0)
            events.append(.finished(errorCount: errors))
            self.summary = nil
        }
        return events
    }

    // MARK: - Line by line

    private static let banner = TextPatterns.regex(#"^Gamdl (\d[0-9A-Za-z.\-+]*)$"#)
    /// "Title: downloaded → /path", "Title: skipped (reason)"…
    private static let outcome = TextPatterns.regex(
        #"^(.+?): (downloaded|overwritten|skipped|media saved \(finalization incomplete\))(.*)$"#
    )
    private static let finished = TextPatterns.regex(
        #"^Finished: \d+ downloaded, \d+ overwritten, \d+ skipped, (\d+) failed, (\d+) finalization failures"#
    )
    private static let errorsHeader = TextPatterns.regex(#"^Errors \(\d+\):$"#)
    private static let tracebacksHeader = TextPatterns.regex(#"^Exception tracebacks \(\d+\):$"#)
    /// gamdl appends the exception type to unexpected errors.
    private static let exceptionSuffix = TextPatterns.regex(#"\s\([A-Za-z_][A-Za-z0-9_]*\)$"#)

    mutating func parseLine(_ raw: String) -> [GamdlEvent] {
        let line = TextPatterns.stripANSI(raw).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }

        if line.hasPrefix(Self.marker) {
            return bridgeEvent(String(line.dropFirst(Self.marker.count)))
        }
        if Self.tracebacksHeader.matches(line) {
            section = .tracebacks
            return [.log(LogLine(level: .error, text: line))]
        }
        if section == .tracebacks {
            return [.log(LogLine(level: .plain, text: line))]
        }
        if Self.errorsHeader.matches(line) {
            section = .errors
            return []
        }
        if section == .errors, line.hasPrefix("✗ ") {
            return failureRow(String(line.dropFirst(2)))
        }

        if let m = Self.banner.captures(in: line), let version = m[1] {
            return [.started(version: version)]
        }
        if let m = Self.finished.captures(in: line) {
            summary = (m[1].flatMap(Int.init) ?? 0, m[2].flatMap(Int.init) ?? 0)
            return [.log(LogLine(level: .info, text: line))]
        }
        if line == "No supported media found at this URL." {
            return [.urlFailed(message: String(localized: "Aucun média téléchargeable à ce lien"))]
        }
        if line.hasPrefix("✓ ") || line.hasPrefix("↷ ") {
            if let event = trackOutcome(String(line.dropFirst(2))) { return [event] }
            return [.log(LogLine(level: .info, text: String(line.dropFirst(2))))]
        }
        if line.hasPrefix("✗ ") { return [.log(LogLine(level: .error, text: String(line.dropFirst(2))))] }
        if line.hasPrefix("! ") { return [.log(LogLine(level: .warning, text: String(line.dropFirst(2))))] }
        if line.hasPrefix("• ") { return [.log(LogLine(level: .info, text: String(line.dropFirst(2))))] }
        // Tracebacks, "Created config at …", anything new.
        return [.log(LogLine(level: .plain, text: line))]
    }

    private func trackOutcome(_ text: String) -> GamdlEvent? {
        guard let m = Self.outcome.captures(in: text), let title = m[1], let status = m[2] else { return nil }
        // The rest is " (reason)" and/or " → /path", in that order.
        var rest = (m[3] ?? "").trimmed
        var file: URL?
        if let arrow = rest.range(of: "→ ") {
            let path = String(rest[arrow.upperBound...]).trimmed
            if !path.isEmpty { file = URL(filePath: path) }
            rest = String(rest[..<arrow.lowerBound]).trimmed
        }
        if status == "skipped" {
            let reason = rest.hasPrefix("(") && rest.hasSuffix(")") ? String(rest.dropFirst().dropLast()) : rest
            // No reason: the file is already there.
            let human = GamdlOutputParser.humanReason(reason.isEmpty ? "already exists" : reason)
            return .trackSkipped(nil, title: title, reason: human, existingFile: file)
        }
        return .trackCompleted(nil, title: title, file: file)
    }

    /// "Title: message" under "Errors (N):". "Session" and "Source" are not
    /// tracks: the whole run, or the link itself, failed.
    private mutating func failureRow(_ text: String) -> [GamdlEvent] {
        let (label, message) = splitFailure(text)
        switch label {
        case "Session":
            return [.log(LogLine(level: .error, text: String(localized: "Session Apple Music : \(message)")))]
        case "Source":
            sourceFailures += 1
            return [.urlFailed(message: GamdlOutputParser.humanURLError(message))]
        default:
            let detail = LogLine(level: .error, text: "\(label) : \(message)")
            if reportedFailures.contains(label) { return [.log(detail)] }
            return [.trackFailed(nil, title: label), .log(detail)]
        }
    }

    private func splitFailure(_ text: String) -> (label: String, message: String) {
        // The longest known title wins, so a colon inside it isn't taken as
        // the separator.
        for title in knownTitles.sorted(by: { $0.count > $1.count }) where text.hasPrefix(title + ": ") {
            return (title, cleanMessage(String(text.dropFirst(title.count + 2))))
        }
        guard let sep = text.range(of: ": ") else { return (text, "") }
        return (String(text[..<sep.lowerBound]), cleanMessage(String(text[sep.upperBound...])))
    }

    private func cleanMessage(_ message: String) -> String {
        let range = NSRange(message.startIndex..., in: message)
        return Self.exceptionSuffix.stringByReplacingMatches(in: message, range: range, withTemplate: "")
    }

    // MARK: - Bridge

    private struct BridgeMessage: Decodable {
        let e: String
        let i: Int?
        let title: String?
        let pct: Double?
        let bytes: Int64?
        let total: Int64?
        let elapsed: Double?
        let message: String?
    }

    private mutating func bridgeEvent(_ json: String) -> [GamdlEvent] {
        guard let message = try? JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8)) else {
            return [.log(LogLine(level: .plain, text: Self.marker + json))]
        }
        let position = message.i.map { TrackPosition(index: $0, total: nil) }
        switch message.e {
        case "track":
            guard let title = message.title else { return [] }
            knownTitles.append(title)
            return [.trackStarted(position, title: title)]
        case "progress":
            return [.progress(Self.transfer(message))]
        case "failed":
            guard let title = message.title else { return [] }
            reportedFailures.insert(title)
            return [.trackFailed(position, title: title)]
        default:
            return []
        }
    }

    private static func transfer(_ m: BridgeMessage) -> TransferProgress {
        let percent = min(max(m.pct ?? 0, 0), 100)
        let complete = percent >= 100
        var speed: String?
        var eta: String?
        if let bytes = m.bytes, let elapsed = m.elapsed, elapsed > 0, bytes > 0 {
            let rate = Double(bytes) / elapsed
            speed = Formatters.bytes(Int64(rate)) + "/s"
            if let total = m.total, total > bytes, !complete {
                eta = Formatters.duration(seconds: Double(total - bytes) / rate)
            }
        }
        return TransferProgress(
            fraction: percent / 100,
            size: m.total.map(Formatters.bytes),
            speed: speed,
            eta: eta,
            isComplete: complete
        )
    }
}

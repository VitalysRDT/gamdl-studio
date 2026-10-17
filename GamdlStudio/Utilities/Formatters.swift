import Foundation

/// French-localized formatting shared by views and models.
enum Formatters {
    static let french = Locale(identifier: "fr_FR")

    static func duration(milliseconds: Int) -> String {
        duration(seconds: Double(milliseconds) / 1000)
    }

    /// "3:07" or "1:02:45".
    static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1 h 12 min", for an album's total duration.
    static func longDuration(milliseconds: Int) -> String {
        let minutes = Int((Double(milliseconds) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        // Otherwise a job finished 200 ms ago would read "dans 0 seconde".
        if abs(date.timeIntervalSince(now)) < 10 { return "à l'instant" }
        let f = RelativeDateTimeFormatter()
        f.locale = french
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(french))
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(french))
    }

    /// Simple pluralization: "1 titre", "12 titres".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n > 1 ? (plural ?? singular + "s") : singular)"
    }
}

extension URL {
    /// `~/Music/…` rather than `/Users/name/Music/…`.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

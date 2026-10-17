import Foundation

enum LyricsText {
    /// "[00:12.34]Lyrics" → "Lyrics". Also strips LRC header tags
    /// ([ar:], [ti:], [length:]…) and timestamped words <00:12.34>.
    static func plain(fromLRC raw: String) -> String {
        let timestamp = TextPatterns.regex(#"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#)
        let wordStamp = TextPatterns.regex(#"<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>"#)
        let tag = TextPatterns.regex(#"^\[[a-z]+:.*\]$"#, options: .caseInsensitive)

        let lines = raw.components(separatedBy: .newlines).compactMap { line -> String? in
            if tag.matches(line.trimmed) { return nil }
            var text = line
            for re in [timestamp, wordStamp] {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
            return text.trimmed
        }
        // Consecutive blank lines (instrumentals) collapse into one.
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmed
    }
}

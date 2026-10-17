import Foundation

/// Small helpers for regular expressions and terminal text.
///
/// `NSRegularExpression` rather than `Regex`: patterns are strings built at
/// runtime, and the Foundation API returns optional groups without the
/// `AnyRegexOutput` typing, which is heavier to work with here.
enum TextPatterns {
    /// ANSI escape sequences (colors, line erase, cursor).
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    /// Strips the color codes gamdl (via Rich/loguru) emits even when output
    /// isn't a terminal.
    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansi.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Compiles a pattern known at compile time. An invalid pattern is a
    /// programmer error, so crash early, in tests.
    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid pattern \(pattern): \(error)")
        }
    }
}

extension NSRegularExpression {
    /// Captured groups of the first match, `nil` if nothing matches.
    /// Index 0 is the whole match; an unmatched group is `nil`.
    func captures(in text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let r = match.range(at: index)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

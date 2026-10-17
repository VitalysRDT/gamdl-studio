import Foundation

/// One record from a Netscape export (`cookies.txt`).
struct NetscapeCookie: Hashable, Sendable {
    let domain: String
    let path: String
    let isSecure: Bool
    /// Epoch seconds; 0 means a session cookie with no expiry.
    let expires: Int64
    let name: String
    let value: String
    let isHTTPOnly: Bool
    /// Original line, written back verbatim on import.
    let rawLine: String

    var expiryDate: Date? { expires > 0 ? Date(timeIntervalSince1970: TimeInterval(expires)) : nil }
}

/// Status of a cookies file, in the order the checks are applied.
enum CookieStatus: Hashable, Sendable {
    case missing
    case invalidFormat
    case noMediaUserToken
    case expired(Date)
    case valid(appleCookies: Int, expiresAt: Date?)

    var isUsable: Bool {
        if case .valid = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .missing: String(localized: "Aucun fichier de cookies")
        case .invalidFormat: String(localized: "Format non reconnu")
        case .noMediaUserToken: String(localized: "Session Apple Music absente")
        case .expired: String(localized: "Session expirée")
        case .valid: String(localized: "Session Apple Music active")
        }
    }

    var message: String {
        switch self {
        case .missing:
            String(localized: "Le fichier de cookies est absent ou vide.")
        case .invalidFormat:
            String(localized: "Ce n'est pas un export Netscape (lignes à 7 champs tabulés). Un export JSON ne convient pas.")
        case .noMediaUserToken:
            String(localized: "Le cookie « media-user-token » manque : l'export ne vient pas d'un onglet music.apple.com connecté.")
        case .expired(let date):
            String(localized: "Le cookie « media-user-token » a expiré le \(Formatters.day(date)).")
        case let .valid(count, expiresAt):
            if let expiresAt {
                String(localized: "\(count) cookies Apple, media-user-token valable jusqu'au \(Formatters.day(expiresAt)).")
            } else {
                String(localized: "\(count) cookies Apple, media-user-token de session.")
            }
        }
    }
}

enum CookieInspectorError: LocalizedError {
    case unreadable(URL)
    case unusable(CookieStatus)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): String(localized: "Impossible de lire \(url.lastPathComponent).")
        case .unusable(let status): status.message
        }
    }
}

enum CookieInspector {
    static let header = "# Netscape HTTP Cookie File"
    static let tokenName = "media-user-token"
    private static let httpOnlyPrefix = "#HttpOnly_"

    /// Netscape records in a text. HttpOnly cookies are prefixed with
    /// "#HttpOnly_": they are not comments and must be kept.
    static func parse(_ text: String) -> [NetscapeCookie] {
        text.split(whereSeparator: \.isNewline).compactMap { sub in
            let line = String(sub)
            var body = line
            var httpOnly = false
            if line.hasPrefix(httpOnlyPrefix) {
                body = String(line.dropFirst(httpOnlyPrefix.count))
                httpOnly = true
            } else if line.hasPrefix("#") {
                return nil
            }
            let fields = body.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            return NetscapeCookie(
                domain: fields[0],
                path: fields[2],
                isSecure: fields[3].uppercased() == "TRUE",
                expires: Int64(fields[4]) ?? 0,
                name: fields[5],
                value: fields[6...].joined(separator: "\t"),
                isHTTPOnly: httpOnly,
                rawLine: line
            )
        }
    }

    /// "apple.com" or a subdomain. The leading dot matters: without it
    /// "myapple.com" would match and third-party cookies would be copied.
    static func isAppleDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return d == "apple.com" || d == ".apple.com" || d.hasSuffix(".apple.com")
    }

    static func status(of text: String?, now: Date = .now) -> CookieStatus {
        guard let text, !text.trimmed.isEmpty else { return .missing }
        let cookies = parse(text)
        guard !cookies.isEmpty else { return .invalidFormat }

        let apple = cookies.filter { isAppleDomain($0.domain) }
        guard let token = apple.first(where: { $0.name == tokenName }) else { return .noMediaUserToken }

        if let expiry = token.expiryDate, expiry < now { return .expired(expiry) }
        return .valid(appleCookies: apple.count, expiresAt: token.expiryDate)
    }

    static func status(ofFileAt url: URL, now: Date = .now) -> CookieStatus {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .missing }
        return status(of: String(decoding: data, as: UTF8.self), now: now)
    }

    /// Keeps only the Apple cookies from an export (often the whole browser's).
    static func extractApple(from text: String) -> String {
        let lines = parse(text).filter { isAppleDomain($0.domain) }.map(\.rawLine)
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    /// Filters, validates and installs an export: atomic write, mode 600.
    /// The existing file is replaced only if the new one is usable.
    @discardableResult
    static func install(from source: URL, to destination: URL, now: Date = .now) throws -> CookieStatus {
        guard let data = try? Data(contentsOf: source) else { throw CookieInspectorError.unreadable(source) }
        let filtered = extractApple(from: String(decoding: data, as: UTF8.self))
        let status = status(of: filtered, now: now)
        guard status.isUsable else { throw CookieInspectorError.unusable(status) }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(filtered.utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return status
    }
}

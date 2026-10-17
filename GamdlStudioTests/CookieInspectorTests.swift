import Foundation
import Testing
@testable import GamdlStudio

/// Parsing and validation of Netscape cookies.txt exports: format detection,
/// the media-user-token requirement, expiry, Apple domain filtering and
/// installation on disk.
@Suite("CookieInspector")
struct CookieInspectorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Int64 { Int64(now.timeIntervalSince1970) + 86_400 }
    private var past: Int64 { Int64(now.timeIntervalSince1970) - 86_400 }

    private func line(_ domain: String, _ expires: Int64, _ name: String, _ value: String) -> String {
        [domain, "TRUE", "/", "TRUE", String(expires), name, value].joined(separator: "\t")
    }

    private func file(_ lines: String...) -> String {
        (["# Netscape HTTP Cookie File"] + lines).joined(separator: "\n")
    }

    @Test("Valid file")
    func valid() {
        let text = file(
            line(".apple.com", future, "myacinfo", "AAAA"),
            line(".music.apple.com", future, "media-user-token", "BBBB"),
            line(".music.apple.com", future, "itua", "fr")
        )
        let status = CookieInspector.status(of: text, now: now)
        #expect(status == .valid(appleCookies: 3, expiresAt: Date(timeIntervalSince1970: TimeInterval(future))))
        #expect(status.isUsable)
        #expect(status.message.contains("media-user-token"))
    }

    @Test("Session cookie (expiry 0)")
    func session() {
        let status = CookieInspector.status(of: file(line(".music.apple.com", 0, "media-user-token", "B")), now: now)
        #expect(status == .valid(appleCookies: 1, expiresAt: nil))
    }

    @Test("Missing or empty")
    func missing() {
        #expect(CookieInspector.status(of: nil, now: now) == .missing)
        #expect(CookieInspector.status(of: "  \n", now: now) == .missing)
        #expect(CookieInspector.status(ofFileAt: URL(filePath: "/nexiste/pas.txt"), now: now) == .missing)
    }

    @Test("JSON instead of Netscape format")
    func json() {
        let status = CookieInspector.status(of: #"[{"domain":".apple.com","name":"media-user-token","value":"B"}]"#, now: now)
        #expect(status == .invalidFormat)
    }

    @Test("Spaces instead of tabs is an invalid format")
    func spaces() {
        #expect(CookieInspector.status(of: ".apple.com TRUE / TRUE 0 media-user-token B", now: now) == .invalidFormat)
    }

    @Test("No media-user-token")
    func noToken() {
        let status = CookieInspector.status(of: file(
            line(".apple.com", future, "myacinfo", "A"),
            line(".github.com", future, "session", "C")
        ), now: now)
        #expect(status == .noMediaUserToken)
        #expect(status.message.contains("music.apple.com"))
    }

    @Test("media-user-token on a third-party domain is ignored")
    func tokenOnOtherDomain() {
        #expect(CookieInspector.status(of: file(line("myapple.com", future, "media-user-token", "EVIL")), now: now) == .noMediaUserToken)
    }

    @Test("Expired media-user-token")
    func expired() {
        let status = CookieInspector.status(of: file(line(".music.apple.com", past, "media-user-token", "B")), now: now)
        #expect(status == .expired(Date(timeIntervalSince1970: TimeInterval(past))))
        #expect(!status.isUsable)
    }

    @Test("HttpOnly cookies are kept")
    func httpOnly() {
        let text = file("#HttpOnly_" + line(".music.apple.com", future, "media-user-token", "B"))
        let cookies = CookieInspector.parse(text)
        #expect(cookies.count == 1)
        #expect(cookies[0].isHTTPOnly)
        #expect(cookies[0].domain == ".music.apple.com")
        #expect(CookieInspector.status(of: text, now: now).isUsable)
    }

    @Test("Apple domains", arguments: [
        ("apple.com", true), (".apple.com", true), (".music.apple.com", true), ("buy.itunes.apple.com", true),
        ("myapple.com", false), ("apple.com.evil.net", false), (".github.com", false),
    ])
    func appleDomains(domain: String, expected: Bool) {
        #expect(CookieInspector.isAppleDomain(domain) == expected)
    }

    @Test("Extraction keeps only Apple cookies")
    func extract() {
        let mixed = file(
            line(".google.com", future, "NID", "Z"),
            line(".music.apple.com", future, "media-user-token", "B"),
            line(".apple.com", future, "myacinfo", "A"),
            line("myapple.com", future, "tracker", "EVIL"),
            line(".github.com", future, "session", "C")
        )
        let out = CookieInspector.extractApple(from: mixed)
        #expect(out.hasPrefix("# Netscape HTTP Cookie File\n"))
        #expect(CookieInspector.parse(out).count == 2)
        #expect(!out.contains("google") && !out.contains("github") && !out.contains("myapple"))
        #expect(CookieInspector.status(of: out, now: now).isUsable)
    }

    // MARK: - Integration (file system)

    @Test("Install filters cookies, sets mode 600 and stays usable")
    func install() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appending(path: "export.txt")
        try file(
            line(".google.com", future, "NID", "Z"),
            line(".music.apple.com", future, "media-user-token", "B")
        ).write(to: source, atomically: true, encoding: .utf8)

        let destination = dir.appending(path: "sub/cookies.txt")
        let status = try CookieInspector.install(from: source, to: destination, now: now)
        #expect(status.isUsable)

        let perms = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        let installed = try String(contentsOf: destination, encoding: .utf8)
        #expect(!installed.contains("google"))
    }

    @Test("Rejected install leaves the existing file in place")
    func installRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: "cookies.txt")
        try "ancien".write(to: destination, atomically: true, encoding: .utf8)
        let source = dir.appending(path: "bad.txt")
        try file(line(".github.com", future, "session", "C")).write(to: source, atomically: true, encoding: .utf8)

        #expect(throws: CookieInspectorError.self) {
            try CookieInspector.install(from: source, to: destination, now: now)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "ancien")
    }
}

import Foundation
import Testing
@testable import GamdlStudio

/// A valid wrapper-v2 1.x `/info`, field for field what gamdl 4.1.2 accepts.
private let goodInfo: [String: Any] = [
    "version": "1.2.0", "protocol_version": 1, "architecture": "x86_64",
    "profile": "apple-music-1109-x86_64", "context_supported": true,
    "context_format": "temari", "decryption": "client_side",
]

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

@Suite("Wrapper probe")
struct WrapperProbeTests {
    @Test("A compatible, signed-in wrapper is ready")
    func ready() {
        let status = WrapperProbe.status(info: json(goodInfo), session: json(["state": "authenticated"]))
        #expect(status == .ready(version: "1.2.0", architecture: "x86_64"))
        #expect(status.isReady)
    }

    @Test("A wrapper without an Apple Account session is logged out")
    func loggedOut() {
        #expect(WrapperProbe.status(info: json(goodInfo), session: json(["state": "logged_out"])) == .loggedOut)
        #expect(WrapperProbe.status(info: json(goodInfo), session: Data()) == .loggedOut)
    }

    @Test("What gamdl 4.1.2 refuses is reported precisely", arguments: [
        ("version", "0.9.0" as Any),
        ("version", "2.0.0" as Any),
        ("protocol_version", 2 as Any),
        ("architecture", "armv7" as Any),
        ("profile", "apple-music-1000-x86_64" as Any),
        ("context_supported", false as Any),
        ("context_format", "other" as Any),
        ("decryption", "server_side" as Any),
    ])
    func incompatible(field: String, value: Any) {
        var info = goodInfo
        info[field] = value
        guard case .incompatible = WrapperProbe.status(info: json(info), session: json(["state": "authenticated"])) else {
            Issue.record("\(field)=\(value) should be incompatible")
            return
        }
    }

    @Test("ARM64 profile is accepted")
    func arm64() {
        var info = goodInfo
        info["architecture"] = "arm64-v8a"
        info["profile"] = "apple-music-1109-arm64-v8a"
        #expect(WrapperProbe.incompatibility(info: info) == nil)
    }

    @Test("Wrapper URL must be http(s) with a host", arguments: [
        ("http://127.0.0.1:8080", true), ("https://wrapper.lan", true), (" http://10.0.0.2:8080 ", true),
        ("127.0.0.1:8080", false), ("ftp://host", false), ("", false), ("http://", false),
    ])
    func baseURL(text: String, valid: Bool) {
        #expect((WrapperProbe.baseURL(text) != nil) == valid)
    }

    @Test("Nothing listening: unreachable, quickly")
    func closedPort() async {
        let start = Date()
        let status = await WrapperProbe.check("http://127.0.0.1:9", timeout: 2)
        guard case .unreachable = status else { Issue.record("\(status)"); return }
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite("Session settings")
struct GamdlSessionTests {
    @Test("Saved session settings load field by field")
    func tolerant() throws {
        let s = try JSONDecoder().decode(GamdlSession.self, from: Data(#"{"authMode":"wrapper","drmBackend":"nope","storefront":"fr"}"#.utf8))
        #expect(s.authMode == .wrapper)
        #expect(s.drmBackend == nil)
        #expect(s.storefront == "fr")
        #expect(s.wrapperURL == GamdlSession.defaultWrapperURL)
        #expect(try JSONDecoder().decode(GamdlSession.self, from: Data("{}".utf8)) == GamdlSession())
    }

    @Test("Device path: empty is nil, ~ is expanded")
    func devicePath() {
        var s = GamdlSession()
        #expect(s.expandedDevicePath == nil)
        s.devicePath = "~/device.wvd"
        #expect(s.expandedDevicePath == FileManager.default.homeDirectoryForCurrentUser.appending(path: "device.wvd").path)
    }
}

@Suite("Terminal launcher")
struct TerminalLauncherTests {
    @Test("The auth script runs gamdl auth, quoting a path with spaces")
    func script() {
        let text = TerminalLauncher.script(running: URL(filePath: "/Users/me/Library/Application Support/pipx/venvs/gamdl/bin/gamdl"))
        #expect(text.hasPrefix("#!/bin/sh\n"))
        #expect(text.contains("exec '/Users/me/Library/Application Support/pipx/venvs/gamdl/bin/gamdl' auth"))
    }
}

@Suite("GamdlCommand: session settings")
struct SessionCommandTests {
    private let base = GamdlPaths(
        gamdl: URL(filePath: "/u/.local/bin/gamdl"), ffmpeg: nil,
        cookies: URL(filePath: "/u/cookies.txt"), output: URL(filePath: "/u/Music"),
        temp: URL(filePath: "/tmp/g"), generation: .v4
    )
    private let album = AppleMusicLink(string: "https://music.apple.com/fr/album/x/1")!

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test("Cookies mode: cookies path, no wrapper URL, nothing else by default")
    func cookies() {
        let args = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: base)
        #expect(value(after: "--auth-mode", in: args) == "cookies")
        #expect(value(after: "--cookies-path", in: args) == "/u/cookies.txt")
        for flag in ["--wrapper-url", "--storefront", "--language", "--drm-backend", "--device-path"] {
            #expect(!args.contains(flag), "\(flag)")
        }
    }

    @Test("Wrapper mode: wrapper URL instead of the cookies path")
    func wrapper() {
        var p = base
        p.session.authMode = .wrapper
        p.session.wrapperURL = " http://10.0.0.2:8080 "
        let args = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: p)
        #expect(value(after: "--auth-mode", in: args) == "wrapper")
        #expect(value(after: "--wrapper-url", in: args) == "http://10.0.0.2:8080")
        #expect(!args.contains("--cookies-path"))
    }

    @Test("Region and DRM settings are passed once set")
    func region() {
        var p = base
        p.session.storefront = " FR "
        p.session.language = "fr-FR"
        p.session.drmBackend = .widevine
        p.session.devicePath = "~/device.wvd"
        let args = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: p)
        #expect(value(after: "--storefront", in: args) == "fr")
        #expect(value(after: "--language", in: args) == "fr-FR")
        #expect(value(after: "--drm-backend", in: args) == "widevine")
        #expect(value(after: "--device-path", in: args) == FileManager.default.homeDirectoryForCurrentUser.appending(path: "device.wvd").path)
    }

    @Test("gamdl 3 ignores the session and refuses wrapper mode")
    func gamdl3() {
        var p = base
        p.generation = .v3
        let plain = GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: p)
        p.session.storefront = "fr"
        #expect(GamdlCommand.arguments(for: album, options: DownloadOptions(), paths: p) == plain)
        var s = GamdlSession()
        s.authMode = .wrapper
        #expect(throws: GamdlCommandError.needsGamdl4(AuthMode.wrapper.label)) {
            try GamdlCommand.validate(DownloadOptions(), session: s, for: .v3)
        }
    }

    @Test("Validation: wrapper URL, PlayReady without device file")
    func validation() throws {
        var s = GamdlSession()
        s.authMode = .wrapper
        s.wrapperURL = "127.0.0.1:8080"
        #expect(throws: GamdlCommandError.invalidWrapperURL("127.0.0.1:8080")) { try GamdlCommand.validate(DownloadOptions(), session: s, for: .v4) }
        s.wrapperURL = "http://127.0.0.1:8080"
        try GamdlCommand.validate(DownloadOptions(), session: s, for: .v4)
        s.drmBackend = .playready
        #expect(throws: GamdlCommandError.playReadyNeedsDevice) { try GamdlCommand.validate(DownloadOptions(), session: s, for: .v4) }
        s.devicePath = "/u/device.prd"
        try GamdlCommand.validate(DownloadOptions(), session: s, for: .v4)
    }
}

@Suite("Diagnostics in wrapper mode")
struct WrapperDiagnosticsTests {
    private func report(cookies: CookieStatus, wrapper: WrapperStatus?, mode: AuthMode, version: String = "4.1.2") -> DiagnosticReport {
        var session = GamdlSession()
        session.authMode = mode
        return DiagnosticReport(
            gamdl: ToolCheck(name: "gamdl", path: URL(filePath: "/u/gamdl"), version: version),
            ffmpeg: ToolCheck(name: "ffmpeg", path: nil, version: nil),
            pipx: ToolCheck(name: "pipx", path: nil, version: nil),
            cookies: cookies, outputExists: true, outputWritable: true, freeSpace: nil, checkedAt: .now,
            session: session, wrapper: wrapper
        )
    }

    @Test("A ready wrapper is enough: no cookies needed")
    func readyWithoutCookies() {
        let r = report(cookies: .missing, wrapper: .ready(version: "1.2.0", architecture: "x86_64"), mode: .wrapper)
        #expect(r.isReady && r.problems.isEmpty)
    }

    @Test("A logged-out wrapper blocks, and says why")
    func loggedOut() {
        let r = report(cookies: .valid(appleCookies: 3, expiresAt: nil), wrapper: .loggedOut, mode: .wrapper)
        #expect(!r.isReady)
        #expect(r.problems == [WrapperStatus.loggedOut.title])
    }

    @Test("Cookies mode still needs usable cookies; gamdl 3 ignores the wrapper setting")
    func cookiesMode() {
        #expect(!report(cookies: .missing, wrapper: nil, mode: .cookies).isReady)
        let v3 = report(cookies: .valid(appleCookies: 3, expiresAt: nil), wrapper: nil, mode: .wrapper, version: "3.9.1")
        #expect(!v3.usesWrapper)
    }
}

@Suite("gamdl 4 session failures with a wrapper")
struct WrapperSessionMessageTests {
    /// Real gamdl 4.1.2 output, run against a fake wrapper answering
    /// `"state": "logged_out"`, then against a closed port.
    @Test("Logged-out wrapper and closed port get explained", arguments: [
        ("Apple ID: requires an interactive terminal", "Se connecter dans le Terminal"),
        ("Network request failed", "wrapper arrêté"),
    ])
    func session(message: String, expected: String) {
        var parser = Gamdl4OutputParser()
        let events = parser.feed("Gamdl 4.1.2\n\nErrors (1):\n  ✗ Session: \(message)\n")
        guard case .log(let line) = events.last else { Issue.record("\(events)"); return }
        #expect(line.level == .error)
        #expect(line.text.hasPrefix("Session Apple Music : "))
        #expect(line.text.contains(expected))
    }
}

/// Answers every request with an App Transport Security refusal, as macOS
/// does for plain http to a qualified host name.
private final class ATSRefusal: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.appTransportSecurityRequiresSecureConnection))
    }
    override func stopLoading() {}
}

@Suite("Wrapper over plain http (App Transport Security)")
struct WrapperATSTests {
    /// Measured: without it, http://<name>.local was refused while
    /// http://127.0.0.1 and the LAN IP worked.
    @Test("The app allows plain http on the local network, and only there")
    func localNetworkAllowed() throws {
        let ats = try #require(Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
    }

    @Test("A refused host name is reported as such, not as a wrapper that isn't running")
    func refusedHostName() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ATSRefusal.self]
        let status = await WrapperProbe.check("http://wrapper.example.com:8080", session: URLSession(configuration: config))
        guard case .unreachable(let reason) = status else { Issue.record("\(status)"); return }
        #expect(reason.contains("wrapper.example.com"))
        #expect(reason.contains(".local"))
    }
}

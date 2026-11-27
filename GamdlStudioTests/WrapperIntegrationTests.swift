import Foundation
import Testing
@testable import GamdlStudio

/// A fake wrapper-v2 served by Python's http.server on a free port, answering
/// `/info` and `/session` like the real one (README of glomatico/wrapper-v2).
private final class FakeWrapper {
    let port: Int
    private let process = Process()
    private let dir: URL

    static let python: URL? = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        .map { URL(filePath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    init(version: String = "1.2.0", state: String) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fake-wrapper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "wrapper.py")
        try """
        import json, socket, sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        INFO = {"version": "\(version)", "protocol_version": 1, "architecture": "x86_64",
                "profile": "apple-music-1109-x86_64", "context_supported": True,
                "context_format": "temari", "decryption": "client_side"}
        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                body = {"/info": INFO, "/session": {"state": "\(state)"}}.get(self.path)
                data = json.dumps(body or {"error": "not found"}).encode()
                self.send_response(200 if body else 404)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, *a): pass
        server = HTTPServer(("127.0.0.1", 0), H)
        with open(sys.argv[1], "w") as f: f.write(str(server.server_address[1]))
        server.serve_forever()
        """.write(to: script, atomically: true, encoding: .utf8)
        let portFile = dir.appending(path: "port")
        process.executableURL = try #require(Self.python)
        process.arguments = ["-I", script.path, portFile.path]
        process.environment = ["PYTHONDONTWRITEBYTECODE": "1"]
        try process.run()
        var found: Int?
        for _ in 0..<100 where found == nil {
            Thread.sleep(forTimeInterval: 0.05)
            found = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0) }
        }
        port = try #require(found)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    deinit {
        process.terminate()
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite("Wrapper probe against a live fake wrapper (integration)", .serialized)
struct WrapperProbeIntegrationTests {
    @Test("Signed-in wrapper: ready", .enabled(if: FakeWrapper.python != nil))
    func ready() async throws {
        let wrapper = try FakeWrapper(state: "authenticated")
        #expect(await WrapperProbe.check(wrapper.url) == .ready(version: "1.2.0", architecture: "x86_64"))
    }

    @Test("Logged-out wrapper: what makes gamdl ask for an Apple ID", .enabled(if: FakeWrapper.python != nil))
    func loggedOut() async throws {
        let wrapper = try FakeWrapper(state: "logged_out")
        #expect(await WrapperProbe.check(wrapper.url) == .loggedOut)
    }

    @Test("Old wrapper: the version gamdl would refuse", .enabled(if: FakeWrapper.python != nil))
    func oldVersion() async throws {
        let wrapper = try FakeWrapper(version: "0.9.0", state: "authenticated")
        guard case .incompatible(let reason) = await WrapperProbe.check(wrapper.url) else { Issue.record("expected incompatible"); return }
        #expect(reason.contains("0.9.0"))
    }
}

@Suite("Live download environment and the session (functional)")
struct LiveEnvironmentSessionTests {
    /// A fake gamdl 4: answers --version, nothing else is run here.
    private func fakeGamdl() throws -> (dir: URL, gamdl: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gamdl = dir.appending(path: "gamdl")
        try "#!/bin/sh\necho 'Gamdl, version 4.1.2'\n".write(to: gamdl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gamdl.path)
        return (dir, gamdl)
    }

    private func environment(_ dir: URL, gamdl: URL, session: GamdlSession) -> DownloadEnvironment {
        DownloadEnvironment.live(settings: SettingsSnapshot(
            output: dir.appending(path: "out"), cookies: dir.appending(path: "no-cookies.txt"),
            temp: dir.appending(path: "temp"), gamdlOverride: gamdl.path, session: session
        ))
    }

    @Test("Wrapper mode starts without a cookies file")
    func wrapperWithoutCookies() async throws {
        let (dir, gamdl) = try fakeGamdl()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = GamdlSession()
        session.authMode = .wrapper
        let paths = try await environment(dir, gamdl: gamdl, session: session).paths()
        #expect(paths.generation == .v4)
        #expect(paths.session.authMode == .wrapper)
    }

    @Test("Cookies mode still requires the cookies file")
    func cookiesRequired() async throws {
        let (dir, gamdl) = try fakeGamdl()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: DownloadQueueError.self) {
            _ = try await environment(dir, gamdl: gamdl, session: GamdlSession()).paths()
        }
    }

    @Test("A missing DRM device file stops before gamdl runs")
    func missingDevice() async throws {
        let (dir, gamdl) = try fakeGamdl()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = GamdlSession()
        session.authMode = .wrapper
        session.devicePath = dir.appending(path: "nope.wvd").path
        await #expect(throws: GamdlCommandError.deviceFileMissing(dir.appending(path: "nope.wvd").path)) {
            _ = try await environment(dir, gamdl: gamdl, session: session).paths()
        }
    }

    @Test("A personalized playlist in wrapper mode asks for the cookies file")
    func playlistNeedsCookies() async throws {
        let (dir, gamdl) = try fakeGamdl()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session = GamdlSession()
        session.authMode = .wrapper
        let env = environment(dir, gamdl: gamdl, session: session)
        let paths = try await env.paths()
        let link = try #require(AppleMusicLink(string: "https://music.apple.com/fr/playlist/replay/pl.pm-20e9f373919da080c4b396962bf55294"))
        await #expect(throws: GamdlCommandError.playlistNeedsCookies) { _ = try await env.resolvePlaylist(link, paths) }
    }
}

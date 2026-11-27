import Foundation

struct ToolCheck: Hashable, Sendable {
    let name: String
    let path: URL?
    let version: String?
    var isAvailable: Bool { path != nil }
}

struct DiagnosticReport: Hashable, Sendable {
    let gamdl: ToolCheck
    let ffmpeg: ToolCheck
    let pipx: ToolCheck
    let cookies: CookieStatus
    let outputExists: Bool
    let outputWritable: Bool
    let freeSpace: Int64?
    let checkedAt: Date
    /// How gamdl 4 signs in. With the wrapper, cookies are only needed for
    /// personalized playlists.
    var session = GamdlSession()
    /// Checked only in wrapper mode.
    var wrapper: WrapperStatus?

    /// Which command line the installed gamdl speaks, once it was found.
    var generation: GamdlGeneration? { gamdl.isAvailable ? GamdlGeneration(version: gamdl.version) : nil }

    /// gamdl 4 no longer uses ffmpeg.
    var needsFFmpeg: Bool { generation?.needsFFmpeg ?? true }

    var usesWrapper: Bool { session.authMode == .wrapper && generation != .v3 }

    /// Everything needed to start a download.
    var isReady: Bool {
        gamdl.isAvailable && (ffmpeg.isAvailable || !needsFFmpeg) && outputWritable
            && (usesWrapper ? wrapper?.isReady == true : cookies.isUsable)
    }

    var problems: [String] {
        var out: [String] = []
        if !gamdl.isAvailable { out.append(String(localized: "gamdl introuvable")) }
        if !ffmpeg.isAvailable && needsFFmpeg { out.append(String(localized: "ffmpeg introuvable")) }
        if usesWrapper {
            if let wrapper, !wrapper.isReady { out.append(wrapper.title) }
        } else if !cookies.isUsable {
            out.append(cookies.title)
        }
        if !outputWritable { out.append(String(localized: "Dossier de sortie non accessible en écriture")) }
        return out
    }
}

/// Environment checks (tools and their versions), returned as data.
enum Diagnostics {
    /// "gamdl, version 3.9.1" → "3.9.1"; "ffmpeg version 9.0.2 Copyright…" → "9.0.2".
    ///
    /// gamdl 4 prints a "Gamdl 4.1.2" banner on stderr before its version
    /// line, so every line is searched, not just the first.
    static func parseVersion(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { String($0).trimmed }
        let pattern = TextPatterns.regex(#"version\s+v?([0-9][0-9A-Za-z.\-+]*)"#, options: .caseInsensitive)
        for line in lines {
            if let v = pattern.captures(in: line)?[1] { return v }
        }
        let banner = TextPatterns.regex(#"^gamdl\s+v?([0-9][0-9A-Za-z.\-+]*)$"#, options: .caseInsensitive)
        for line in lines {
            if let v = banner.captures(in: line)?[1] { return v }
        }
        // pipx --version prints only the number.
        let bare = lines.first ?? ""
        return bare.range(of: #"^[0-9][0-9.]*$"#, options: .regularExpression) != nil ? bare : nil
    }

    static func check(tool name: String, override: String? = nil, locator: ToolLocator) async -> ToolCheck {
        guard let path = locator.locate(name, override: override) else { return ToolCheck(name: name, path: nil, version: nil) }
        let flag = name == "ffmpeg" ? "-version" : "--version"
        let output = await ProcessRunner.capture(path, [flag], environment: locator.environment())
        return ToolCheck(name: name, path: path, version: output.flatMap { parseVersion($0.output) })
    }

    static func run(settings snapshot: SettingsSnapshot, locator: ToolLocator = .standard) async -> DiagnosticReport {
        async let gamdl = check(tool: "gamdl", override: snapshot.gamdlOverride, locator: locator)
        async let ffmpeg = check(tool: "ffmpeg", locator: locator)
        async let pipx = check(tool: "pipx", locator: locator)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: snapshot.output.path, isDirectory: &isDir) && isDir.boolValue
        let writable = exists ? fm.isWritableFile(atPath: snapshot.output.path) : fm.isWritableFile(atPath: snapshot.output.deletingLastPathComponent().path)
        let free = (try? snapshot.output.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage

        let wrapper = snapshot.session.authMode == .wrapper ? await WrapperProbe.check(snapshot.session.wrapperURL) : nil

        return await DiagnosticReport(
            gamdl: gamdl,
            ffmpeg: ffmpeg,
            pipx: pipx,
            cookies: CookieInspector.status(ofFileAt: snapshot.cookies),
            outputExists: exists,
            outputWritable: writable,
            freeSpace: free,
            checkedAt: .now,
            session: snapshot.session,
            wrapper: wrapper
        )
    }
}

/// Copy of the settings that can be used off the main thread.
struct SettingsSnapshot: Sendable, Hashable {
    let output: URL
    let cookies: URL
    let temp: URL
    let gamdlOverride: String
    let session: GamdlSession

    @MainActor init(_ settings: AppSettings) {
        output = settings.outputURL
        cookies = settings.cookiesURL
        temp = settings.tempURL
        gamdlOverride = settings.gamdlOverride
        session = settings.session
    }

    init(output: URL, cookies: URL, temp: URL, gamdlOverride: String = "", session: GamdlSession = GamdlSession()) {
        self.output = output
        self.cookies = cookies
        self.temp = temp
        self.gamdlOverride = gamdlOverride
        self.session = session
    }
}

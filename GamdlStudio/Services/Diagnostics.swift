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

    /// Everything needed to start a download.
    var isReady: Bool { gamdl.isAvailable && ffmpeg.isAvailable && cookies.isUsable && outputWritable }

    var problems: [String] {
        var out: [String] = []
        if !gamdl.isAvailable { out.append("gamdl introuvable") }
        if !ffmpeg.isAvailable { out.append("ffmpeg introuvable") }
        if !cookies.isUsable { out.append(cookies.title) }
        if !outputWritable { out.append("Dossier de sortie non accessible en écriture") }
        return out
    }
}

/// Environment checks (tools and their versions), returned as data.
enum Diagnostics {
    /// "gamdl, version 3.9.1" → "3.9.1"; "ffmpeg version 9.0.2 Copyright…" → "9.0.2".
    static func parseVersion(_ output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let pattern = TextPatterns.regex(#"version\s+v?([0-9][0-9A-Za-z.\-+]*)"#, options: .caseInsensitive)
        if let v = pattern.captures(in: firstLine)?[1] { return v }
        // pipx --version prints only the number.
        let bare = firstLine.trimmed
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

        return await DiagnosticReport(
            gamdl: gamdl,
            ffmpeg: ffmpeg,
            pipx: pipx,
            cookies: CookieInspector.status(ofFileAt: snapshot.cookies),
            outputExists: exists,
            outputWritable: writable,
            freeSpace: free,
            checkedAt: .now
        )
    }
}

/// Copy of the settings that can be used off the main thread.
struct SettingsSnapshot: Sendable, Hashable {
    let output: URL
    let cookies: URL
    let temp: URL
    let gamdlOverride: String

    @MainActor init(_ settings: AppSettings) {
        output = settings.outputURL
        cookies = settings.cookiesURL
        temp = settings.tempURL
        gamdlOverride = settings.gamdlOverride
    }

    init(output: URL, cookies: URL, temp: URL, gamdlOverride: String = "") {
        self.output = output
        self.cookies = cookies
        self.temp = temp
        self.gamdlOverride = gamdlOverride
    }
}

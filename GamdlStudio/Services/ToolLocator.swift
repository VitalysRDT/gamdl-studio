import Foundation

/// Locates the executables the app needs.
///
/// An app launched from Finder does not inherit the shell's PATH: neither
/// `~/.local/bin` (pipx) nor `/opt/homebrew/bin` is on it, so the usual
/// locations are searched explicitly.
struct ToolLocator: Sendable {
    let searchDirectories: [URL]

    static let standard = ToolLocator(searchDirectories: {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: ".local/bin"),
            URL(filePath: "/opt/homebrew/bin"),
            URL(filePath: "/usr/local/bin"),
            URL(filePath: "/usr/bin"),
            URL(filePath: "/bin"),
        ]
    }())

    /// PATH passed to child processes (gamdl itself invokes ffmpeg).
    var pathVariable: String { searchDirectories.map(\.path).joined(separator: ":") }

    func locate(_ name: String, override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override, !override.trimmed.isEmpty {
            let url = URL(filePath: (override.trimmed as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        return searchDirectories
            .map { $0.appending(path: name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Environment shared by every process the app launches.
    func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = pathVariable
        env["PYTHONUNBUFFERED"] = "1"     // otherwise progress arrives in 4 KB chunks
        env["PYTHONIOENCODING"] = "utf-8"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["COLUMNS"] = "240"            // keeps Rich from wrapping log lines
        env["LANG"] = env["LANG"] ?? "fr_FR.UTF-8"
        env.merge(extra) { _, new in new }
        return env
    }
}

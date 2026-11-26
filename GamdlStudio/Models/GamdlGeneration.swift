import Foundation

/// The two gamdl command lines the app knows how to drive.
///
/// gamdl 4 replaced 3.x's single command with subcommands (`gamdl rip …`),
/// renamed or dropped most options, stopped using ffmpeg and reports progress
/// differently. Everything that depends on it branches on this value.
enum GamdlGeneration: String, Hashable, Sendable {
    case v3, v4

    /// From `gamdl --version` ("3.9.1", "4.1.2"). An unreadable version is
    /// taken as the current major, which is what a new install gets.
    init(version: String?) {
        let major = version?.split(separator: ".").first.flatMap { Int($0) }
        self = (major ?? 4) >= 4 ? .v4 : .v3
    }

    /// gamdl 3 remuxes with ffmpeg; gamdl 4 does it natively.
    var needsFFmpeg: Bool { self == .v3 }

    /// gamdl 4 has no "lyrics only" mode.
    var supportsLyricsOnly: Bool { self == .v3 }
}

/// Remembers `gamdl --version` per executable, so each download doesn't pay
/// for a Python start-up. Keyed by the resolved file and its modification
/// date: `pipx upgrade` rewrites the launcher, which invalidates the entry.
final class GamdlVersionCache: @unchecked Sendable {
    static let shared = GamdlVersionCache()

    private struct Entry {
        let stamp: Date?
        let version: String?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func version(of gamdl: URL, environment: [String: String]) async -> String? {
        let key = gamdl.resolvingSymlinksInPath().path
        let stamp = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        if let hit = lock.withLock({ entries[key] }), hit.stamp == stamp { return hit.version }
        let output = await ProcessRunner.capture(gamdl, ["--version"], environment: environment)
        let version = output.flatMap { Diagnostics.parseVersion($0.output) }
        lock.withLock { entries[key] = Entry(stamp: stamp, version: version) }
        return version
    }
}

import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    nonisolated static var defaultOutput: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/Gamdl Studio")
    }

    nonisolated static var defaultCookies: URL {
        applicationSupport.appending(path: "cookies.txt")
    }

    nonisolated static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Gamdl Studio")
    }

    nonisolated static var defaultTemp: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Gamdl Studio/temp")
    }

    var outputPath: String { didSet { defaults.set(outputPath, forKey: Keys.output) } }
    var cookiesPath: String { didSet { defaults.set(cookiesPath, forKey: Keys.cookies) } }
    var tempPath: String { didSet { defaults.set(tempPath, forKey: Keys.temp) } }
    var gamdlOverride: String { didSet { defaults.set(gamdlOverride, forKey: Keys.gamdl) } }
    var maxConcurrentJobs: Int { didSet { defaults.set(maxConcurrentJobs, forKey: Keys.concurrency) } }
    var notifyOnCompletion: Bool { didSet { defaults.set(notifyOnCompletion, forKey: Keys.notify) } }
    var playSoundOnCompletion: Bool { didSet { defaults.set(playSoundOnCompletion, forKey: Keys.sound) } }
    var watchClipboard: Bool { didSet { defaults.set(watchClipboard, forKey: Keys.clipboard) } }
    /// Warn before a Dolby Atmos or spatial download without the wrapper.
    var warnSpatialWithoutWrapper: Bool { didSet { defaults.set(warnSpatialWithoutWrapper, forKey: Keys.warnSpatial) } }
    var options: DownloadOptions {
        didSet { defaults.set(try? JSONEncoder().encode(options), forKey: Keys.options) }
    }
    /// How gamdl 4 signs in (cookies or wrapper), plus storefront, language and DRM.
    var session: GamdlSession {
        didSet { defaults.set(try? JSONEncoder().encode(session), forKey: Keys.session) }
    }

    var outputURL: URL { URL(filePath: (outputPath as NSString).expandingTildeInPath) }
    var cookiesURL: URL { URL(filePath: (cookiesPath as NSString).expandingTildeInPath) }
    var tempURL: URL { URL(filePath: (tempPath as NSString).expandingTildeInPath) }

    private enum Keys {
        static let output = "outputPath", cookies = "cookiesPath", temp = "tempPath", gamdl = "gamdlOverride"
        static let concurrency = "maxConcurrentJobs", notify = "notifyOnCompletion", sound = "playSound"
        static let clipboard = "watchClipboard", options = "downloadOptions", session = "gamdlSession"
        static let warnSpatial = "warnSpatialWithoutWrapper"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputPath = defaults.string(forKey: Keys.output) ?? Self.defaultOutput.path
        cookiesPath = defaults.string(forKey: Keys.cookies) ?? Self.defaultCookies.path
        tempPath = defaults.string(forKey: Keys.temp) ?? Self.defaultTemp.path
        gamdlOverride = defaults.string(forKey: Keys.gamdl) ?? ""
        let concurrency = defaults.integer(forKey: Keys.concurrency)
        maxConcurrentJobs = (1...3).contains(concurrency) ? concurrency : 1
        notifyOnCompletion = defaults.object(forKey: Keys.notify) as? Bool ?? true
        playSoundOnCompletion = defaults.object(forKey: Keys.sound) as? Bool ?? true
        watchClipboard = defaults.object(forKey: Keys.clipboard) as? Bool ?? true
        warnSpatialWithoutWrapper = defaults.object(forKey: Keys.warnSpatial) as? Bool ?? true
        options = defaults.data(forKey: Keys.options).flatMap { try? JSONDecoder().decode(DownloadOptions.self, from: $0) } ?? DownloadOptions()
        session = defaults.data(forKey: Keys.session).flatMap { try? JSONDecoder().decode(GamdlSession.self, from: $0) } ?? GamdlSession()
    }

    func resetPaths() {
        outputPath = Self.defaultOutput.path
        cookiesPath = Self.defaultCookies.path
        tempPath = Self.defaultTemp.path
        gamdlOverride = ""
    }
}

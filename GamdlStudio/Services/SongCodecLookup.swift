import Foundation

/// Inputs for one availability check. A changed link or session invalidates its result.
struct SongCodecLookup: Hashable, Sendable {
    let link: AppleMusicLink
    let storefront: String
    let mode: String
    let source: String
    let gamdlOverride: String

    init?(link: AppleMusicLink?, settings: SettingsSnapshot, wrapperReady: Bool) {
        guard let link, [.song, .album, .playlist].contains(link.kind) else { return nil }
        self.link = link
        storefront = settings.session.storefront.trimmed.isEmpty ? (link.storefront ?? "") : settings.session.storefront.trimmed.lowercased()
        gamdlOverride = settings.gamdlOverride
        switch settings.session.authMode {
        case .wrapper where link.needsResolution:
            // These playlists are read with the subscriber's cookies by PlaylistResolver.
            mode = "cookies"
            source = settings.cookies.path
        case .wrapper:
            mode = wrapperReady ? "wrapper" : "public"
            source = settings.session.wrapperURL.trimmed
        case .cookies:
            mode = "cookies"
            source = settings.cookies.path
        }
    }

    func fetch() async -> [SongCodec]? {
        let locator = ToolLocator.standard
        guard let gamdl = locator.locate("gamdl", override: gamdlOverride),
              let python = PlaylistResolver.python(forGamdl: gamdl), python.lastPathComponent.hasPrefix("python"),
              let script = Bundle.main.url(forResource: "available_codecs", withExtension: "py") else { return nil }
        let output = OutputCollector()
        let arguments = ["-I", script.path, link.kind.rawValue, link.id, link.isLibrary ? "library" : "catalog", storefront, mode, source]
        let result = try? await ProcessRunner().run(executable: python, arguments: arguments,
            environment: locator.environment(), separateErrorOutput: { _ in }, onOutput: { output.append($0) })
        guard result?.succeeded == true,
              let names = try? JSONDecoder().decode([String].self, from: Data(output.value.utf8)) else { return nil }
        return SongCodec.allCases.filter { names.contains($0.rawValue) }
    }
}

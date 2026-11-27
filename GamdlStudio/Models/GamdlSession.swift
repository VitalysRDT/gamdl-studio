import Foundation

/// How gamdl 4 signs in to Apple Music.
enum AuthMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The browser cookies file (media-user-token). AAC and Atmos.
    case cookies
    /// gamdl's wrapper-v2 service, needed for ALAC.
    case wrapper

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cookies: String(localized: "Fichier de cookies")
        case .wrapper: String(localized: "Wrapper (pour l'ALAC)")
        }
    }
}

enum DrmBackend: String, CaseIterable, Codable, Sendable, Identifiable {
    case widevine, playready
    var id: String { rawValue }
    var label: String { self == .widevine ? "Widevine" : "PlayReady" }
}

/// Session settings for gamdl 4 (`--auth-mode`, `--wrapper-url`,
/// `--storefront`, `--language`, `--drm-backend`, `--device-path`).
/// Empty text and `nil` mean "leave it to gamdl".
struct GamdlSession: Codable, Hashable, Sendable {
    var authMode: AuthMode = .cookies
    var wrapperURL = Self.defaultWrapperURL
    var storefront = ""
    var language = ""
    var drmBackend: DrmBackend?
    var devicePath = ""

    static let defaultWrapperURL = "http://127.0.0.1:8080"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        authMode = value(.authMode, AuthMode.self) ?? .cookies
        wrapperURL = value(.wrapperURL, String.self) ?? Self.defaultWrapperURL
        storefront = value(.storefront, String.self) ?? ""
        language = value(.language, String.self) ?? ""
        drmBackend = value(.drmBackend, DrmBackend.self)
        devicePath = value(.devicePath, String.self) ?? ""
    }

    var expandedDevicePath: String? {
        let path = devicePath.trimmed
        return path.isEmpty ? nil : (path as NSString).expandingTildeInPath
    }
}

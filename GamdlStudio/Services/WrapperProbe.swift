import Foundation

/// State of gamdl's wrapper-v2 service, as gamdl 4.1.2 would judge it.
enum WrapperStatus: Hashable, Sendable {
    /// Nothing answered at the URL.
    case unreachable(String)
    /// It answered, but gamdl would refuse it (version, protocol, profile…).
    case incompatible(String)
    /// Compatible, but no Apple Account session: gamdl would ask for an Apple
    /// ID, which needs a terminal.
    case loggedOut
    case ready(version: String, architecture: String)

    var isReady: Bool { if case .ready = self { true } else { false } }

    var title: String {
        switch self {
        case .unreachable: String(localized: "Wrapper injoignable")
        case .incompatible: String(localized: "Wrapper incompatible avec gamdl")
        case .loggedOut: String(localized: "Wrapper non connecté")
        case .ready: String(localized: "Wrapper prêt")
        }
    }

    var message: String {
        switch self {
        case .unreachable(let reason): reason
        case .incompatible(let reason): reason
        case .loggedOut: String(localized: "Connecte-le à ton compte Apple avec « gamdl auth » dans le Terminal.")
        case let .ready(version, architecture): "wrapper-v2 \(version) · \(architecture)"
        }
    }
}

/// Reads `GET /info` and `GET /session` from a wrapper-v2, with a short
/// timeout. The checks mirror `gamdl.api.wrapper.WrapperApi.validate_info`
/// (gamdl 4.1.2), so the app reports the precise reason gamdl itself hides
/// behind "Unexpected Apple Music or wrapper API response".
enum WrapperProbe {
    static let profiles = ["x86_64": "apple-music-1109-x86_64", "arm64-v8a": "apple-music-1109-arm64-v8a"]

    /// The reason gamdl would refuse this `/info`, or `nil` if it would accept it.
    static func incompatibility(info: [String: Any]) -> String? {
        let version = info["version"] as? String ?? ""
        if version.range(of: #"^1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) == nil {
            return String(localized: "gamdl 4 demande wrapper-v2 1.x (version annoncée : \(version.isEmpty ? "?" : version)).")
        }
        if (info["protocol_version"] as? Int) != 1 {
            return String(localized: "Protocole du wrapper non pris en charge par gamdl.")
        }
        guard let arch = info["architecture"] as? String, let profile = profiles[arch] else {
            return String(localized: "Architecture du wrapper non prise en charge (x86_64 ou arm64-v8a attendue).")
        }
        if (info["profile"] as? String) != profile {
            return String(localized: "Profil Temari inattendu pour \(arch).")
        }
        if (info["context_supported"] as? Bool) != true || (info["context_format"] as? String) != "temari"
            || (info["decryption"] as? String) != "client_side" {
            return String(localized: "Ce wrapper ne fournit pas les contextes Temari dont gamdl a besoin.")
        }
        return nil
    }

    static func status(info infoData: Data, session sessionData: Data) -> WrapperStatus {
        guard let info = (try? JSONSerialization.jsonObject(with: infoData)) as? [String: Any] else {
            return .incompatible(String(localized: "Réponse illisible du wrapper."))
        }
        if let reason = incompatibility(info: info) { return .incompatible(reason) }
        let session = (try? JSONSerialization.jsonObject(with: sessionData)) as? [String: Any]
        guard (session?["state"] as? String) == "authenticated" else { return .loggedOut }
        return .ready(version: info["version"] as? String ?? "", architecture: info["architecture"] as? String ?? "")
    }

    /// `http(s)://host[:port]`, nothing else: gamdl appends the API paths.
    static func baseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    static func check(_ urlText: String, session: URLSession = .shared, timeout: TimeInterval = 3) async -> WrapperStatus {
        guard let base = baseURL(urlText) else {
            return .unreachable(String(localized: "Adresse du wrapper invalide : \(urlText)"))
        }
        func get(_ path: String) async throws -> Data {
            var request = URLRequest(url: base.appending(path: path))
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        do {
            let info = try await get("info")
            let state = (try? await get("session")) ?? Data()
            return status(info: info, session: state)
        } catch {
            return .unreachable(String(localized: "Rien ne répond à \(base.absoluteString). Le wrapper tourne-t-il ?"))
        }
    }
}

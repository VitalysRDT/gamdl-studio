import Foundation
import Observation

/// Which Android ABI the wrapper-v2 image is built for (`build-docker.sh --arch`).
enum WrapperArchitecture: String, CaseIterable, Codable, Sendable, Identifiable {
    case x86_64
    case arm64 = "arm64-v8a"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .x86_64: "x86_64"
        case .arm64: "ARM64 (arm64-v8a)"
        }
    }

    /// What wrapper-v2 1.0.1 says about it (README, "Validation status").
    var note: String {
        switch self {
        case .x86_64: String(localized: "Le seul chemin validé de bout en bout par wrapper-v2. Sur une puce Apple, Docker l'émule : construction et démarrage plus lents.")
        case .arm64: String(localized: "Natif sur une puce Apple, mais wrapper-v2 ne l'a pas encore validé avec une vraie connexion Apple.")
        }
    }

    /// The ABI of an image, from `docker image inspect --format {{.Architecture}}`.
    init?(dockerArchitecture: String) {
        switch dockerArchitecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "amd64", "x86_64": self = .x86_64
        case "arm64", "aarch64", "arm64-v8a": self = .arm64
        default: return nil
        }
    }

    /// The ABI matching the host CPU (`uname -m`).
    static func native(machine: String) -> WrapperArchitecture {
        ["arm64", "aarch64", "arm64e"].contains(machine.lowercased()) ? .arm64 : .x86_64
    }

    static var hostMachine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The steps of the wrapper installation, in order.
enum WrapperSetupStep: Int, CaseIterable, Identifiable, Sendable {
    case docker, source, package, build, start, signIn, activate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .docker: String(localized: "Docker")
        case .source: String(localized: "Code de wrapper-v2")
        case .package: String(localized: "Paquet Apple Music")
        case .build: String(localized: "Image Docker")
        case .start: String(localized: "Démarrage")
        case .activate: String(localized: "Activation dans Gamdl Studio")
        case .signIn: String(localized: "Connexion au compte Apple")
        }
    }

    var symbol: String {
        switch self {
        case .docker: "shippingbox.fill"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .package: "doc.zipper"
        case .build: "hammer.fill"
        case .start: "play.circle.fill"
        case .activate: "switch.2"
        case .signIn: "person.badge.key.fill"
        }
    }

    var actionTitle: String {
        switch self {
        case .docker: String(localized: "Préparer Docker")
        case .source: String(localized: "Télécharger le code")
        case .package: String(localized: "Choisir le paquet…")
        case .build: String(localized: "Construire")
        case .start: String(localized: "Démarrer")
        case .activate: String(localized: "Activer le wrapper")
        case .signIn: String(localized: "Se connecter dans le Terminal")
        }
    }
}

enum WrapperStepState: Hashable, Sendable {
    case unknown
    case done(String)
    case todo(String)
    case failed(String)

    var isDone: Bool { if case .done = self { true } else { false } }

    var message: String {
        switch self {
        case .unknown: ""
        case .done(let m), .todo(let m), .failed(let m): m
        }
    }
}

/// What `docker`, its plugins and Colima answered.
/// The settings of Colima's default VM, read from `~/.colima/default/colima.yaml`.
struct ColimaSettings: Hashable, Sendable {
    var vmType: String?
    var rosetta: Bool?
    var cpu: Int?
    var memory: Int?

    /// Reads the top-level keys only (`rosetta: true`, `cpu: 2`…).
    static func parse(_ yaml: String) -> ColimaSettings {
        var s = ColimaSettings()
        for raw in yaml.components(separatedBy: .newlines) {
            guard let first = raw.first, first != " ", first != "#", first != "\t",
                  let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "vmType": s.vmType = value.isEmpty ? nil : value
            case "rosetta": s.rosetta = value == "true" ? true : value == "false" ? false : nil
            case "cpu": s.cpu = Int(value)
            case "memory": s.memory = Int(value)
            default: break
            }
        }
        return s
    }
}

struct DockerProbe: Hashable, Sendable {
    var docker: URL?
    var compose = false
    var buildx = false
    var daemon = false
    var colima: URL?
    var brew: URL?
    /// `docker context show`: "colima" when Colima is the engine in use.
    var context: String?
    /// Colima's VM settings, when it has one.
    var colimaSettings: ColimaSettings?

    var usesColima: Bool { context?.hasPrefix("colima") == true }

    /// Homebrew formulae still to install for the wrapper to build and run.
    var missingFormulae: [String] {
        var out: [String] = []
        if docker == nil {
            // Without any Docker engine, Colima is the lightest one to add.
            if colima == nil { out.append("colima") }
            out.append("docker")
        }
        if !compose { out.append("docker-compose") }
        if !buildx { out.append("docker-buildx") }
        return out
    }
}

/// Everything the step states are computed from.
struct WrapperSetupSnapshot: Hashable, Sendable {
    var docker = DockerProbe()
    var sourceReady = false
    var sourcePath = ""
    var package: URL?
    var imageBuilt = false
    /// The ABI the existing image was built for, when Docker said.
    var imageArchitecture: WrapperArchitecture?
    /// The running Compose service uses the image currently tagged wrapper-v2:local.
    var containerUsesBuiltImage = false
    /// The ABI chosen in the assistant.
    var architecture: WrapperArchitecture = .x86_64
    var hostMachine = "x86_64"
    var status: WrapperStatus = .unreachable("")
    var session = GamdlSession()
}

/// Commands and rules of the installation, kept pure so they can be tested.
enum WrapperRecipe {
    static let repository = "https://github.com/glomatico/wrapper-v2.git"
    /// The release gamdl 4.1.2 was measured against.
    static let release = "1.0.1"
    /// `build-docker.sh` always adds this tag, and `compose.yaml` runs it.
    static let image = "wrapper-v2:local"
    static let healthURL = GamdlSession.defaultWrapperURL

    static func cloneArguments(into directory: URL) -> [String] {
        ["clone", "--depth", "1", "--branch", release, repository, directory.path]
    }

    static func buildArguments(package: URL, architecture: WrapperArchitecture) -> [String] {
        ["tools/build-docker.sh", package.path, "--arch", architecture.rawValue]
    }

    static let composeUpArguments = ["compose", "up", "-d"]
    static let imageInspectArguments = ["image", "inspect", "--format", "{{.Architecture}} {{.Id}}", image]

    /// Resources the wrapper's Android runtime needs to answer in time.
    static let minimumCPU = 4, minimumMemoryGiB = 4

    /// `colima start`. For an x86_64 image on Apple silicon, the VM runs on
    /// the macOS virtualization framework with Rosetta: without it, Docker
    /// falls back to QEMU emulation and the wrapper's worker times out
    /// (`worker_timeout`, seen on a 2-CPU VM on 2026-11-27). Rosetta can be
    /// turned on for an existing `vz` VM at start; a QEMU VM can't switch.
    static func colimaStartArguments(hostMachine: String, architecture: WrapperArchitecture, settings: ColimaSettings?) -> [String] {
        guard WrapperArchitecture.native(machine: hostMachine) == .arm64, architecture == .x86_64 else { return ["start"] }
        if let vmType = settings?.vmType, vmType != "vz" { return ["start"] }
        return ["start", "--vm-type", "vz", "--vz-rosetta",
                "--cpu", String(max(settings?.cpu ?? 0, minimumCPU)),
                "--memory", String(max(settings?.memory ?? 0, minimumMemoryGiB))]
    }

    /// Colima is the engine, the image is x86_64 on Apple silicon, and the VM
    /// runs without Rosetta.
    static func colimaNeedsRosetta(_ s: WrapperSetupSnapshot) -> Bool {
        WrapperArchitecture.native(machine: s.hostMachine) == .arm64 && s.architecture == .x86_64
            && s.docker.usesColima && s.docker.colimaSettings?.rosetta != true
    }

    /// The command pasted in Terminal when tools are missing. The compose and
    /// buildx plugins from Homebrew are only found by `docker` once
    /// `cliPluginsExtraDirs` points at them (Homebrew's own caveat).
    static func brewInstallScript(formulae: [String], brew: String) -> String {
        let plugins = #"""
        mkdir -p ~/.docker
        if [ ! -f ~/.docker/config.json ]; then echo '{}' > ~/.docker/config.json; fi
        /usr/bin/python3 -I - <<'EOF'
        import json, os
        path = os.path.expanduser("~/.docker/config.json")
        with open(path) as f: config = json.load(f)
        dirs = config.setdefault("cliPluginsExtraDirs", [])
        for d in ("/opt/homebrew/lib/docker/cli-plugins", "/usr/local/lib/docker/cli-plugins"):
            if d not in dirs: dirs.append(d)
        with open(path, "w") as f: json.dump(config, f, indent=2)
        EOF
        """#
        return """
        \(GamdlCommand.shellQuote(brew)) install \(formulae.joined(separator: " "))
        \(plugins)
        """
    }

    static func isPackage(_ url: URL) -> Bool {
        ["apk", "apkm"].contains(url.pathExtension.lowercased())
    }

    /// The two files the installation runs.
    static func sourceIsComplete(at root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appending(path: "compose.yaml").path)
            && fm.fileExists(atPath: root.appending(path: "tools/build-docker.sh").path)
    }

    static func isActivated(_ session: GamdlSession) -> Bool {
        session.authMode == .wrapper
            && WrapperProbe.baseURL(session.wrapperURL).map(normalized) == WrapperProbe.baseURL(healthURL).map(normalized)
    }

    private static func normalized(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
    }

    static func evaluate(_ s: WrapperSetupSnapshot) -> [WrapperSetupStep: WrapperStepState] {
        var out: [WrapperSetupStep: WrapperStepState] = [:]

        let missing = s.docker.missingFormulae
        if !missing.isEmpty {
            out[.docker] = .todo(String(localized: "À installer avec Homebrew : \(missing.joined(separator: ", ")).")
                + (s.docker.brew == nil ? " " + String(localized: "Installe d'abord Homebrew (brew.sh).") : ""))
        } else if !s.docker.daemon {
            out[.docker] = .todo(s.docker.colima != nil
                ? String(localized: "Le moteur Docker est arrêté : l'assistant peut démarrer Colima.")
                : String(localized: "Le moteur Docker ne répond pas : lance Docker Desktop, OrbStack ou Colima."))
        } else if colimaNeedsRosetta(s) {
            out[.docker] = .todo(s.docker.colimaSettings?.vmType.map { $0 != "vz" } == true
                ? String(localized: "Colima tourne sans Rosetta, sur une VM QEMU qui ne peut pas l'activer : l'image x86_64 y est émulée trop lentement et le moteur du wrapper expire. Recrée la VM (colima delete), puis relance l'assistant ; l'image sera à reconstruire.")
                : String(localized: "Colima tourne sans Rosetta : l'image x86_64 y est émulée trop lentement et le moteur du wrapper expire. L'assistant peut redémarrer Colima avec Rosetta (\(WrapperRecipe.minimumCPU) cœurs, \(WrapperRecipe.minimumMemoryGiB) Go)."))
        } else {
            out[.docker] = .done(String(localized: "Moteur Docker, Compose et Buildx prêts."))
        }

        out[.source] = s.sourceReady
            ? .done(s.sourcePath)
            : .todo(String(localized: "wrapper-v2 \(release) sera cloné depuis GitHub."))

        let mismatch = s.imageBuilt && s.imageArchitecture != nil && s.imageArchitecture != s.architecture
        let imageReady = s.imageBuilt && !mismatch
        if let package = s.package {
            out[.package] = .done(package.lastPathComponent)
        } else if imageReady {
            out[.package] = .done(String(localized: "L'image est déjà construite : le paquet n'est plus nécessaire."))
        } else {
            out[.package] = .todo(String(localized: "Choisis ton paquet Apple Music 3.6.0-beta, build 1109 (.apk ou .apkm). Gamdl Studio ne le télécharge pas."))
        }

        if mismatch, let built = s.imageArchitecture {
            out[.build] = .todo(String(localized: "L'image existante est construite pour \(built.rawValue), pas pour \(s.architecture.rawValue) : reconstruis-la avec ton paquet."))
        } else if s.imageBuilt {
            out[.build] = .done(String(localized: "Image \(image) présente (\(s.imageArchitecture?.rawValue ?? "?"))."))
        } else {
            out[.build] = .todo(String(localized: "Construit l'image privée avec ton paquet (plusieurs minutes la première fois)."))
        }

        switch s.status {
        case .unreachable:
            out[.start] = .todo(String(localized: "Rien ne répond encore sur \(healthURL)."))
        case .ready(_, let runningABI) where s.sourceReady && s.imageArchitecture != nil && s.imageArchitecture?.rawValue != runningABI:
            out[.start] = .todo(String(localized: "Le wrapper sur \(healthURL) annonce \(runningABI). Démarre le conteneur de l’image vérifiée et vérifie le port utilisé."))
        case _ where s.sourceReady && s.imageBuilt && !s.containerUsesBuiltImage:
            out[.start] = .todo(String(localized: "Démarre le service Compose avec l’image Docker qui vient d’être vérifiée."))
        default:
            out[.start] = .done(String(localized: "Le wrapper répond sur \(healthURL)."))
        }

        out[.activate] = isActivated(s.session)
            ? .done(String(localized: "gamdl passe par le wrapper."))
            : .todo(String(localized: "Gamdl Studio utilise encore le fichier de cookies : l'ALAC échouera tant que le wrapper n'est pas activé. Active-le une fois le wrapper connecté : en mode wrapper, tout passe par lui, l'AAC compris."))

        switch s.status {
        case .ready:
            out[.signIn] = .done(s.status.message)
        case .loggedOut:
            out[.signIn] = .todo(String(localized: "Connecte le wrapper à ton compte Apple avec « gamdl auth ». Gamdl Studio ne voit jamais ton identifiant."))
        case .incompatible(let reason):
            out[.signIn] = .failed(reason)
        case .unreachable:
            out[.signIn] = .todo(String(localized: "Démarre d'abord le wrapper."))
        }
        return out
    }
}

/// How the assistant reaches the outside world, swappable in tests.
struct WrapperSetupEnvironment: Sendable {
    var tools: ToolLocator
    /// Where wrapper-v2 is cloned.
    var root: URL
    var hostMachine: String
    /// Colima's state folder: its absence means `colima start` creates the VM.
    var colimaHome: URL
    var probe: @Sendable (String) async -> WrapperStatus
    /// How long `docker compose up` may take to answer on `/info`.
    var startTimeout: Duration = .seconds(90)
    var pollInterval: Duration = .seconds(2)
    var openTerminal: @Sendable (_ script: String, _ name: String) throws -> Void

    static func live() -> WrapperSetupEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return WrapperSetupEnvironment(
            tools: .standard,
            root: AppSettings.applicationSupport.appending(path: "wrapper-v2"),
            hostMachine: WrapperArchitecture.hostMachine,
            colimaHome: home.appending(path: ".colima"),
            probe: { await WrapperProbe.check($0) },
            openTerminal: { script, name in _ = try TerminalLauncher.open(script: script, name: name) }
        )
    }

    /// The build script needs `sha256sum` (/sbin) and `realpath`.
    var processEnvironment: [String: String] {
        var env = tools.environment()
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/sbin:/sbin"
        env["COLUMNS"] = "120"
        env["BUILDKIT_PROGRESS"] = "plain"
        return env
    }
}

/// Installs gamdl's wrapper-v2 step by step: Docker, the source, the user's
/// own Apple Music package, the image, the service, the app setting and the
/// Apple Account sign-in.
@MainActor
@Observable
final class WrapperSetup {
    private(set) var states: [WrapperSetupStep: WrapperStepState] = [:]
    private(set) var snapshot = WrapperSetupSnapshot()
    private(set) var running: WrapperSetupStep?
    private(set) var isRefreshing = false
    private(set) var log = ""
    private var selectedArchitecture: WrapperArchitecture?
    var architecture: WrapperArchitecture {
        get { selectedArchitecture ?? snapshot.architecture }
        set {
            selectedArchitecture = newValue
            snapshot.architecture = newValue
            states = Self.merge(WrapperRecipe.evaluate(snapshot), keeping: states)
        }
    }
    private(set) var package: URL?
    /// Progress of the running `build-docker.sh`, read from BuildKit's output.
    private(set) var buildProgress: BuildKitProgress?
    private(set) var buildStartedAt: Date?

    let environment: WrapperSetupEnvironment
    private var runner: ProcessRunner?
    private static let maxLog = 200_000

    init(environment: WrapperSetupEnvironment = .live()) {
        self.environment = environment
    }

    var isBusy: Bool { running != nil }
    var isComplete: Bool { WrapperSetupStep.allCases.allSatisfy { states[$0]?.isDone == true } }
    func state(_ step: WrapperSetupStep) -> WrapperStepState { states[step] ?? .unknown }

    /// The first step not done yet: the one the assistant highlights.
    var nextStep: WrapperSetupStep? { WrapperSetupStep.allCases.first { !state($0).isDone } }

    // MARK: - Checks

    func refresh(session: GamdlSession) async {
        isRefreshing = true
        defer { isRefreshing = false }
        var s = WrapperSetupSnapshot()
        s.docker = await probeDocker()
        s.sourceReady = WrapperRecipe.sourceIsComplete(at: environment.root)
        s.sourcePath = environment.root.path
        s.package = package
        s.hostMachine = environment.hostMachine
        if s.docker.daemon, let docker = s.docker.docker {
            let inspect = await capture(docker, WrapperRecipe.imageInspectArguments)
            s.imageBuilt = inspect.exitCode == 0
            let fields = inspect.output.split(whereSeparator: \.isWhitespace)
            if s.imageBuilt, fields.count == 2 {
                s.imageArchitecture = WrapperArchitecture(dockerArchitecture: String(fields[0]))
                if s.sourceReady {
                    let service = await capture(docker, ["compose", "ps", "--status", "running", "-q", "wrapper"], directory: environment.root)
                    if service.exitCode == 0, !service.output.trimmed.isEmpty {
                        let running = await capture(docker, ["inspect", "--type", "container", "--format", "{{.Image}}", service.output.trimmed])
                        s.containerUsesBuiltImage = running.exitCode == 0 && running.output.trimmed == fields[1]
                    }
                }
            }
        }
        s.status = await environment.probe(WrapperRecipe.healthURL)
        // Reopening the assistant should keep the installed ABI. A manual
        // choice still takes precedence, including while a refresh is running.
        s.architecture = selectedArchitecture ?? s.imageArchitecture ?? architecture
        s.session = session
        snapshot = s
        states = Self.merge(WrapperRecipe.evaluate(s), keeping: states)
    }

    /// A failure or a pending hand-off stays visible until the step is done.
    private static func merge(_ new: [WrapperSetupStep: WrapperStepState], keeping old: [WrapperSetupStep: WrapperStepState]) -> [WrapperSetupStep: WrapperStepState] {
        var out = new
        for (step, state) in old where out[step]?.isDone != true {
            switch state {
            case .failed: out[step] = state
            case .todo(let m) where m != new[step]?.message && sticky.contains(m): out[step] = state
            default: break
            }
        }
        return out
    }

    /// Hand-off messages ("Terminal is open…") kept across refreshes.
    private static var sticky = Set<String>()

    func probeDocker() async -> DockerProbe {
        let tools = environment.tools
        var probe = DockerProbe(docker: tools.locate("docker"), colima: tools.locate("colima"), brew: tools.locate("brew"))
        guard let docker = probe.docker else { return probe }
        probe.compose = await execute(docker, ["compose", "version"], logged: false).exitCode == 0
        probe.buildx = await execute(docker, ["buildx", "version"], logged: false).exitCode == 0
        probe.daemon = await execute(docker, ["info", "--format", "{{.ServerVersion}}"], logged: false, timeout: .seconds(15)).exitCode == 0
        let context = await capture(docker, ["context", "show"])
        probe.context = context.exitCode == 0 ? context.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let config = environment.colimaHome.appending(path: "default/colima.yaml")
        probe.colimaSettings = (try? String(contentsOf: config, encoding: .utf8)).map(ColimaSettings.parse)
        return probe
    }

    // MARK: - Actions

    func choosePackage(_ url: URL) -> Bool {
        guard WrapperRecipe.isPackage(url), FileManager.default.isReadableFile(atPath: url.path) else {
            states[.package] = .failed(String(localized: "« \(url.lastPathComponent) » n'est pas un paquet .apk ou .apkm lisible."))
            return false
        }
        package = url
        snapshot.package = url
        states[.package] = .done(url.lastPathComponent)
        return true
    }

    /// Runs one step. Returns whether it is done afterwards.
    @discardableResult
    func perform(_ step: WrapperSetupStep, settings: AppSettings, gamdl: URL? = nil) async -> Bool {
        guard running == nil else { return false }
        running = step
        defer { running = nil }
        states[step] = .unknown
        appendLog("\n▶︎ \(step.title)\n")
        let outcome: WrapperStepState?
        switch step {
        case .docker: outcome = await prepareDocker()
        case .source: outcome = await cloneSource()
        case .package: outcome = package == nil ? WrapperRecipe.evaluate(snapshot)[.package] : nil
        case .build: outcome = await build()
        case .start: outcome = await start()
        case .signIn: outcome = signIn(gamdl: gamdl)
        case .activate:
            settings.session.authMode = .wrapper
            settings.session.wrapperURL = WrapperRecipe.healthURL
            outcome = nil
        }
        switch outcome {
        case .failed(let m)?: appendLog("✕ \(m)\n")
        case .todo(let m)?: appendLog("→ \(m)\n"); Self.sticky.insert(m)
        default: break
        }
        if let outcome { states[step] = outcome }
        await refresh(session: settings.session)
        return states[step]?.isDone == true
    }

    /// Runs every remaining step in order and stops at the first one that
    /// needs the user (missing tools, the package, the Apple sign-in) or fails.
    func installAll(settings: AppSettings, gamdl: URL? = nil) async {
        await refresh(session: settings.session)
        for step in WrapperSetupStep.allCases where !state(step).isDone {
            if step == .package { return }                    // the view asks for the file
            if step == .docker, !snapshot.docker.missingFormulae.isEmpty {
                await perform(step, settings: settings)        // opens Terminal, then the user comes back
                return
            }
            // Sign-in happens in Terminal, on demand. Activation waits for it:
            // in wrapper mode every download goes through the wrapper.
            if step == .signIn { return }
            guard await perform(step, settings: settings, gamdl: gamdl) else { return }
        }
    }

    func cancel() { runner?.cancel() }

    private func prepareDocker() async -> WrapperStepState? {
        let probe = await probeDocker()
        let missing = probe.missingFormulae
        if !missing.isEmpty {
            guard let brew = probe.brew else {
                return .failed(String(localized: "Homebrew est introuvable : installe-le depuis brew.sh, puis relance la vérification."))
            }
            do {
                try environment.openTerminal(WrapperRecipe.brewInstallScript(formulae: missing, brew: brew.path), "wrapper-docker-install")
                return .todo(String(localized: "Le Terminal installe \(missing.joined(separator: ", ")). Reviens ici quand il a fini, puis clique sur « Vérifier »."))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        var current = snapshot
        current.docker = probe
        current.architecture = architecture
        current.hostMachine = environment.hostMachine
        let needsRosetta = WrapperRecipe.colimaNeedsRosetta(current)
        if probe.daemon && !needsRosetta { return nil }
        guard let colima = probe.colima else {
            return .todo(String(localized: "Lance ton moteur Docker (Docker Desktop, OrbStack ou Colima), puis clique sur « Vérifier »."))
        }
        let start = WrapperRecipe.colimaStartArguments(hostMachine: environment.hostMachine, architecture: architecture, settings: probe.colimaSettings)
        if needsRosetta && !start.contains("--vz-rosetta") {
            return .failed(WrapperRecipe.evaluate(current)[.docker]?.message ?? "")
        }
        if probe.daemon {
            // Rosetta is only applied when the VM starts. The wrapper
            // container restarts with Docker (restart: unless-stopped).
            let stop = await execute(colima, ["stop"], timeout: .seconds(300))
            if stop.exitCode != 0 { return .failed(String(localized: "Colima ne s'est pas arrêté (code \(stop.exitCode)). Le détail est dans le journal.")) }
        }
        let result = await execute(colima, start, timeout: .seconds(600))
        if result.exitCode != 0 { return .failed(String(localized: "Colima n'a pas démarré (code \(result.exitCode)). Le détail est dans le journal.")) }
        return nil
    }

    private func cloneSource() async -> WrapperStepState? {
        let root = environment.root
        if WrapperRecipe.sourceIsComplete(at: root) { return nil }
        if FileManager.default.fileExists(atPath: root.path) {
            return .failed(String(localized: "Le dossier \(root.path) existe mais ne contient pas wrapper-v2 : déplace-le ou supprime-le, puis réessaie."))
        }
        guard let git = environment.tools.locate("git") else {
            return .failed(String(localized: "git est introuvable : installe les outils en ligne de commande d'Xcode (xcode-select --install)."))
        }
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = await execute(git, WrapperRecipe.cloneArguments(into: root), timeout: .seconds(600))
        guard result.exitCode == 0, WrapperRecipe.sourceIsComplete(at: root) else {
            return .failed(String(localized: "Le clonage de wrapper-v2 a échoué (code \(result.exitCode))."))
        }
        return nil
    }

    private func build() async -> WrapperStepState? {
        guard let package else { return .failed(String(localized: "Choisis d'abord ton paquet Apple Music.")) }
        guard FileManager.default.isReadableFile(atPath: package.path) else {
            return .failed(String(localized: "Le paquet \(package.lastPathComponent) n'est plus lisible."))
        }
        let script = environment.root.appending(path: "tools/build-docker.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return .failed(String(localized: "Télécharge d'abord le code de wrapper-v2.")) }
        appendLog(String(localized: "Construction pour \(architecture.rawValue). L'image contient des bibliothèques d'Apple : ne la publie pas.") + "\n")
        let args = WrapperRecipe.buildArguments(package: package, architecture: architecture)
        buildProgress = BuildKitProgress()
        buildStartedAt = .now
        // The last progress stays readable after the build (tests, log).
        defer { buildStartedAt = nil }
        let result = await execute(URL(filePath: "/bin/bash"), args, directory: environment.root, timeout: .seconds(7200)) { [weak self] text in
            self?.buildProgress?.consume(text)
        }
        if result.cancelled { return .failed(String(localized: "Construction annulée.")) }
        if result.exitCode != 0 {
            return .failed(String(localized: "La construction a échoué (code \(result.exitCode)). Vérifie que le paquet est bien la build 1109 pour \(architecture.rawValue) ; le détail est dans le journal."))
        }
        return nil
    }

    private func start() async -> WrapperStepState? {
        guard let docker = environment.tools.locate("docker") else { return .failed(String(localized: "docker est introuvable.")) }
        guard WrapperRecipe.sourceIsComplete(at: environment.root) else { return .failed(String(localized: "Télécharge d'abord le code de wrapper-v2.")) }
        let result = await execute(docker, WrapperRecipe.composeUpArguments, directory: environment.root, timeout: .seconds(300))
        if result.exitCode != 0 { return .failed(String(localized: "docker compose up a échoué (code \(result.exitCode)).")) }
        let clock = ContinuousClock()
        let deadline = clock.now + environment.startTimeout
        while clock.now < deadline {
            if case .unreachable = await environment.probe(WrapperRecipe.healthURL) {
                try? await Task.sleep(for: environment.pollInterval)
                continue
            }
            return nil
        }
        return .failed(String(localized: "Le conteneur tourne mais rien ne répond sur \(WrapperRecipe.healthURL). Regarde « docker compose logs » dans \(environment.root.path)."))
    }

    private func signIn(gamdl: URL?) -> WrapperStepState? {
        guard let gamdl else { return .failed(String(localized: "gamdl est introuvable : installe-le d'abord (onglet Diagnostic).")) }
        do {
            try environment.openTerminal(TerminalLauncher.script(running: gamdl), "gamdl-auth")
            return .todo(String(localized: "Le Terminal est ouvert : choisis « Wrapper », connecte-toi, puis clique sur « Vérifier »."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Processes

    private struct Outcome { var exitCode: Int32; var cancelled = false }

    private func execute(
        _ executable: URL, _ arguments: [String], directory: URL? = nil,
        logged: Bool = true, timeout: Duration = .seconds(20),
        observe: (@MainActor (String) -> Void)? = nil
    ) async -> Outcome {
        let runner = ProcessRunner()
        if logged {
            self.runner = runner
            appendLog("$ \(([executable.lastPathComponent] + arguments).map(GamdlCommand.shellQuote).joined(separator: " "))\n")
        }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            runner.cancel()
        }
        defer { watchdog.cancel() }
        do {
            let result = try await runner.run(
                executable: executable, arguments: arguments,
                environment: environment.processEnvironment, currentDirectory: directory
            ) { [weak self] text in
                guard logged else { return }
                Task { @MainActor in
                    self?.appendLog(text)
                    observe?(text)
                }
            }
            return Outcome(exitCode: result.exitCode, cancelled: result.wasCancelled)
        } catch {
            if logged { appendLog("\(error.localizedDescription)\n") }
            return Outcome(exitCode: -1)
        }
    }

    /// Runs a short, unlogged command and returns its output.
    private func capture(_ executable: URL, _ arguments: [String], directory: URL? = nil) async -> (output: String, exitCode: Int32) {
        let collected = OutputCollector()
        let runner = ProcessRunner()
        let watchdog = Task { try await Task.sleep(for: .seconds(20)); runner.cancel() }
        defer { watchdog.cancel() }
        guard let result = try? await runner.run(executable: executable, arguments: arguments,
                                                 environment: environment.processEnvironment, currentDirectory: directory,
                                                 onOutput: { collected.append($0) })
        else { return ("", -1) }
        return (collected.value, result.exitCode)
    }

    func appendLog(_ text: String) {
        log += text
        if log.count > Self.maxLog { log = String(log.suffix(Self.maxLog)) }
    }
}

/// Why the wrapper matters for a download, checked before it is queued:
/// ALAC (lossless), Dolby Atmos and the other spatial codecs.
///
/// With plain cookies Apple rejects the ALAC license (measured with gamdl
/// 4.1.2), so that download would fail. Atmos and spatial audio did download
/// with cookies in the same measurements: for them the warning is advice,
/// and it can be turned off.
enum WrapperGate: Hashable, Sendable {
    /// ALAC with the cookies file: the download would fail.
    case wrapperNotActivated
    /// The wrapper is the session mode, but the last check found it not ready.
    case wrapperNotReady(WrapperStatus?)
    /// Dolby Atmos or spatial audio with the cookies file: advice only.
    case spatialWithoutWrapper

    static func check(options: DownloadOptions, session: GamdlSession, wrapper: WrapperStatus?, warnSpatial: Bool = true) -> WrapperGate? {
        let codecs = options.songCodecPriority
        let lossless = codecs.contains(where: \.needsWrapper)
        let spatial = codecs.contains { $0.family == .spatial }
        guard lossless || spatial else { return nil }
        if session.authMode == .wrapper {
            return wrapper?.isReady == true ? nil : .wrapperNotReady(wrapper)
        }
        if lossless { return .wrapperNotActivated }
        return warnSpatial ? .spatialWithoutWrapper : nil
    }

    /// Whether the download would fail without acting on the warning.
    var isBlocking: Bool { self != .spatialWithoutWrapper }

    var title: String {
        switch self {
        case .wrapperNotActivated: String(localized: "L'ALAC demande le wrapper")
        case .wrapperNotReady: String(localized: "Le wrapper n'est pas prêt")
        case .spatialWithoutWrapper: String(localized: "Dolby Atmos et audio spatial sans wrapper")
        }
    }

    var message: String {
        switch self {
        case .wrapperNotActivated:
            String(localized: "Avec le seul fichier de cookies, Apple refuse la licence de l'ALAC et le téléchargement échouera. Active le wrapper de gamdl : l'assistant l'installe avec Docker et le configure.")
        case .wrapperNotReady(let status):
            [status?.title, status?.message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " : ")
                + (status == nil ? String(localized: "Le wrapper n'a pas encore été vérifié.") : "")
                + "\n" + String(localized: "Sans wrapper prêt, gamdl ne peut rien télécharger dans ce mode.")
        case .spatialWithoutWrapper:
            String(localized: "Tu télécharges en Dolby Atmos ou en audio spatial avec le seul fichier de cookies. Lors des tests avec gamdl 4.1.2, ces codecs ont fonctionné ainsi ; si Apple refuse une licence, le wrapper est la voie à prendre. L'assistant l'installe avec Docker.")
        }
    }
}

/// Progress of a `docker buildx build`, estimated from BuildKit's plain
/// output (`BUILDKIT_PROGRESS=plain`):
///
///     #12 [builder  3/15] RUN cargo build --release
///     #12 DONE 41.2s
///     #13 [runtime 2/6] COPY --from=builder …
///     #13 CACHED
///
/// Each `[stage n/m]` line is one step of a stage with `m` steps. The total is
/// the sum of the stages seen so far, so the estimate can only go up.
struct BuildKitProgress: Hashable, Sendable {
    /// Steps per stage, as announced by `n/m`.
    private(set) var stageTotals: [String: Int] = [:]
    /// Vertex id → "stage n".
    private var steps: [Int: String] = [:]
    private var finishedSteps: Set<String> = []
    /// The latest step started, e.g. "[builder 3/15] RUN cargo build --release".
    private(set) var current: String?
    private var pending = ""
    private var shown = 0.0

    var finished: Int { finishedSteps.count }
    var total: Int { stageTotals.values.reduce(0, +) }

    /// 0…0.99 while building: the last percent is the image export.
    var fraction: Double { shown }

    mutating func consume(_ text: String) {
        pending += text
        var lines = pending.components(separatedBy: .newlines)
        pending = lines.removeLast()
        for line in lines { read(line.trimmingCharacters(in: .whitespaces)) }
    }

    private static let stepPattern = /^#(\d+) \[([^\]]*?)\s*(\d+)\/(\d+)\] (.*)$/
    private static let donePattern = /^#(\d+) (DONE|CACHED)\b/

    private mutating func read(_ line: String) {
        if let m = line.wholeMatch(of: Self.stepPattern), let id = Int(m.1), let n = Int(m.3), let total = Int(m.4) {
            let stage = m.2.trimmingCharacters(in: .whitespaces)
            stageTotals[stage] = max(stageTotals[stage] ?? 0, total)
            let key = "\(stage) \(n)"
            steps[id] = key
            let label = stage.isEmpty ? "[\(n)/\(total)]" : "[\(stage) \(n)/\(total)]"
            current = String((label + " " + m.5).prefix(120))
        } else if let m = line.prefixMatch(of: Self.donePattern), let id = Int(m.1), let key = steps[id] {
            finishedSteps.insert(key)
        } else {
            return
        }
        if total > 0 { shown = max(shown, min(0.99, Double(finished) / Double(total))) }
    }
}

/// The one action the codec picker offers when the chosen codec wants the
/// wrapper and the app doesn't use one yet.
enum WrapperCallToAction: Hashable, Sendable {
    /// A signed-in wrapper already answers on this Mac: just switch to it.
    case activate
    /// It answers but isn't signed in to an Apple Account.
    case connect
    /// Nothing answers: install it.
    case install
    /// Wrapper mode is on but the wrapper isn't ready.
    case openAssistant

    static func choose(gate: WrapperGate?, local: WrapperStatus?) -> WrapperCallToAction? {
        switch gate {
        case nil: return nil
        case .wrapperNotReady: return .openAssistant
        case .wrapperNotActivated, .spatialWithoutWrapper:
            switch local {
            case .ready?: return .activate
            case .loggedOut?: return .connect
            default: return .install
            }
        }
    }

    var title: String {
        switch self {
        case .activate: String(localized: "Activer le wrapper")
        case .connect: String(localized: "Connecter et activer le wrapper…")
        case .install: String(localized: "Installer le wrapper…")
        case .openAssistant: String(localized: "Ouvrir l'assistant du wrapper…")
        }
    }

    var symbol: String {
        switch self {
        case .activate: "bolt.fill"
        case .connect: "person.badge.key.fill"
        case .install: "arrow.down.circle.fill"
        case .openAssistant: "wand.and.stars"
        }
    }
}

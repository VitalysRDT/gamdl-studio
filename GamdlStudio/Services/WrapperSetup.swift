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
struct DockerProbe: Hashable, Sendable {
    var docker: URL?
    var compose = false
    var buildx = false
    var daemon = false
    var colima: URL?
    var brew: URL?

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
    /// The ABI chosen in the assistant.
    var architecture: WrapperArchitecture = .x86_64
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
    static let imageInspectArguments = ["image", "inspect", "--format", "{{.Architecture}}", image]

    /// `colima start`. A first start on a puce Apple uses the macOS
    /// virtualization framework with Rosetta, so x86_64 images also run.
    /// An existing VM keeps the settings it was created with.
    static func colimaStartArguments(hostMachine: String, firstRun: Bool) -> [String] {
        guard firstRun, WrapperArchitecture.native(machine: hostMachine) == .arm64 else { return ["start"] }
        return ["start", "--vm-type", "vz", "--vz-rosetta"]
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
    var architecture: WrapperArchitecture {
        didSet {
            snapshot.architecture = architecture
            states = Self.merge(WrapperRecipe.evaluate(snapshot), keeping: states)
        }
    }
    private(set) var package: URL?

    let environment: WrapperSetupEnvironment
    private var runner: ProcessRunner?
    private static let maxLog = 200_000

    init(environment: WrapperSetupEnvironment = .live()) {
        self.environment = environment
        // The only ABI wrapper-v2 validated end to end, even if emulated here.
        architecture = .x86_64
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
        s.architecture = architecture
        if s.docker.daemon, let docker = s.docker.docker {
            let inspect = await capture(docker, WrapperRecipe.imageInspectArguments)
            s.imageBuilt = inspect.exitCode == 0
            s.imageArchitecture = s.imageBuilt ? WrapperArchitecture(dockerArchitecture: inspect.output) : nil
        }
        s.status = await environment.probe(WrapperRecipe.healthURL)
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
        if probe.daemon { return nil }
        guard let colima = probe.colima else {
            return .todo(String(localized: "Lance ton moteur Docker (Docker Desktop, OrbStack ou Colima), puis clique sur « Vérifier »."))
        }
        let firstRun = !FileManager.default.fileExists(atPath: environment.colimaHome.appending(path: "default").path)
        let result = await execute(colima, WrapperRecipe.colimaStartArguments(hostMachine: environment.hostMachine, firstRun: firstRun), timeout: .seconds(600))
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
        let result = await execute(URL(filePath: "/bin/bash"), args, directory: environment.root, timeout: .seconds(7200))
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
        logged: Bool = true, timeout: Duration = .seconds(20)
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
                Task { @MainActor in self?.appendLog(text) }
            }
            return Outcome(exitCode: result.exitCode, cancelled: result.wasCancelled)
        } catch {
            if logged { appendLog("\(error.localizedDescription)\n") }
            return Outcome(exitCode: -1)
        }
    }

    /// Runs a short, unlogged command and returns its output.
    private func capture(_ executable: URL, _ arguments: [String]) async -> (output: String, exitCode: Int32) {
        let collected = OutputCollector()
        let runner = ProcessRunner()
        let watchdog = Task { try await Task.sleep(for: .seconds(20)); runner.cancel() }
        defer { watchdog.cancel() }
        guard let result = try? await runner.run(executable: executable, arguments: arguments,
                                                 environment: environment.processEnvironment, onOutput: { collected.append($0) })
        else { return ("", -1) }
        return (collected.value, result.exitCode)
    }

    func appendLog(_ text: String) {
        log += text
        if log.count > Self.maxLog { log = String(log.suffix(Self.maxLog)) }
    }
}

/// Why a download asking for ALAC would fail, checked before it is queued.
/// With plain cookies Apple rejects the ALAC license (measured with gamdl
/// 4.1.2), so the user is warned instead of watching the job fail.
enum LosslessGate: Hashable, Sendable {
    /// The app still signs in with the cookies file.
    case wrapperNotActivated
    /// The wrapper is the session mode, but the last check found it not ready.
    case wrapperNotReady(WrapperStatus?)

    static func check(options: DownloadOptions, session: GamdlSession, wrapper: WrapperStatus?) -> LosslessGate? {
        guard options.songCodecPriority.contains(where: \.needsWrapper) else { return nil }
        guard session.authMode == .wrapper else { return .wrapperNotActivated }
        return wrapper?.isReady == true ? nil : .wrapperNotReady(wrapper)
    }

    var title: String {
        switch self {
        case .wrapperNotActivated: String(localized: "L'ALAC demande le wrapper")
        case .wrapperNotReady: String(localized: "Le wrapper n'est pas prêt")
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
        }
    }
}

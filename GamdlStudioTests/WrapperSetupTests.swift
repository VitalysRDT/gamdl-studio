import Foundation
import Testing
@testable import GamdlStudio

// MARK: - Unit: recipe, states, ALAC gate

@Suite("Wrapper setup recipe")
struct WrapperRecipeTests {
    @Test("Clones the pinned wrapper-v2 release, shallow")
    func clone() {
        let args = WrapperRecipe.cloneArguments(into: URL(filePath: "/tmp/w"))
        #expect(args == ["clone", "--depth", "1", "--branch", "1.0.1", "https://github.com/glomatico/wrapper-v2.git", "/tmp/w"])
    }

    @Test("Builds with the user's package and the chosen ABI", arguments: WrapperArchitecture.allCases)
    func build(arch: WrapperArchitecture) {
        let args = WrapperRecipe.buildArguments(package: URL(filePath: "/Users/me/Apple Music.apkm"), architecture: arch)
        #expect(args == ["tools/build-docker.sh", "/Users/me/Apple Music.apkm", "--arch", arch.rawValue])
    }

    @Test("Docker's image architecture maps to the ABI")
    func dockerArch() {
        #expect(WrapperArchitecture(dockerArchitecture: "amd64\n") == .x86_64)
        #expect(WrapperArchitecture(dockerArchitecture: "arm64") == .arm64)
        #expect(WrapperArchitecture(dockerArchitecture: "s390x") == nil)
    }

    @Test("An image built for the other ABI needs the package and a rebuild")
    func mismatch() {
        var s = WrapperSetupSnapshot()
        s.imageBuilt = true
        s.imageArchitecture = .x86_64
        s.architecture = .arm64
        let states = WrapperRecipe.evaluate(s)
        #expect(!states[.build]!.isDone)
        #expect(!states[.package]!.isDone)
        s.architecture = .x86_64
        #expect(WrapperRecipe.evaluate(s)[.build]?.isDone == true)
    }

    @Test("The assistant defaults to x86_64, the ABI wrapper-v2 validated")
    @MainActor func defaultArch() {
        var env = WrapperSetupEnvironment.live()
        env.hostMachine = "arm64"
        #expect(WrapperSetup(environment: env).architecture == .x86_64)
    }

    @Test("Native ABI follows the host CPU")
    func native() {
        #expect(WrapperArchitecture.native(machine: "arm64") == .arm64)
        #expect(WrapperArchitecture.native(machine: "aarch64") == .arm64)
        #expect(WrapperArchitecture.native(machine: "x86_64") == .x86_64)
        #expect(!WrapperArchitecture.hostMachine.isEmpty)
    }

    @Test("A first Colima start on Apple silicon gets vz and Rosetta; an existing VM keeps its settings")
    func colima() {
        #expect(WrapperRecipe.colimaStartArguments(hostMachine: "arm64", firstRun: true) == ["start", "--vm-type", "vz", "--vz-rosetta"])
        #expect(WrapperRecipe.colimaStartArguments(hostMachine: "arm64", firstRun: false) == ["start"])
        #expect(WrapperRecipe.colimaStartArguments(hostMachine: "x86_64", firstRun: true) == ["start"])
    }

    @Test("Only .apk and .apkm are accepted as the package")
    func package() {
        #expect(WrapperRecipe.isPackage(URL(filePath: "/a/Music.apk")))
        #expect(WrapperRecipe.isPackage(URL(filePath: "/a/Music.APKM")))
        #expect(!WrapperRecipe.isPackage(URL(filePath: "/a/Music.zip")))
        #expect(!WrapperRecipe.isPackage(URL(filePath: "/a/Music")))
    }

    @Test("Missing Homebrew formulae")
    func formulae() {
        #expect(DockerProbe().missingFormulae == ["colima", "docker", "docker-compose", "docker-buildx"])
        #expect(DockerProbe(colima: URL(filePath: "/c")).missingFormulae == ["docker", "docker-compose", "docker-buildx"])
        #expect(DockerProbe(docker: URL(filePath: "/d"), compose: true, buildx: false).missingFormulae == ["docker-buildx"])
        #expect(DockerProbe(docker: URL(filePath: "/d"), compose: true, buildx: true).missingFormulae.isEmpty)
    }

    @Test("The brew script installs the formulae and registers Homebrew's CLI plugins")
    func brewScript() {
        let script = WrapperRecipe.brewInstallScript(formulae: ["docker-compose", "docker-buildx"], brew: "/opt/homebrew/bin/brew")
        #expect(script.hasPrefix("'/opt/homebrew/bin/brew' install docker-compose docker-buildx\n") || script.hasPrefix("/opt/homebrew/bin/brew install docker-compose docker-buildx\n"))
        #expect(script.contains("cliPluginsExtraDirs"))
        #expect(script.contains("/opt/homebrew/lib/docker/cli-plugins"))
    }

    @Test("Activated means wrapper mode on the local address")
    func activated() {
        var session = GamdlSession()
        #expect(!WrapperRecipe.isActivated(session))
        session.authMode = .wrapper
        #expect(WrapperRecipe.isActivated(session))
        session.wrapperURL = "http://localhost:8080/"
        #expect(WrapperRecipe.isActivated(session))
        session.wrapperURL = "http://192.168.1.20:8080"
        #expect(!WrapperRecipe.isActivated(session))
    }

    @Test("Nothing installed: every step is to do, in order")
    func emptyState() {
        let states = WrapperRecipe.evaluate(WrapperSetupSnapshot())
        #expect(WrapperSetupStep.allCases.allSatisfy { states[$0]?.isDone == false })
        #expect(states[.docker]?.message.contains("docker-compose") == true)
        #expect(states[.docker]?.message.contains("Homebrew") == true)
    }

    @Test("Docker stopped with Colima present offers to start Colima")
    func dockerStopped() {
        var s = WrapperSetupSnapshot()
        s.docker = DockerProbe(docker: URL(filePath: "/d"), compose: true, buildx: true, daemon: false, colima: URL(filePath: "/c"))
        guard case .todo(let message) = WrapperRecipe.evaluate(s)[.docker] else { Issue.record("expected todo"); return }
        #expect(message.contains("Colima"))
    }

    @Test("A built image makes the package unnecessary")
    func imageBuilt() {
        var s = WrapperSetupSnapshot()
        s.imageBuilt = true
        let states = WrapperRecipe.evaluate(s)
        #expect(states[.package]?.isDone == true)
        #expect(states[.build]?.isDone == true)
    }

    @Test("Wrapper status drives the start and sign-in steps")
    func statusSteps() {
        var s = WrapperSetupSnapshot()
        s.status = .loggedOut
        var states = WrapperRecipe.evaluate(s)
        #expect(states[.start]?.isDone == true)
        #expect(states[.signIn]?.isDone == false)

        s.status = .ready(version: "1.0.1", architecture: "x86_64")
        states = WrapperRecipe.evaluate(s)
        #expect(states[.signIn] == .done("wrapper-v2 1.0.1 · x86_64"))

        s.status = .incompatible("old")
        #expect(WrapperRecipe.evaluate(s)[.signIn] == .failed("old"))
    }
}

@Suite("Wrapper gate: ALAC, Dolby Atmos, spatial")
struct WrapperGateTests {
    private func options(_ codecs: [SongCodec]) -> DownloadOptions {
        var o = DownloadOptions()
        o.songCodecPriority = codecs
        return o
    }

    @Test("Stereo AAC never brings up the wrapper", arguments: SongCodec.Family.stereo.codecs)
    func stereo(codec: SongCodec) {
        #expect(WrapperGate.check(options: options([codec]), session: GamdlSession(), wrapper: nil) == nil)
    }

    @Test("Dolby Atmos and spatial codecs with cookies get advice, not a block", arguments: SongCodec.Family.spatial.codecs)
    func spatial(codec: SongCodec) {
        let gate = WrapperGate.check(options: options([codec]), session: GamdlSession(), wrapper: nil)
        #expect(gate == .spatialWithoutWrapper)
        #expect(gate?.isBlocking == false)
        #expect(WrapperGate.check(options: options([codec]), session: GamdlSession(), wrapper: nil, warnSpatial: false) == nil)
    }

    @Test("Atmos with an AAC fallback still gets the advice; ALAC in the list wins over it")
    func spatialFallback() {
        #expect(WrapperGate.check(options: options([.atmos, .aacWeb]), session: GamdlSession(), wrapper: nil) == .spatialWithoutWrapper)
        #expect(WrapperGate.check(options: options([.atmos, .alac]), session: GamdlSession(), wrapper: nil) == .wrapperNotActivated)
        #expect(WrapperGate.check(options: options([.atmos, .alac]), session: GamdlSession(), wrapper: nil, warnSpatial: false) == .wrapperNotActivated)
    }

    @Test("In wrapper mode, Atmos also waits for a ready wrapper")
    func spatialWrapperMode() {
        var session = GamdlSession()
        session.authMode = .wrapper
        #expect(WrapperGate.check(options: options([.atmos]), session: session, wrapper: .loggedOut) == .wrapperNotReady(.loggedOut))
        #expect(WrapperGate.check(options: options([.atmos]), session: session, wrapper: .ready(version: "1.0.1", architecture: "x86_64")) == nil)
    }

    @Test("The spatial warning setting persists, on by default")
    @MainActor func spatialSetting() throws {
        let name = "gamdlstudio.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.warnSpatialWithoutWrapper)
        settings.warnSpatialWithoutWrapper = false
        #expect(AppSettings(defaults: defaults).warnSpatialWithoutWrapper == false)
        let model = AppModel(settings: AppSettings(defaults: defaults))
        model.settings.options.songCodecPriority = [.atmos]
        #expect(model.wrapperGate == nil)
        model.settings.warnSpatialWithoutWrapper = true
        #expect(model.wrapperGate == .spatialWithoutWrapper)
    }

    @Test("ALAC with cookies only is blocked as not activated", arguments: SongCodec.Family.lossless.codecs)
    func cookies(codec: SongCodec) {
        #expect(WrapperGate.check(options: options([codec]), session: GamdlSession(), wrapper: nil) == .wrapperNotActivated)
    }

    @Test("An ALAC fallback after AAC still counts: gamdl falls back on availability, not on license")
    func fallback() {
        #expect(WrapperGate.check(options: options([.aacWeb, .alac]), session: GamdlSession(), wrapper: nil) == .wrapperNotActivated)
    }

    @Test("Wrapper mode passes only when the wrapper is ready")
    func wrapperMode() {
        var session = GamdlSession()
        session.authMode = .wrapper
        let alac = options([.alac])
        #expect(WrapperGate.check(options: alac, session: session, wrapper: nil) == .wrapperNotReady(nil))
        #expect(WrapperGate.check(options: alac, session: session, wrapper: .loggedOut) == .wrapperNotReady(.loggedOut))
        #expect(WrapperGate.check(options: alac, session: session, wrapper: .ready(version: "1.0.1", architecture: "x86_64")) == nil)
    }

    @Test("Messages name the problem")
    func messages() {
        #expect(WrapperGate.wrapperNotActivated.message.contains("cookies"))
        #expect(WrapperGate.wrapperNotReady(.loggedOut).message.contains(WrapperStatus.loggedOut.title))
        #expect(WrapperGate.wrapperNotReady(nil).message.contains("vérifié"))
        #expect(WrapperGate.spatialWithoutWrapper.message.contains("Dolby Atmos"))
        #expect(WrapperGate.wrapperNotActivated.isBlocking && WrapperGate.wrapperNotReady(nil).isBlocking)
    }

    @Test("A dropped ALAC link lands in the link field instead of the queue")
    @MainActor func dropped() throws {
        let defaults = try #require(UserDefaults(suiteName: "gamdlstudio.tests.\(UUID().uuidString)"))
        let model = AppModel(settings: AppSettings(defaults: defaults))
        model.settings.options.songCodecPriority = [.alac]
        let link = try #require(AppleMusicLink.extractAll(from: "https://music.apple.com/fr/album/x/1739659142").first)
        model.selection = .library
        model.enqueueDropped([link])
        #expect(model.queue.jobs.isEmpty)
        #expect(model.draftURL == link.absoluteString)
        #expect(model.selection == .download)
    }
}

// MARK: - Integration: the whole installation against fake tools

/// Fake `docker`, `git` and `colima` in a temp folder. They record their
/// calls and change a state folder the way the real tools would.
private final class FakeToolchain {
    let root: URL
    let bin: URL
    let state: URL
    let calls: URL
    let wrapperDir: URL
    let package: URL

    init(withDocker: Bool = true, buildFails: Bool = false) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "wrapper-setup-\(UUID().uuidString)")
        bin = root.appending(path: "bin")
        state = root.appending(path: "state")
        calls = root.appending(path: "calls.log")
        wrapperDir = root.appending(path: "support/wrapper-v2")
        package = root.appending(path: "Apple Music 1109.apk")
        for dir in [bin, state] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("apk".utf8).write(to: package)
        let log = calls.path, st = state.path
        if withDocker {
            try script("docker", """
            echo "docker $*" >> '\(log)'
            case "$1 $2" in
              "compose version"|"buildx version") exit 0 ;;
              "compose up") touch '\(st)/up'; exit 0 ;;
              "info --format") [ -f '\(st)/daemon' ] ;;
              "image inspect") [ -f '\(st)/image' ] && cat '\(st)/image' ;;
              *) exit 3 ;;
            esac
            """)
            try script("colima", """
            echo "colima $*" >> '\(log)'
            touch '\(st)/daemon'
            """)
        }
        try script("git", """
        echo "git $*" >> '\(log)'
        for last; do :; done
        mkdir -p "$last/tools"
        echo "services: {}" > "$last/compose.yaml"
        cat > "$last/tools/build-docker.sh" <<'EOS'
        echo "build $* in $(pwd)" >> '\(log)'
        command -v sha256sum >/dev/null || { echo "no sha256sum on PATH"; exit 9; }
        \(buildFails ? "exit 4" : "echo amd64 > '\(st)/image'")
        EOS
        """)
    }

    private func script(_ name: String, _ body: String) throws {
        let url = bin.appending(path: name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var callLog: String { (try? String(contentsOf: calls, encoding: .utf8)) ?? "" }
    func has(_ flag: String) -> Bool { FileManager.default.fileExists(atPath: state.appending(path: flag).path) }

    func environment(terminal: TerminalRecorder) -> WrapperSetupEnvironment {
        let state = state
        return WrapperSetupEnvironment(
            tools: ToolLocator(searchDirectories: [bin, URL(filePath: "/usr/bin"), URL(filePath: "/bin")]),
            root: wrapperDir,
            hostMachine: "x86_64",
            colimaHome: root.appending(path: "colima-home"),
            probe: { _ in
                let fm = FileManager.default
                guard fm.fileExists(atPath: state.appending(path: "up").path) else { return .unreachable("nothing") }
                return fm.fileExists(atPath: state.appending(path: "auth").path)
                    ? .ready(version: "1.0.1", architecture: "x86_64") : .loggedOut
            },
            startTimeout: .seconds(3),
            pollInterval: .milliseconds(50),
            openTerminal: { script, name in terminal.record(script, name) }
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class TerminalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(script: String, name: String)] = []
    func record(_ script: String, _ name: String) { lock.withLock { items.append((script, name)) } }
    var opened: [(script: String, name: String)] { lock.withLock { items } }
}

@MainActor
private func freshSettings() throws -> AppSettings {
    AppSettings(defaults: try #require(UserDefaults(suiteName: "gamdlstudio.tests.\(UUID().uuidString)")))
}

@Suite("Wrapper installation with fake tools (integration)", .serialized)
@MainActor
struct WrapperSetupIntegrationTests {
    @Test("Install all: starts Docker, clones, stops at the package, then builds, starts, activates, waits for sign-in")
    func fullInstall() async throws {
        let fake = try FakeToolchain()
        let terminal = TerminalRecorder()
        let setup = WrapperSetup(environment: fake.environment(terminal: terminal))
        let settings = try freshSettings()
        #expect(setup.architecture == .x86_64)

        await setup.installAll(settings: settings)
        #expect(setup.state(.docker).isDone)
        #expect(setup.state(.source).isDone)
        #expect(!setup.state(.package).isDone)
        #expect(setup.nextStep == .package)
        #expect(fake.callLog.contains("colima start\n"))
        #expect(fake.callLog.contains("git clone --depth 1 --branch 1.0.1 https://github.com/glomatico/wrapper-v2.git \(fake.wrapperDir.path)"))
        #expect(!fake.callLog.contains("build "))

        #expect(setup.choosePackage(fake.package))
        await setup.installAll(settings: settings)
        // `pwd` reports /private/var for the temp folder.
        #expect(fake.callLog.contains("build \(fake.package.path) --arch x86_64 in /private\(fake.wrapperDir.path)")
                || fake.callLog.contains("build \(fake.package.path) --arch x86_64 in \(fake.wrapperDir.path)"))
        #expect(fake.callLog.contains("docker compose up -d"))
        #expect(fake.has("image") && fake.has("up"))
        #expect(setup.state(.build) == .done("Image wrapper-v2:local présente (x86_64)."))
        #expect(setup.state(.start).isDone)
        #expect(setup.nextStep == .signIn)
        #expect(!setup.state(.activate).isDone, "activation waits for the Apple sign-in")
        #expect(settings.session.authMode == .cookies)
        #expect(terminal.opened.isEmpty, "the Apple sign-in only opens on demand")

        let gamdl = URL(filePath: "/Users/me/.local/bin/gamdl")
        await setup.perform(.signIn, settings: settings, gamdl: gamdl)
        #expect(terminal.opened.last?.name == "gamdl-auth")
        guard case .todo = setup.state(.signIn) else { Issue.record("a Terminal hand-off is not a failure"); return }
        #expect(!setup.log.contains("✕"))
        #expect(terminal.opened.last?.script.contains("'/Users/me/.local/bin/gamdl' auth") == true
                || terminal.opened.last?.script.contains("/Users/me/.local/bin/gamdl auth") == true)

        try Data().write(to: fake.state.appending(path: "auth"))
        await setup.installAll(settings: settings, gamdl: gamdl)
        #expect(setup.state(.signIn).isDone)
        #expect(settings.session.authMode == .wrapper)
        #expect(settings.session.wrapperURL == GamdlSession.defaultWrapperURL)
        #expect(setup.isComplete)

        // Switching ABI asks for a rebuild for that ABI.
        setup.architecture = .arm64
        #expect(!setup.state(.build).isDone)
        #expect(setup.state(.build).message.contains("x86_64"))
        #expect(setup.log.contains("$ git clone"))
    }

    @Test("Missing Docker tools open Terminal with the brew command and stop there")
    func missingTools() async throws {
        let fake = try FakeToolchain(withDocker: false)
        let terminal = TerminalRecorder()
        var env = fake.environment(terminal: terminal)
        // A fake brew, so the assistant knows Homebrew is there.
        let brew = fake.bin.appending(path: "brew")
        try "#!/bin/sh\nexit 0\n".write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        env.tools = ToolLocator(searchDirectories: [fake.bin])
        let setup = WrapperSetup(environment: env)
        let settings = try freshSettings()

        await setup.installAll(settings: settings)
        #expect(terminal.opened.count == 1)
        #expect(terminal.opened.first?.script.contains("install colima docker docker-compose docker-buildx") == true)
        guard case .todo(let message) = setup.state(.docker) else { Issue.record("a Terminal hand-off is not a failure"); return }
        #expect(message.contains("Terminal"))
        #expect(!setup.state(.docker).isDone)
        #expect(!setup.state(.source).isDone, "nothing past Docker runs while tools are missing")
        #expect(!fake.callLog.contains("git"))
    }

    @Test("A folder in the way is never overwritten")
    func folderInTheWay() async throws {
        let fake = try FakeToolchain()
        try FileManager.default.createDirectory(at: fake.wrapperDir, withIntermediateDirectories: true)
        let keep = fake.wrapperDir.appending(path: "mine.txt")
        try Data("keep".utf8).write(to: keep)
        let setup = WrapperSetup(environment: fake.environment(terminal: TerminalRecorder()))
        let settings = try freshSettings()

        let done = await setup.perform(.source, settings: settings)
        #expect(!done)
        guard case .failed(let message) = setup.state(.source) else { Issue.record("expected a failure"); return }
        #expect(message.contains(fake.wrapperDir.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!fake.callLog.contains("git clone"))
    }

    @Test("A failed build is reported and stops the installation")
    func buildFails() async throws {
        let fake = try FakeToolchain(buildFails: true)
        let setup = WrapperSetup(environment: fake.environment(terminal: TerminalRecorder()))
        let settings = try freshSettings()
        await setup.installAll(settings: settings)
        #expect(setup.choosePackage(fake.package))
        await setup.installAll(settings: settings)
        guard case .failed(let message) = setup.state(.build) else { Issue.record("expected a failure"); return }
        #expect(message.contains("4"))
        #expect(!fake.callLog.contains("compose up"))
        #expect(settings.session.authMode == .cookies, "a broken install must not switch the app to the wrapper")
    }

    @Test("A wrong file is refused as the package")
    func wrongPackage() throws {
        let fake = try FakeToolchain()
        let setup = WrapperSetup(environment: fake.environment(terminal: TerminalRecorder()))
        let zip = fake.root.appending(path: "music.zip")
        try Data().write(to: zip)
        #expect(!setup.choosePackage(zip))
        #expect(setup.package == nil)
        #expect(!setup.choosePackage(fake.root.appending(path: "missing.apk")))
    }

    @Test("The service started but never answering is a failure with a hint")
    func neverAnswers() async throws {
        let fake = try FakeToolchain()
        var env = fake.environment(terminal: TerminalRecorder())
        env.probe = { _ in .unreachable("nothing") }
        env.startTimeout = .milliseconds(200)
        let setup = WrapperSetup(environment: env)
        let settings = try freshSettings()
        let early = await setup.perform(.start, settings: settings)
        #expect(!early)
        #expect(setup.state(.start).message.contains("code de wrapper-v2"), "no compose up without the source")
        #expect(!fake.callLog.contains("compose up"))
        #expect(await setup.perform(.source, settings: settings))
        let done = await setup.perform(.start, settings: settings)
        #expect(!done)
        #expect(setup.state(.start).message.contains("docker compose logs"))
    }

    @Test("The generic Terminal script is owner-only and ends with a hint")
    func terminalScript() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try TerminalLauncher.open(script: "echo hi", name: "t", directory: dir, launch: false)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/sh\n"))
        #expect(text.contains("set -e\necho hi\n"))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }
}

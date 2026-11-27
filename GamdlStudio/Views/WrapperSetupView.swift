import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Guided installation of gamdl's wrapper-v2, the service gamdl 4 needs for
/// ALAC. Each step shows what it found, what it will do, and runs it.
struct WrapperSetupView: View {
    static let windowID = "wrapper-setup"

    @Environment(AppModel.self) private var model
    @State private var showLog = false

    private var setup: WrapperSetup { model.wrapperSetup }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                architecturePicker
                VStack(spacing: 10) {
                    ForEach(WrapperSetupStep.allCases) { step in
                        StepRow(step: step, state: setup.state(step), isNext: setup.nextStep == step,
                                isRunning: setup.running == step, isBusy: setup.isBusy,
                                progress: step == .build ? setup.buildProgress : nil,
                                startedAt: step == .build ? setup.buildStartedAt : nil) {
                            act(step)
                        }
                    }
                }
                logSection
                footer
            }
            .padding(24)
        }
        .background(AmbientBackground(palette: .fallback))
        .task { await setup.refresh(session: model.settings.session) }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(.brandGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installer le wrapper").font(.title.bold())
                    Text("Le service de gamdl qui débloque l'ALAC").foregroundStyle(.secondary)
                }
                Spacer()
                if setup.isComplete {
                    Label("Prêt", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                }
            }
            Text("Avec le seul fichier de cookies, Apple refuse la licence de l'ALAC. wrapper-v2 tourne dans Docker sur ce Mac, avec ton propre paquet Apple Music, et gamdl lui demande les clés. L'assistant installe chaque étape et vérifie le résultat. Le Dolby Atmos et l'audio spatial marchent déjà avec le fichier de cookies (mesuré avec gamdl 4.1.2) : seul l'ALAC a besoin du wrapper.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    Task { await setup.installAll(settings: model.settings, gamdl: model.report?.gamdl.path) ; await afterChange() }
                } label: {
                    Label(setup.isComplete ? "Tout est installé" : "Tout installer", systemImage: "wand.and.stars")
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .disabled(setup.isBusy || setup.isComplete)

                Button { Task { await setup.refresh(session: model.settings.session); await afterChange() } } label: {
                    Label("Vérifier", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(setup.isBusy || setup.isRefreshing)

                if setup.isBusy {
                    Button(role: .cancel) { setup.cancel() } label: { Label("Arrêter", systemImage: "stop.fill") }
                        .buttonStyle(.glass)
                }
                if setup.isRefreshing { ProgressView().controlSize(.small) }
            }
        }
    }

    private var architecturePicker: some View {
        @Bindable var setup = setup
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Architecture de l'image", selection: $setup.architecture) {
                ForEach(WrapperArchitecture.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(setup.isBusy)
            Text(setup.architecture.note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(padding: 14)
    }

    private var logSection: some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(setup.log.isEmpty ? String(localized: "Rien pour l'instant.") : setup.log)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .frame(height: 200)
                .onChange(of: setup.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
        } label: {
            Label("Journal", systemImage: "text.alignleft").font(.headline)
        }
        .glassCard(padding: 14)
        .onChange(of: setup.isBusy) { if setup.isBusy { showLog = true } }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gamdl Studio ne télécharge jamais le paquet Apple Music : fournis le tien (3.6.0-beta, build 1109). L'image construite contient des bibliothèques d'Apple : garde-la privée. Le wrapper écoute seulement sur 127.0.0.1 ; ne l'expose pas sur Internet. Ne lance pas « docker compose down -v » : ça efface la session et l'identité de l'appareil. wrapper-v2 vise un hôte Linux : cet assistant passe par la VM Linux de Colima ou de Docker Desktop, un chemin que wrapper-v2 n'a pas validé.")
            Link("wrapper-v2 sur GitHub", destination: URL(string: "https://github.com/glomatico/wrapper-v2")!)
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func act(_ step: WrapperSetupStep) {
        if step == .package {
            choosePackage()
            return
        }
        Task {
            await setup.perform(step, settings: model.settings, gamdl: model.report?.gamdl.path)
            await afterChange()
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Ton paquet Apple Music (build 1109)")
        panel.allowedContentTypes = ["apk", "apkm"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = setup.choosePackage(url)
    }

    /// The download screen and Diagnostics read the wrapper state from the report.
    private func afterChange() async {
        await model.runDiagnostics()
    }
}

private struct StepRow: View {
    let step: WrapperSetupStep
    let state: WrapperStepState
    let isNext: Bool
    let isRunning: Bool
    let isBusy: Bool
    var progress: BuildKitProgress?
    var startedAt: Date?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator.frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Label(step.title, systemImage: step.symbol).font(.headline)
                if isRunning, let progress {
                    BuildProgressView(progress: progress, startedAt: startedAt)
                }
                if !state.message.isEmpty {
                    Text(state.message)
                        .font(.callout)
                        .foregroundStyle(color == .red || color == .orange ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !state.isDone || step == .package || step == .build {
                let title = switch (step, state.isDone) {
                case (.package, true): String(localized: "Changer…")
                case (.build, true): String(localized: "Reconstruire")
                default: step.actionTitle
                }
                Group {
                    if isNext {
                        Button(title, action: action).buttonStyle(.glassProminent).tint(.brand)
                    } else {
                        Button(title, action: action).buttonStyle(.glass)
                    }
                }
                .disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 16, padding: 14, tint: isNext && !state.isDone ? .brand : nil)
    }

    private var color: Color {
        switch state {
        case .done: .green
        case .failed: .orange
        case .todo, .unknown: .secondary
        }
    }

    @ViewBuilder private var indicator: some View {
        if isRunning {
            ProgressView().controlSize(.small)
        } else {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            case .todo: Text("\(step.rawValue + 1)").font(.callout.bold()).frame(width: 22, height: 22)
                    .background(.brand.opacity(isNext ? 0.35 : 0.15), in: .circle)
            case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary).font(.title3)
            }
        }
    }
}

/// Live progress of the Docker image build: a bar, the step count, the
/// current BuildKit step and the elapsed time.
struct BuildProgressView: View {
    let progress: BuildKitProgress
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressCapsule(value: progress.fraction, isActive: true)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if progress.total > 0 {
                    Text("Étape \(progress.finished) sur \(progress.total) · \(Int(progress.fraction * 100)) %")
                        .monospacedDigit()
                } else {
                    Text("Préparation de la construction…")
                }
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let current = progress.current {
                Text(verbatim: current)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.top, 4)
    }
}

/// The big button under the codec picker: activate the wrapper already
/// running here, or install / connect it through the assistant.
struct WrapperActionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var working = false

    var body: some View {
        if let action = model.wrapperAction {
            Button {
                if action == .activate {
                    working = true
                    Task { await model.activateLocalWrapper(); working = false }
                } else {
                    openWindow(id: WrapperSetupView.windowID)
                }
            } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) } else { Image(systemName: action.symbol) }
                    Text(action.title).fontWeight(.semibold)
                }
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
            .controlSize(.large)
            .disabled(working)
            .padding(.vertical, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

/// Opens the assistant: a button for Diagnostics, Settings and the ALAC notes.
struct WrapperSetupButton: View {
    var title: LocalizedStringKey = "Assistant d'installation du wrapper…"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: WrapperSetupView.windowID) } label: {
            Label(title, systemImage: "wand.and.stars")
        }
    }
}

#Preview {
    // Isolated defaults: a preview must never rewrite the real settings.
    WrapperSetupView()
        .environment(AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "gamdlstudio.preview")!)))
        .frame(width: 720, height: 900)
}

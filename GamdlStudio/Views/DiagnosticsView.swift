import SwiftUI
import UniformTypeIdentifiers

/// Checks the setup (required tools, Apple Music cookies, output folder) and
/// offers a fix for each problem.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var importError: String?
    @State private var dropTargeted = false
    @State private var upgrade: UpgradeSession?

    var body: some View {
        ZStack {
            AmbientBackground(palette: statusPalette, intensity: 0.7)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let report = model.report {
                        summary(report)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                            toolCard(report.gamdl, symbol: "arrow.down.app", help: "pipx install gamdl") {
                                if report.pipx.isAvailable {
                                    Button {
                                        upgrade = UpgradeSession(pipx: report.pipx.path!)
                                    } label: { Label("Mettre à jour", systemImage: "arrow.triangle.2.circlepath") }
                                    .buttonStyle(.glass)
                                }
                            }
                            toolCard(report.ffmpeg, symbol: "film.stack", help: "brew install ffmpeg") { EmptyView() }
                        }
                        cookiesCard(report.cookies)
                        outputCard(report)
                    } else {
                        ProgressView("Vérification…").frame(maxWidth: .infinity).padding(60)
                    }
                }
                .padding(32)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 90)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
            if case .success(let url) = result { importCookies(from: url) }
        }
        .sheet(item: $upgrade) { session in
            UpgradeSheet(session: session) {
                Task { await model.runDiagnostics() }
            }
        }
    }

    private var statusPalette: ImagePalette {
        guard let report = model.report else { return .fallback }
        return report.isReady
            ? ImagePalette(colors: [.init(r: 0.2, g: 0.75, b: 0.45), .init(r: 0.1, g: 0.5, b: 0.6), .init(r: 0.3, g: 0.8, b: 0.6)])
            : ImagePalette(colors: [.init(r: 0.95, g: 0.55, b: 0.15), .init(r: 0.85, g: 0.25, b: 0.3), .init(r: 0.95, g: 0.7, b: 0.2)])
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostic").font(.system(size: 30, weight: .bold, design: .rounded))
                if let report = model.report {
                    Text("Vérifié \(Formatters.relative(report.checkedAt))").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await model.runDiagnostics() }
            } label: {
                Label("Tout vérifier", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(model.isCheckingDiagnostics)
        }
    }

    private func summary(_ report: DiagnosticReport) -> some View {
        HStack(spacing: 18) {
            Image(systemName: report.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(report.isReady ? .green : .orange)
                .symbolEffect(.bounce, value: report.checkedAt)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.isReady ? "Prêt à télécharger" : "Il reste à régler")
                    .font(.title2.bold())
                Text(report.isReady ? "gamdl, ffmpeg et ta session Apple Music sont opérationnels."
                                    : report.problems.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .glassCard(radius: 24, tint: report.isReady ? .green : .orange)
    }

    private func toolCard<Extra: View>(_ tool: ToolCheck, symbol: String, help: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol).font(.title2).foregroundStyle(.brandGradient)
                Text(tool.name).font(.title3.bold())
                Spacer()
                statusDot(tool.isAvailable)
            }
            if let path = tool.path {
                Text(tool.version.map { "Version \($0)" } ?? "Version inconnue").font(.headline)
                Text(path.displayPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Introuvable").font(.headline).foregroundStyle(.red)
                Text("Installe-le avec : \(help)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            extra()
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .glassCard()
    }

    private func cookiesCard(_ status: CookieStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "key.fill").font(.title2).foregroundStyle(.brandGradient)
                Text("Session Apple Music").font(.title3.bold())
                Spacer()
                statusDot(status.isUsable)
            }
            Text(status.title).font(.headline)
            Text(status.message).foregroundStyle(.secondary)
            if case .valid(_, let expires?) = status {
                let days = Calendar.current.dateComponents([.day], from: .now, to: expires).day ?? 0
                ProgressCapsule(value: min(Double(days) / 365, 1), isActive: false, height: 6,
                                tint: AnyShapeStyle(days < 14 ? Color.orange : Color.green))
                Text(days < 14 ? "Expire dans \(days) jours : pense à réexporter les cookies." : "Encore \(days) jours de validité.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.settings.cookiesURL.displayPath).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)

            if !status.isUsable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pour (re)générer le fichier").sectionLabel()
                    step(1, "Ouvre music.apple.com et connecte-toi (abonnement actif).")
                    step(2, "Installe l'extension « Get cookies.txt LOCALLY » (Chrome) ou « Export Cookies » (Firefox).")
                    step(3, "Sur l'onglet music.apple.com, exporte les cookies au format Netscape.")
                    step(4, "Dépose le fichier ci-dessous : seuls les cookies Apple sont conservés.")
                }
                .padding(.top, 4)
            }

            dropZone
            if let importError {
                Label(importError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button { importing = true } label: { Label("Importer un cookies.txt…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.glass)
                Button { NSWorkspace.shared.open(URL(string: "https://music.apple.com")!) } label: {
                    Label("Ouvrir music.apple.com", systemImage: "safari")
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(dropTargeted ? Color.brand : Color.secondary.opacity(0.5))
            .background(dropTargeted ? Color.brand.opacity(0.08) : .clear, in: .rect(cornerRadius: 14))
            .frame(height: 70)
            .overlay {
                Label("Dépose ici un export cookies.txt", systemImage: "doc.badge.arrow.up")
                    .foregroundStyle(dropTargeted ? Color.brand : .secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in importCookies(from: url) }
                }
                return true
            }
            .animation(.snappy, value: dropTargeted)
    }

    private func outputCard(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.brandGradient)
                Text("Dossier de sortie").font(.title3.bold())
                Spacer()
                statusDot(report.outputWritable)
            }
            Text(model.settings.outputURL.displayPath).font(.callout.monospaced()).textSelection(.enabled)
            HStack(spacing: 14) {
                if let free = report.freeSpace { Label("\(Formatters.bytes(free)) libres", systemImage: "chart.pie") }
                Label("\(Formatters.count(model.library.albums.count, "album")), \(Formatters.bytes(model.library.totalSize))", systemImage: "music.note.list")
                if !report.outputExists { Label("Sera créé au premier téléchargement", systemImage: "plus.circle") }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.reveal(model.settings.outputURL) } label: { Label("Afficher", systemImage: "folder") }
                    .buttonStyle(.glass)
                SettingsLink { Label("Changer…", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.bold()).frame(width: 18, height: 18).background(.brand.opacity(0.2), in: .circle)
            Text(text).font(.callout)
        }
    }

    private func statusDot(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(ok ? .green : .red)
    }

    private func importCookies(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let status = try CookieInspector.install(from: url, to: model.settings.cookiesURL)
            importError = nil
            model.show(.init(symbol: "key.fill", message: "Cookies installés · \(status.title)"))
            Task { await model.runDiagnostics() }
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - gamdl upgrade

struct UpgradeSession: Identifiable {
    let id = UUID()
    let pipx: URL
}

/// Runs `pipx upgrade gamdl` and streams its output.
private struct UpgradeSheet: View {
    let session: UpgradeSession
    var onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var result: ProcessResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(.brandGradient)
                Text("Mise à jour de gamdl").font(.title2.bold())
                Spacer()
                if result == nil { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(output.isEmpty ? "pipx upgrade gamdl…" : output)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(.black.opacity(0.3), in: .rect(cornerRadius: 12))
            HStack {
                if let result {
                    Label(result.succeeded ? "Terminé" : "Échec (code \(result.exitCode))",
                          systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                }
                Spacer()
                Button(result == nil ? "Patienter…" : "Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil)
            }
        }
        .padding(24)
        .frame(width: 560, height: 380)
        .task {
            let locator = ToolLocator.standard
            let runner = ProcessRunner()
            let r = try? await runner.run(executable: session.pipx, arguments: ["upgrade", "gamdl"], environment: locator.environment()) { text in
                Task { @MainActor in output += TextPatterns.stripANSI(text) }
            }
            result = r ?? ProcessResult(exitCode: -1, wasCancelled: false)
            onFinish()
        }
    }
}

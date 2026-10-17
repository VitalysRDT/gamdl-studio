import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var palette = ImagePalette.fallback

    var body: some View {
        let queue = model.queue
        ZStack {
            AmbientBackground(palette: palette, intensity: 0.85)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    if queue.jobs.isEmpty && queue.history.isEmpty {
                        ContentUnavailableView {
                            Label("Rien en cours", systemImage: "tray")
                        } description: {
                            Text("Les téléchargements lancés apparaîtront ici, avec leur progression piste par piste.")
                        } actions: {
                            Button("Coller un lien") { model.pasteFromClipboard() }
                                .buttonStyle(.glassProminent).tint(.brand)
                        }
                        .padding(.top, 80)
                    }

                    ForEach(queue.active) { job in
                        ActiveJobCard(job: job)
                            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                    }

                    if !queue.queued.isEmpty {
                        section("En attente · \(queue.queued.count)") {
                            ForEach(queue.queued) { job in JobRow(job: job) }
                        }
                    }

                    if !queue.finished.isEmpty {
                        section("Terminés") {
                            ForEach(queue.finished) { job in JobRow(job: job) }
                        }
                    }

                    if !queue.history.isEmpty {
                        HistorySection()
                    }
                }
                .padding(32)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 90)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: queue.jobs.map(\.state))
            }
        }
        .readPalette(from: queue.active.first?.preview?.artworkURL, into: $palette)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File d'attente").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if model.queue.pendingCount > 0 {
                Button(role: .destructive) { model.queue.cancelAll() } label: {
                    Label("Tout annuler", systemImage: "stop.circle")
                }
                .buttonStyle(.glass)
            }
            if !model.queue.finished.isEmpty {
                Button { withAnimation { model.queue.clearFinished() } } label: {
                    Label("Vider les terminés", systemImage: "checkmark.circle")
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var subtitle: String {
        let q = model.queue
        if let job = q.active.first {
            let current = String(localized: "En cours : \(job.title)")
            return q.queued.isEmpty ? current : current + " · " + String(localized: "\(q.queued.count) en attente")
        }
        return q.queued.isEmpty ? String(localized: "Aucun téléchargement en cours") : String(localized: "\(q.queued.count) en attente")
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionLabel()
            VStack(spacing: 8) { content() }
        }
    }
}

// MARK: - Active job

private struct ActiveJobCard: View {
    @Environment(AppModel.self) private var model
    let job: DownloadJob
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 22) {
                ArtworkView(source: job.preview?.artworkURL, size: 150, cornerRadius: 14, maxPixel: 500, symbol: job.link.kind.symbol)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.brand)
                            .symbolEffect(.pulse, options: .repeating)
                            .offset(x: 8, y: 8)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Pill(text: job.link.kind.label, symbol: job.link.kind.symbol, color: .brand)
                    Text(job.title).font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(2)
                    if let artist = job.subtitle { Text(artist).font(.title3).foregroundStyle(.brandGradient) }

                    Spacer(minLength: 6)

                    HStack(alignment: .firstTextBaseline) {
                        Group {
                            if let title = job.currentTrackTitle {
                                Text("\(trackLabel) \(Text("—").foregroundStyle(.tertiary)) \(title)")
                            } else {
                                Text("Connexion à Apple Music…")
                            }
                        }
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        Spacer()
                        Text("\(Int(job.overallFraction * 100)) %")
                            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: job.overallFraction))
                            .animation(.snappy, value: Int(job.overallFraction * 100))
                    }
                    ProgressCapsule(value: job.overallFraction, isActive: true, height: 10)
                    HStack(spacing: 16) {
                        if let speed = job.speed { stat("speedometer", speed) }
                        if let eta = job.eta { stat("clock", String(localized: "reste \(eta)")) }
                        if let size = job.size { stat("internaldrive", size) }
                        if let elapsed = job.elapsed { stat("timer", Formatters.duration(seconds: elapsed)) }
                        Spacer()
                        Button { showLog.toggle() } label: {
                            Label(showLog ? String(localized: "Masquer le journal") : String(localized: "Journal"), systemImage: "terminal")
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) { model.queue.cancel(job) } label: {
                            Label("Annuler", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.glass)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if !job.tracks.isEmpty {
                TrackTimeline(tracks: job.tracks, total: job.trackTotal)
            }

            if showLog {
                LogConsole(job: job).frame(height: 220)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .glassCard(radius: 28, padding: 24)
        .animation(.snappy, value: showLog)
    }

    private var trackLabel: String {
        guard let index = job.trackIndex else { return String(localized: "Piste") }
        if let total = job.trackTotal { return String(localized: "Piste \(index)/\(total)") }
        return String(localized: "Piste \(index)")
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).monospacedDigit()
    }
}

/// Tracks seen in gamdl's output, newest at the bottom.
private struct TrackTimeline: View {
    let tracks: [JobTrack]
    let total: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pistes").sectionLabel()
                Spacer()
                Text(verbatim: counts).font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(tracks) { track in
                            HStack(spacing: 10) {
                                icon(track.status).frame(width: 18)
                                Text(track.index.map { String($0) } ?? "·")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(track.title).lineLimit(1)
                                Spacer()
                                if case .skipped(let reason) = track.status {
                                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .font(.callout)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(track.status == .downloading ? Color.brand.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
                            .id(track.id)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .onChange(of: tracks.count) {
                    withAnimation { proxy.scrollTo(tracks.last?.id, anchor: .bottom) }
                }
            }
        }
    }

    private var counts: String {
        let done = tracks.filter { $0.status == .done }.count
        let skipped = tracks.filter { if case .skipped = $0.status { true } else { false } }.count
        var parts = [String(localized: "\(done) terminées")]
        if skipped > 0 { parts.append(String(localized: "\(skipped) ignorées")) }
        if let total { parts.append(String(localized: "sur \(total)")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func icon(_ status: JobTrack.Status) -> some View {
        switch status {
        case .downloading: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "arrow.uturn.right.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// Raw gamdl log, auto-scrolling and selectable.
struct LogConsole: View {
    let job: DownloadJob

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Journal gamdl").sectionLabel()
                Spacer()
                if let command = job.commandLine {
                    Button("Copier la commande") { copy(command) }.buttonStyle(.borderless)
                }
                Button("Copier le journal") { copy(job.logText) }.buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(job.log) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(line.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: job.log.count) { proxy.scrollTo(job.log.last?.id, anchor: .bottom) }
                .onAppear { proxy.scrollTo(job.log.last?.id, anchor: .bottom) }
            }
        }
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .debug: .secondary
        case .info: .primary
        case .plain: .secondary
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Compact rows

private struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: DownloadJob
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ArtworkView(source: job.preview?.artworkURL, size: 52, cornerRadius: 9, maxPixel: 160, symbol: job.link.kind.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(job.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Pill(text: job.link.kind.label, color: .secondary)
                    }
                    statusLine
                }
                Spacer()
                actions
            }
            if showLog { LogConsole(job: job).frame(height: 180) }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch job.state {
        case .queued:
            Label("En attente", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .running:
            ProgressCapsule(value: job.overallFraction, height: 5).frame(width: 200)
        case .completed(let errors):
            Label(HistoryEntry(job: job)?.summary ?? String(localized: "Terminé"), systemImage: errors > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(errors > 0 ? .orange : .green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Label("Annulé", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .queued:
                iconButton("arrow.up", "Monter dans la file") { model.queue.moveUp(job) }
                iconButton("xmark", "Retirer") { model.queue.cancel(job) }
            case .running:
                iconButton("xmark", "Annuler") { model.queue.cancel(job) }
            default:
                if let folder = job.resultFolders.first {
                    iconButton("play.fill", "Écouter") {
                        if let album = model.library.album(at: folder), let first = album.tracks.first {
                            model.player.play(first, in: album)
                        }
                    }
                    iconButton("folder", "Afficher dans le Finder") { model.reveal(folder) }
                }
                if job.state != .completed(errors: 0) {
                    iconButton("arrow.clockwise", "Réessayer") { model.queue.retry(job) }
                }
                iconButton("terminal", "Journal") { withAnimation(.snappy) { showLog.toggle() } }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .help(help)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copier le lien") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.link.absoluteString, forType: .string)
        }
        Button("Ouvrir dans Apple Music") { NSWorkspace.shared.open(job.link.url) }
        if job.state.isFinished {
            Divider()
            Button("Réessayer") { model.queue.retry(job) }
            Button("Retirer de la liste") { model.queue.remove(job) }
        }
    }
}

/// Persisted download history from previous sessions.
private struct HistorySection: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let entries = model.queue.history
        let shown = expanded ? entries : Array(entries.prefix(6))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Historique").sectionLabel()
                Spacer()
                Button("Effacer l'historique") { withAnimation { model.queue.clearHistory() } }
                    .buttonStyle(.borderless).font(.caption)
            }
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    HStack(spacing: 12) {
                        ArtworkView(source: entry.artworkURL, size: 34, cornerRadius: 6, maxPixel: 100, symbol: entry.kind.symbol)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatters.relative(entry.finishedAt)).font(.caption).foregroundStyle(.tertiary)
                        Menu {
                            Button("Télécharger à nouveau") {
                                if let link = AppleMusicLink(string: entry.url) { model.enqueue([link]) }
                            }
                            if let folder = entry.folders.first {
                                Button("Afficher dans le Finder") { model.reveal(folder) }
                            }
                            Button("Copier le lien") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.url, forType: .string)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if entry != shown.last { Divider().padding(.leading, 60) }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
            if entries.count > 6 {
                Button(expanded ? String(localized: "Réduire") : String(localized: "Tout afficher (\(entries.count))")) { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.borderless).font(.callout)
            }
        }
    }
}

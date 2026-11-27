import SwiftUI

/// Main screen: paste a link, preview what it contains, start the download.
struct DownloadView: View {
    @Environment(AppModel.self) private var model
    @State private var palette = ImagePalette.fallback
    @State private var preview: PreviewState = .idle
    @State private var checkedCodecs: SongCodecLookup?
    @State private var catalogCodecs: [SongCodec]?
    @FocusState private var fieldFocused: Bool
    @State private var wrapperAlert: WrapperAlert?
    @Environment(\.openWindow) private var openWindow

    /// A download held back because ALAC would fail without a ready wrapper.
    struct WrapperAlert: Identifiable {
        let id = UUID()
        let gate: WrapperGate
        let all: Bool
    }

    enum PreviewState: Equatable {
        case idle, loading, loaded(MediaPreview), unavailable, failed(String)
    }

    private var links: [AppleMusicLink] { AppleMusicLink.extractAll(from: model.draftURL) }
    private var link: AppleMusicLink? { links.first }
    private var singleLink: AppleMusicLink? { links.count == 1 ? link : nil }
    private var codecLookup: SongCodecLookup? {
        SongCodecLookup(link: singleLink, settings: SettingsSnapshot(model.settings),
                        wrapperReady: model.report?.wrapper?.isReady == true)
    }
    private var checkingCodecs: Bool { codecLookup != nil && checkedCodecs != codecLookup }
    private var availableCodecs: [SongCodec]? {
        guard let lookup = codecLookup, checkedCodecs == lookup else { return nil }
        return catalogCodecs?.filter { !$0.needsWrapper || model.settings.session.authMode == .wrapper }
    }
    private var options: DownloadOptions { model.settings.options.selectingAvailableCodecs(availableCodecs) }
    private var canStart: Bool {
        guard link?.kind.isDownloadable == true else { return false }
        if options.lyricsMode == .lyricsOnly { return true }
        return !checkingCodecs && !(singleLink?.kind == .song && availableCodecs?.isEmpty == true)
    }

    private var loadedPreview: MediaPreview? {
        if case .loaded(let p) = preview { return p }
        return nil
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            AmbientBackground(palette: palette)

            ScrollView {
                VStack(spacing: 26) {
                    header
                    urlField
                    if let suggestion = model.clipboardSuggestion { clipboardBanner(suggestion) }
                    if links.count > 1 { multiLinkBanner }
                    content
                    if let singleLink {
                        OptionsPanel(kind: singleLink.kind, codecs: availableCodecs,
                                     checking: checkingCodecs, options: options)
                    }
                    if link != nil, links.count == 1 { downloadButton }
                    RecentStrip()
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .readPalette(from: loadedPreview?.artworkURL, into: $palette)
        .task(id: singleLink) { await loadPreview() }
        .task(id: codecLookup) {
            let request = codecLookup
            checkedCodecs = nil
            catalogCodecs = nil
            guard let request else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let codecs = await request.fetch()
            guard !Task.isCancelled, codecLookup == request else { return }
            catalogCodecs = codecs
            checkedCodecs = request
        }
        .onAppear { fieldFocused = model.draftURL.isEmpty }
        .navigationTitle("")
        .alert(Text(verbatim: wrapperAlert?.gate.title ?? ""), isPresented: Binding(
            get: { wrapperAlert != nil }, set: { if !$0 { wrapperAlert = nil } }
        ), presenting: wrapperAlert) { pending in
            Button(pending.gate == .wrapperNotActivated ? "Installer et activer le wrapper…" : "Ouvrir l'assistant du wrapper…") {
                openWindow(id: WrapperSetupView.windowID)
            }
            if pending.gate.isBlocking {
                Button("Télécharger quand même") { enqueue(all: pending.all) }
            } else {
                Button("Télécharger avec les cookies") { enqueue(all: pending.all) }
                Button("Ne plus prévenir pour l'audio spatial") {
                    model.settings.warnSpatialWithoutWrapper = false
                    enqueue(all: pending.all)
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { pending in
            Text(pending.gate.message)
        }
    }

    // MARK: - Header and link field

    private var header: some View {
        VStack(spacing: 8) {
            Text("Que veux-tu écouter ?")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Colle un lien Apple Music : morceau, album, playlist ou artiste.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var urlField: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: link.map { $0.kind.symbol } ?? "link")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(link == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.brandGradient))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)

            TextField("https://music.apple.com/fr/album/…", text: $model.draftURL)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit(startDownload)

            if !model.draftURL.isEmpty {
                Button {
                    model.draftURL = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Effacer")
            }

            Button {
                model.pasteFromClipboard()
            } label: {
                Label("Coller", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help("Coller le lien du presse-papiers (⇧⌘V)")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(height: 56)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay {
            Capsule().strokeBorder(invalidInput ? Color.orange.opacity(0.6) : .clear, lineWidth: 1)
        }
        .animation(.snappy, value: invalidInput)
    }

    private var invalidInput: Bool { !model.draftURL.trimmed.isEmpty && link == nil }

    private func clipboardBanner(_ suggestion: AppleMusicLink) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(.brandGradient)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(suggestion.kind.label) copié dans le presse-papiers").font(.callout.weight(.semibold))
                Text(suggestion.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Ignorer") { model.dismissSuggestion() }.buttonStyle(.borderless)
            Button("Utiliser") {
                model.draftURL = suggestion.absoluteString
                model.clipboardSuggestion = nil
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
        }
        .glassCard(radius: 18, padding: 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var multiLinkBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.title2).foregroundStyle(.brandGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(links.count) liens détectés").font(.headline)
                Text(verbatim: Dictionary(grouping: links, by: \.kind).map { "\($0.value.count) \($0.key.label.lowercased())" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                requestDownload(all: true)
            } label: {
                Label("Tout ajouter à la file", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
            .controlSize(.large)
        }
        .glassCard()
    }

    // MARK: - Preview

    @ViewBuilder
    private var content: some View {
        if links.count > 1 {
            EmptyView()
        } else if let link {
            switch preview {
            case .idle, .loading:
                PreviewSkeleton()
            case .loaded(let p):
                PreviewCard(preview: p, link: link)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            case .unavailable, .failed:
                PreviewFallback(link: link, error: { if case .failed(let e) = preview { e } else { nil } }())
            }
        } else {
            KindHints()
        }
    }

    private func loadPreview() async {
        guard let link, links.count == 1 else { preview = .idle; return }
        preview = .loading
        // Debounce so we don't fire a request on every keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            if let p = try await model.preview(for: link) {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { preview = .loaded(p) }
            } else {
                preview = .unavailable
            }
        } catch {
            guard !Task.isCancelled else { return }
            preview = .failed(error.localizedDescription)
        }
    }

    // MARK: - Start

    private var downloadButton: some View {
        let ready = model.report?.isReady ?? true
        return VStack(spacing: 10) {
            Button(action: startDownload) {
                Label("Télécharger", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)

            if !ready, let problems = model.report?.problems, !problems.isEmpty {
                Button {
                    model.selection = .diagnostics
                } label: {
                    Label(problems.joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            } else if link?.kind == .station {
                Text("Les stations sont des flux : gamdl ne peut pas les télécharger.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("⌘↩ pour lancer · les morceaux déjà présents sont ignorés")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func startDownload() {
        guard canStart else { return }
        requestDownload(all: false)
    }

    /// Queues the download, unless the codec asks for ALAC and the wrapper
    /// is not set up: then the user is told why it would fail first.
    private func requestDownload(all: Bool) {
        let kinds = all ? links.map(\.kind) : link.map { [$0.kind] } ?? []
        guard kinds.contains(where: { $0 != .musicVideo }), let gate = model.wrapperGate(for: options) else {
            enqueue(all: all)
            return
        }
        guard case .wrapperNotReady = gate else {
            wrapperAlert = WrapperAlert(gate: gate, all: all)
            return
        }
        // The last check may be stale (wrapper started or signed in since).
        let requestedLinks = links
        Task {
            await model.runDiagnostics()
            guard requestedLinks == links, canStart else { return }
            if let gate = model.wrapperGate(for: options) {
                wrapperAlert = WrapperAlert(gate: gate, all: all)
            } else {
                enqueue(all: all)
            }
        }
    }

    private func enqueue(all: Bool) {
        if all {
            model.enqueue(links)
            model.draftURL = ""
            return
        }
        guard let link, canStart else { return }
        var previews: [AppleMusicLink: MediaPreview] = [:]
        if let loadedPreview { previews[link] = loadedPreview }
        model.enqueue([link], previews: previews, options: options)
        withAnimation(.spring(response: 0.5)) {
            model.draftURL = ""
            preview = .idle
        }
    }
}

// MARK: - Preview card

private struct PreviewCard: View {
    let preview: MediaPreview
    let link: AppleMusicLink
    @State private var showAllTracks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
                ArtworkView(source: preview.artworkURL, size: 200, cornerRadius: 16, maxPixel: 600, symbol: link.kind.symbol)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Pill(text: link.kind.label, symbol: link.kind.symbol, color: .brand)
                        if preview.isExplicit { Pill(text: String(localized: "Explicite"), symbol: "e.square.fill") }
                        if let storefront = link.storefront { Pill(text: storefront.uppercased(), symbol: "globe") }
                    }
                    Text(preview.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if let artist = preview.artist {
                        Text(artist).font(.title3.weight(.medium)).foregroundStyle(.brandGradient)
                    }
                    if let album = preview.album {
                        Label(album, systemImage: "square.stack").font(.callout).foregroundStyle(.secondary)
                    }
                    Text(preview.summary).font(.callout).foregroundStyle(.secondary)
                    if link.kind == .artist {
                        Label("Choisis plus bas ce qu'il faut prendre dans la discographie.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if !preview.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pistes").sectionLabel().padding(.bottom, 8)
                    let shown = showAllTracks ? preview.tracks : Array(preview.tracks.prefix(8))
                    let multiDisc = Set(preview.tracks.map(\.disc)).count > 1
                    ForEach(shown) { track in
                        HStack(spacing: 12) {
                            Text(verbatim: multiDisc ? "\(track.disc)-\(track.number)" : "\(track.number)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .trailing)
                            Text(track.title).lineLimit(1)
                            if track.isExplicit {
                                Image(systemName: "e.square.fill").foregroundStyle(.secondary).imageScale(.small)
                            }
                            Spacer()
                            if let ms = track.durationMs {
                                Text(Formatters.duration(milliseconds: ms))
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider().opacity(track == shown.last ? 0 : 0.5)
                    }
                    if preview.tracks.count > 8 {
                        Button(showAllTracks ? String(localized: "Réduire") : String(localized: "Afficher les \(preview.tracks.count) pistes")) {
                            withAnimation(.snappy) { showAllTracks.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .glassCard(radius: 26, padding: 24)
    }
}

private struct PreviewSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.primary.opacity(0.08)).frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(.primary.opacity(0.08)).frame(width: 90, height: 18)
                Capsule().fill(.primary.opacity(0.1)).frame(width: 320, height: 28)
                Capsule().fill(.primary.opacity(0.08)).frame(width: 180, height: 20)
                Capsule().fill(.primary.opacity(0.06)).frame(width: 240, height: 14)
            }
            Spacer()
        }
        .shimmering()
        .glassCard(radius: 26, padding: 24)
    }
}

private struct PreviewFallback: View {
    let link: AppleMusicLink
    let error: String?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: link.kind.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.brandGradient)
                .frame(width: 72, height: 72)
                .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(link.kind.label) Apple Music").font(.title3.weight(.semibold))
                (error.map { Text("Aperçu indisponible (\($0)). Le téléchargement reste possible.") }
                     ?? Text("Pas d'aperçu public pour ce lien. Le téléchargement reste possible."))
                    .font(.callout).foregroundStyle(.secondary)
                Text(link.absoluteString).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .glassCard()
    }
}

/// Empty state: what kinds of links work, plus a drag-and-drop hint.
private struct KindHints: View {
    private let kinds: [AppleMusicLink.Kind] = [.song, .album, .playlist, .artist, .musicVideo]

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ForEach(kinds, id: \.self) { kind in
                    VStack(spacing: 8) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.brandGradient)
                            .frame(width: 52, height: 52)
                            .glassEffect(.regular, in: .circle)
                        Text(kind.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Label("Tu peux aussi glisser un ou plusieurs liens n'importe où dans la fenêtre.", systemImage: "hand.draw")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }
}

/// Download options, saved as the new defaults.
private struct OptionsPanel: View {
    @Environment(AppModel.self) private var model
    let kind: AppleMusicLink.Kind
    let codecs: [SongCodec]?
    let checking: Bool
    let options: DownloadOptions

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            Text("Réglages").sectionLabel()
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                if [.song, .album, .playlist, .artist].contains(kind) {
                    GridRow {
                        Text("Qualité").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            if checking {
                                ProgressView("Recherche des codecs disponibles…").controlSize(.small)
                            } else if let codecs, !codecs.isEmpty {
                                Picker("Qualité", selection: Binding(get: { options.codec }, set: { settings.options.codec = $0 })) {
                                    CodecMenuItems(codecs: codecs) { $0 }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 260)
                                Text(options.codec.detail).font(.caption).foregroundStyle(.secondary)
                                if kind != .song {
                                    Text("Formats communs aux morceaux disponibles.").font(.caption).foregroundStyle(.secondary)
                                }
                                WrapperActionButton(options: options)
                            } else if kind == .artist || (kind != .song && codecs != nil) {
                                Text("Qualité par piste selon les priorités des réglages.").foregroundStyle(.secondary)
                            } else if codecs != nil {
                                Text("Aucun codec confirmé pour ce morceau avec cette configuration.").foregroundStyle(.secondary)
                            } else {
                                Text("Aucun codec confirmé. Les priorités des réglages s’appliquent.").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Paroles").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Picker("", selection: $settings.options.lyricsMode) {
                                ForEach(LyricsMode.choices(for: model.report?.generation, keeping: settings.options.lyricsMode)) {
                                    Text($0.label).tag($0)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Picker("", selection: $settings.options.lyricsFormat) {
                                ForEach(LyricsFormat.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 90)
                            .disabled(settings.options.lyricsMode == .none)
                        }
                        if settings.options.lyricsMode.isUnsupported(by: model.report?.generation) {
                            Text(GamdlCommandError.lyricsOnlyUnsupported.localizedDescription)
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    Text("Pochette").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Picker("", selection: $settings.options.coverSize) {
                            ForEach(CoverSize.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Toggle("Enregistrer aussi la pochette à part", isOn: $settings.options.saveCover)
                    }
                }
                if kind == .artist {
                    GridRow {
                        Text("Discographie").foregroundStyle(.secondary)
                        Menu(settings.options.artistSelections.map(\.label).joined(separator: ", ")) {
                            ForEach(ArtistSelection.allCases) { selection in
                                Toggle(selection.label, isOn: Binding(
                                    get: { settings.options.includesArtist(selection) },
                                    set: { settings.options.setArtist(selection, included: $0) }
                                ))
                            }
                        }
                        .frame(width: 260)
                    }
                }
                GridRow {
                    Text("Existants").foregroundStyle(.secondary)
                    Toggle("Réécrire les fichiers déjà téléchargés", isOn: $settings.options.overwrite)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// Strip of recent downloads shown under the button.
private struct RecentStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = Array(model.queue.history.filter { $0.outcome == .completed }.prefix(10))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Derniers téléchargements").sectionLabel()
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(entries) { entry in
                            Button {
                                if let folder = entry.folders.first { model.reveal(folder) }
                                else { model.selection = .library }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkView(source: entry.artworkURL, size: 110, cornerRadius: 12, maxPixel: 300, symbol: entry.kind.symbol)
                                    Text(entry.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(Formatters.relative(entry.finishedAt)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(width: 110)
                            }
                            .buttonStyle(.plain)
                            .hoverLift(scale: 1.04)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }
}

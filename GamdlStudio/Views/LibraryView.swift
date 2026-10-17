import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sort: LibrarySort = .recent
    @State private var filter: Filter = .all
    @State private var tileSize: Double = 180
    @State private var selected: LibraryAlbum?
    @State private var palette = ImagePalette.fallback

    enum Filter: String, CaseIterable, Identifiable {
        case all, albums, compilations
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "Tout"
            case .albums: "Albums"
            case .compilations: "Compilations"
            }
        }
    }

    private var albums: [LibraryAlbum] {
        let base = model.library.albums.filter { album in
            switch filter {
            case .all: true
            case .albums: album.category == .album
            case .compilations: album.category == .compilation
            }
        }
        return sort.sort(base.filter { $0.matches(query) })
    }

    var body: some View {
        ZStack {
            AmbientBackground(palette: palette, intensity: 0.6, animated: false)

            if let selected {
                AlbumDetailView(album: selected) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { self.selected = nil }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                grid.transition(.opacity)
            }
        }
        .readPalette(from: selected?.artworkSource ?? model.library.recent(1).first?.artworkSource, into: $palette)
        .searchable(text: $query, placement: .toolbar, prompt: "Titre, artiste, album…")
        .toolbar {
            ToolbarItemGroup {
                Picker("Afficher", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Trier", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    model.library.refresh(root: model.settings.outputURL)
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .help("Relire le dossier (⌘R)")

                Button {
                    model.reveal(model.settings.outputURL)
                } label: {
                    Label("Ouvrir le dossier", systemImage: "folder")
                }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if model.library.albums.isEmpty && !model.library.isScanning {
                    ContentUnavailableView {
                        Label("Bibliothèque vide", systemImage: "music.note.house")
                    } description: {
                        Text("Rien dans \(model.settings.outputURL.displayPath).")
                    } actions: {
                        Button("Télécharger quelque chose") { model.selection = .download }
                            .buttonStyle(.glassProminent).tint(.brand)
                    }
                    .padding(.top, 60)
                } else {
                    if query.isEmpty && sort != .recent && filter == .all {
                        recentRow
                    }
                    if albums.isEmpty && !query.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.35), spacing: 22, alignment: .top)], spacing: 26) {
                        ForEach(albums) { album in
                            AlbumTile(album: album) { open(album) }
                        }
                    }
                }
            }
            .padding(32)
            .padding(.bottom, 90)
        }
        .overlay(alignment: .bottomTrailing) {
            Slider(value: $tileSize, in: 130...260) {
                Image(systemName: "square.grid.3x3")
            }
            .controlSize(.mini)
            .frame(width: 140)
            .padding(10)
            .glassEffect(.regular, in: .capsule)
            .padding(18)
            .opacity(model.player.current == nil ? 1 : 0)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bibliothèque").font(.system(size: 30, weight: .bold, design: .rounded))
                Group {
                    if model.library.isScanning && model.library.albums.isEmpty {
                        Text("Lecture du dossier…")
                    } else {
                        Text("\(Formatters.count(model.library.albums.count, "album")) · \(Formatters.count(model.library.trackCount, "titre")) · \(Formatters.bytes(model.library.totalSize))")
                    }
                }
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }
            Spacer()
            if model.library.isScanning { ProgressView().controlSize(.small) }
        }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajouts récents").sectionLabel()
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(model.library.recent(12)) { album in
                        AlbumTile(album: album, width: 140) { open(album) }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func open(_ album: LibraryAlbum) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { selected = album }
    }
}

private struct AlbumTile: View {
    @Environment(AppModel.self) private var model
    let album: LibraryAlbum
    var width: CGFloat? = nil
    var onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(source: album.artworkSource, size: width, cornerRadius: 12, maxPixel: 420)
                .overlay(alignment: .bottomTrailing) {
                    if hovering, let first = album.tracks.first {
                        Button {
                            model.player.play(first, in: album)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .tint(.brand)
                        .padding(10)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
                .scaleEffect(hovering ? 1.025 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(album.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(.rect)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .onTapGesture(perform: onOpen)
        .accessibilityAction(.default, onOpen)
        .contextMenu {
            Button("Ouvrir") { onOpen() }
            if let first = album.tracks.first {
                Button("Lire") { model.player.play(first, in: album) }
            }
            Button("Afficher dans le Finder") { model.reveal(album.folder) }
            Button("Ouvrir dans Musique") { model.openInMusic(album.tracks.map(\.url)) }
            Divider()
            Button("Copier le chemin") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(album.folder.path, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Album detail

private struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: LibraryAlbum
    var onClose: () -> Void
    @State private var lyricsTrack: LibraryTrack?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button(action: onClose) {
                    Label("Bibliothèque", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.escape, modifiers: [])

                HStack(alignment: .bottom, spacing: 28) {
                    ArtworkView(source: album.artworkSource, size: 240, cornerRadius: 18, maxPixel: 800)
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
                    VStack(alignment: .leading, spacing: 10) {
                        Pill(text: album.category == .compilation ? "Compilation" : "Album", color: .brand)
                        Text(album.title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Text(album.subtitle).font(.title2.weight(.medium)).foregroundStyle(.brandGradient)
                        Text("\(Formatters.count(album.tracks.count, "titre")) · \(Formatters.bytes(album.totalSize)) · ajouté \(Formatters.relative(album.modifiedAt))")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if let first = album.tracks.first {
                                Button { model.player.play(first, in: album) } label: {
                                    Label("Lire", systemImage: "play.fill").padding(.horizontal, 8)
                                }
                                .buttonStyle(.glassProminent).tint(.brand).controlSize(.large)
                            }
                            Button { model.openInMusic(album.tracks.map(\.url)) } label: {
                                Label("Ajouter à Musique", systemImage: "music.note.house")
                            }
                            .buttonStyle(.glass).controlSize(.large)
                            Button { model.reveal(album.folder) } label: {
                                Label("Finder", systemImage: "folder")
                            }
                            .buttonStyle(.glass).controlSize(.large)
                        }
                        .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: 0) {
                    ForEach(album.tracks) { track in
                        TrackRow(track: track, album: album, onLyrics: { lyricsTrack = track })
                        if track != album.tracks.last { Divider().padding(.leading, 56) }
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
            }
            .padding(32)
            .padding(.bottom, 100)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $lyricsTrack) { track in LyricsSheet(track: track) }
    }
}

private struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: LibraryTrack
    let album: LibraryAlbum
    var onLyrics: () -> Void
    @State private var hovering = false

    private var isCurrent: Bool { model.player.current == track }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if isCurrent && model.player.isPlaying {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(.brandGradient)
                } else if hovering || isCurrent {
                    Image(systemName: "play.fill").foregroundStyle(.brand)
                } else {
                    Text(track.trackNumber.map(String.init) ?? "·")
                        .font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26)

            Text(track.title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if track.isVideo { Pill(text: "Clip", symbol: "play.rectangle") }
            Spacer()
            if track.lyricsURL != nil {
                Button(action: onLyrics) { Image(systemName: "quote.bubble") }
                    .buttonStyle(.borderless)
                    .help("Afficher les paroles")
            }
            Text(Formatters.bytes(track.size)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.player.play(track, in: album) }
        .contextMenu {
            Button("Lire") { model.player.play(track, in: album) }
            Button("Afficher dans le Finder") { model.reveal(track.url) }
            Button("Ouvrir dans Musique") { model.openInMusic([track.url]) }
        }
    }
}

/// Synced lyrics (.lrc) displayed without their timestamps.
private struct LyricsSheet: View {
    let track: LibraryTrack
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Paroles").sectionLabel()
                    Text(track.title).font(.title2.bold())
                }
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(lyrics)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
    }

    private var lyrics: String {
        guard let url = track.lyricsURL, let raw = try? String(contentsOf: url, encoding: .utf8) else { return "Paroles illisibles." }
        return LyricsText.plain(fromLRC: raw)
    }
}

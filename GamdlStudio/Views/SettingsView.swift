import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralSettings() }
            Tab("Audio", systemImage: "music.note") { AudioSettings() }
            Tab("Vidéo", systemImage: "film") { VideoSettings() }
            Tab("Fichiers", systemImage: "folder") { FileSettings() }
            Tab("Session", systemImage: "person.badge.key") { SessionSettings() }
            Tab("Avancé", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 620, height: 600)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Emplacements") {
                PathField(title: "Dossier de sortie", path: $settings.outputPath, directory: true)
                PathField(title: "Fichier de cookies", path: $settings.cookiesPath, directory: false)
            }
            Section("Comportement") {
                Picker("Téléchargements simultanés", selection: $settings.maxConcurrentJobs) {
                    Text("1 (recommandé)").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                Toggle("Proposer les liens copiés dans le presse-papiers", isOn: $settings.watchClipboard)
                Toggle("Notification à la fin d'un téléchargement", isOn: $settings.notifyOnCompletion)
                Toggle("Son à la fin d'un téléchargement", isOn: $settings.playSoundOnCompletion)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.maxConcurrentJobs) { model.applySettings() }
        .onChange(of: settings.notifyOnCompletion) { model.applySettings() }
        .onChange(of: settings.playSoundOnCompletion) { model.applySettings() }
        .onChange(of: settings.cookiesPath) { Task { await model.runDiagnostics() } }
    }
}

// MARK: - Audio

private struct AudioSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let generation = model.report?.generation
        Form {
            Section {
                Picker("Codec", selection: $settings.options.codec) {
                    CodecMenuItems { $0 }
                }
                Picker("S'il n'existe pas", selection: fallback(1)) {
                    Text("Échouer").tag(SongCodec?.none)
                    CodecMenuItems { SongCodec?.some($0) }
                }
                Picker("En dernier recours", selection: fallback(2)) {
                    Text("Échouer").tag(SongCodec?.none)
                    CodecMenuItems { SongCodec?.some($0) }
                }
                .disabled(settings.options.codec(at: 1) == nil)
                Toggle("Dater les morceaux à la sortie de l'album", isOn: $settings.options.useAlbumDate)
            } header: {
                Text("Codec")
            } footer: {
                CodecNotes(options: settings.options, usesWrapper: settings.session.authMode == .wrapper)
            }

            Section {
                Picker("Paroles synchronisées", selection: $settings.options.lyricsMode) {
                    ForEach(LyricsMode.choices(for: generation, keeping: settings.options.lyricsMode)) {
                        Text($0.label).tag($0)
                    }
                }
                Picker("Format du fichier", selection: $settings.options.lyricsFormat) {
                    ForEach(LyricsFormat.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.options.lyricsMode == .none)
                Picker("Format intégré au morceau", selection: $settings.options.embeddedLyricsFormat) {
                    Text("Par défaut de gamdl").tag(LyricsFormat?.none)
                    ForEach(LyricsFormat.allCases) { Text($0.label).tag(LyricsFormat?.some($0)) }
                }
            } header: {
                Text("Paroles")
            } footer: {
                if settings.options.lyricsMode.isUnsupported(by: generation) {
                    Text(GamdlCommandError.lyricsOnlyUnsupported.localizedDescription)
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Pochette") {
                Picker("Taille intégrée", selection: $settings.options.coverSize) {
                    ForEach(CoverSize.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Enregistrer aussi la pochette à part", isOn: $settings.options.saveCover)
                Picker("Taille du fichier à part", selection: $settings.options.fileCoverSize) {
                    Text("Comme la pochette intégrée").tag(CoverSize?.none)
                    ForEach(CoverSize.allCases) { Text($0.label).tag(CoverSize?.some($0)) }
                }
                .disabled(!settings.options.saveCover)
                Picker("Format", selection: $settings.options.coverFormat) {
                    Text("Par défaut de gamdl").tag(CoverFormat?.none)
                    ForEach(CoverFormat.allCases) { Text($0.label).tag(CoverFormat?.some($0)) }
                }
            }

            Section {
                ForEach(ArtistSelection.allCases) { selection in
                    Toggle(selection.label, isOn: Binding(
                        get: { settings.options.includesArtist(selection) },
                        set: { settings.options.setArtist(selection, included: $0) }
                    ))
                }
            } header: {
                Text("Depuis une page d'artiste, prendre")
            } footer: {
                if generation == .v3 {
                    Text("gamdl 3 ne prend que la première catégorie cochée.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Créer une liste M3U pour les playlists", isOn: $settings.options.savePlaylist)
                Toggle("Réécrire les fichiers existants", isOn: $settings.options.overwrite)
            } footer: {
                Gamdl4OnlyNote()
            }
        }
        .formStyle(.grouped)
    }

    /// Fallback codec at a position of the priority list.
    private func fallback(_ index: Int) -> Binding<SongCodec?> {
        let settings = model.settings
        return Binding(
            get: { settings.options.codec(at: index) },
            set: { settings.options.setCodec($0, at: index) }
        )
    }
}

/// Codecs grouped as stereo, spatial and lossless, for a menu picker.
///
/// The tag type is fixed per picker (`SongCodec` or `SongCodec?`). Choosing it
/// with an `if` inside the ForEach hid the tags from the Picker, which then
/// wrote another codec into the settings on first display.
struct CodecMenuItems<Tag: Hashable>: View {
    let tag: (SongCodec) -> Tag

    var body: some View {
        ForEach(SongCodec.Family.allCases, id: \.self) { family in
            Section(family.label) {
                ForEach(family.codecs) { codec in
                    Text(codec.label).tag(tag(codec))
                }
            }
        }
    }
}

/// What the chosen codecs imply, as measured with gamdl 4.1.2.
struct CodecNotes: View {
    let options: DownloadOptions
    var usesWrapper = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(options.codec.detail)
            if !usesWrapper, options.songCodecPriority.contains(where: \.needsWrapper) {
                Text("L'ALAC demande le wrapper de gamdl : avec de simples cookies, Apple refuse la licence de déchiffrement.")
                    .foregroundStyle(.orange)
                WrapperSetupButton(title: "Installer et activer le wrapper…")
                    .buttonStyle(.link)
            }
            if !usesWrapper, options.songCodecPriority.contains(where: { $0.family == .spatial }) {
                Text("Dolby Atmos et audio spatial : ils sont passés avec le fichier de cookies lors des tests, mais le wrapper reste la voie sûre si Apple refuse une licence.")
                if !options.songCodecPriority.contains(where: \.needsWrapper) {
                    WrapperSetupButton(title: "Installer et activer le wrapper…")
                        .buttonStyle(.link)
                }
            }
            if options.songCodecPriority.contains(.ac3) || options.songCodecPriority.contains(.alacHiRes) {
                Text("Dolby Digital (AC-3) et ALAC Hi-Res n'ont pas encore été testés : aucun morceau essayé ne les proposait.")
            }
            if options.songCodecPriority.count == 1, options.codec.family != .stereo {
                Text("Un morceau qui n'existe pas dans ce codec échouera : choisis un codec de secours.")
            }
            Text("Pour remplacer des morceaux déjà téléchargés dans un autre codec, active « Réécrire les fichiers existants ».")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Video

private struct VideoSettings: View {
    @Environment(AppModel.self) private var model

    private static let codecOrders: [[MusicVideoCodec]] = [[], [.h264, .h265], [.h265, .h264], [.h264], [.h265]]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Codec", selection: $settings.options.musicVideoCodecPriority) {
                    ForEach(Self.codecOrders, id: \.self) { order in
                        Text(Self.label(for: order)).tag(order)
                    }
                }
                Picker("Hauteur maximale", selection: $settings.options.maxVideoHeight) {
                    Text("Par défaut de gamdl").tag(Int?.none)
                    ForEach(DownloadOptions.videoHeights, id: \.self) { height in
                        Text(verbatim: height == 2160 ? "2160p (4K)" : "\(height)p").tag(Int?.some(height))
                    }
                }
                Picker("Extension", selection: $settings.options.musicVideoContainer) {
                    Text("Par défaut de gamdl").tag(VideoContainer?.none)
                    ForEach(VideoContainer.allCases) { Text(verbatim: $0.label).tag(VideoContainer?.some($0)) }
                }
            } header: {
                Text("Clips")
            } footer: {
                Text("Au-delà de 1080p, gamdl a besoin d'un appareil Widevine L1 ou PlayReady SL3000.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Qualité", selection: $settings.options.uploadedVideoQuality) {
                    Text("Par défaut de gamdl").tag(UploadedVideoQuality?.none)
                    ForEach(UploadedVideoQuality.allCases) { Text($0.label).tag(UploadedVideoQuality?.some($0)) }
                }
            } header: {
                Text("Vidéos mises en ligne par les artistes")
            } footer: {
                Gamdl4OnlyNote()
            }
        }
        .formStyle(.grouped)
    }

    private static func label(for order: [MusicVideoCodec]) -> String {
        switch order {
        case []: String(localized: "Par défaut de gamdl")
        case [.h264]: String(localized: "H.264 seulement")
        case [.h265]: String(localized: "H.265 seulement")
        default: order.map(\.label).joined(separator: " → ")
        }
    }
}

// MARK: - Files

private struct FileSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let defaults = FileTemplates.gamdlDefaults
        Form {
            Section {
                TemplateField(title: "Dossier d'album", text: $settings.options.templates.albumFolder, placeholder: defaults.albumFolder)
                TemplateField(title: "Dossier de compilation", text: $settings.options.templates.compilationFolder, placeholder: defaults.compilationFolder)
                TemplateField(title: "Dossier hors album", text: $settings.options.templates.noAlbumFolder, placeholder: defaults.noAlbumFolder)
                TemplateField(title: "Dossier de playlist", text: $settings.options.templates.playlistFolder, placeholder: defaults.playlistFolder)
                TemplateField(title: "Morceau (un disque)", text: $settings.options.templates.singleDiscFile, placeholder: defaults.singleDiscFile)
                TemplateField(title: "Morceau (plusieurs disques)", text: $settings.options.templates.multiDiscFile, placeholder: defaults.multiDiscFile)
                TemplateField(title: "Morceau hors album", text: $settings.options.templates.noAlbumFile, placeholder: defaults.noAlbumFile)
                TemplateField(title: "Liste M3U", text: $settings.options.templates.playlistFile, placeholder: defaults.playlistFile)
                Picker("Raccourcir les noms à", selection: $settings.options.templates.truncate) {
                    Text("Par défaut de gamdl").tag(Int?.none)
                    ForEach(DownloadOptions.truncateLengths, id: \.self) { length in
                        Text("\(length) caractères").tag(Int?.some(length))
                    }
                }
            } header: {
                Text("Noms des dossiers et des fichiers")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vide : le modèle de gamdl s'applique (~/.gamdl/config.yml, sinon celui affiché).")
                    Text(verbatim: FileTemplates.variables.map { "{\($0)}" }.joined(separator: " "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Écrire les métadonnées", isOn: $settings.options.writeTags)
                DisclosureGroup("Champs à ne pas écrire (\(settings.options.excludedTags.count))") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(MetadataTags.all, id: \.self) { tag in
                            Toggle(isOn: Binding(
                                get: { settings.options.excludes(tag: tag) },
                                set: { settings.options.setTag(tag, excluded: $0) }
                            )) {
                                Text(verbatim: tag).font(.callout.monospaced())
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!settings.options.writeTags)
                TemplateField(title: "Format de la date", text: $settings.options.dateTagTemplate, placeholder: "%Y-%m-%dT%H:%M:%SZ")
                    .disabled(!settings.options.writeTags)
            } header: {
                Text("Métadonnées")
            } footer: {
                Gamdl4OnlyNote()
            }
        }
        .formStyle(.grouped)
    }
}

/// Text field whose value (not its label) is monospaced: templates, paths.
private struct TemplateField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let placeholder: String

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(verbatim: placeholder))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.callout.monospaced())
        }
    }
}

// MARK: - Session

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Connexion à Apple Music", selection: $settings.session.authMode) {
                    ForEach(AuthMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.session.authMode == .wrapper {
                    TemplateField(title: "Adresse du wrapper", text: $settings.session.wrapperURL, placeholder: GamdlSession.defaultWrapperURL)
                } else {
                    Toggle("Prévenir avant un téléchargement Dolby Atmos ou spatial sans wrapper", isOn: $settings.warnSpatialWithoutWrapper)
                }
            } header: {
                Text("Connexion")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if settings.session.authMode == .wrapper {
                        Text("Le wrapper-v2 de gamdl tourne sur un hôte Linux avec Docker (validé en x86_64, pas encore en ARM64) et un paquet Apple Music que tu fournis. Il doit être connecté à ton compte Apple : l'assistant d'installation s'occupe de Docker, de l'image et ouvre « gamdl auth » dans le Terminal. Ne l'expose pas sur Internet.")
                        HStack {
                            WrapperSetupButton()
                            Link("wrapper-v2 sur GitHub", destination: URL(string: "https://github.com/glomatico/wrapper-v2")!)
                        }
                    } else {
                        Text("Le fichier de cookies suffit pour l'AAC et le Dolby Atmos. L'ALAC demande le wrapper.")
                        WrapperSetupButton()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TemplateField(title: "Storefront", text: $settings.session.storefront, placeholder: String(localized: "Celui du compte"))
                TemplateField(title: "Langue des métadonnées", text: $settings.session.language, placeholder: "en-US")
            } header: {
                Text("Région")
            } footer: {
                Text("Code pays à deux lettres (fr, us…) et langue BCP 47 (fr-FR, en-US). Vide : réglage de gamdl.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Système DRM", selection: $settings.session.drmBackend) {
                    Text("Par défaut de gamdl").tag(DrmBackend?.none)
                    ForEach(DrmBackend.allCases) { Text(verbatim: $0.label).tag(DrmBackend?.some($0)) }
                }
                PathField(title: "Fichier d'appareil", path: $settings.session.devicePath, directory: false)
                if !settings.session.devicePath.isEmpty {
                    Button("Utiliser l'appareil intégré à gamdl") { settings.session.devicePath = "" }
                }
            } header: {
                Text("Déchiffrement")
            } footer: {
                Text("gamdl embarque un appareil Widevine. PlayReady demande ton propre fichier .prd, un appareil Widevine L1 ou PlayReady SL3000 permet les clips au-delà de 1080p.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.session) { Task { await model.runDiagnostics() } }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                TextField("Chemin de gamdl", text: $settings.gamdlOverride, prompt: Text("Automatique (~/.local/bin/gamdl)"))
                PathField(title: "Dossier temporaire", path: $settings.tempPath, directory: true)
            } footer: {
                Text("gamdl est cherché dans ~/.local/bin, /opt/homebrew/bin et /usr/local/bin : une app lancée depuis le Finder n'hérite pas du PATH du terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Téléchargement") {
                Picker("Morceaux en parallèle", selection: $settings.options.concurrentDownloads) {
                    ForEach(DownloadOptions.parallelTracks, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                Picker("Segments en parallèle par morceau", selection: $settings.options.segmentConcurrency) {
                    Text("Par défaut de gamdl").tag(Int?.none)
                    ForEach(DownloadOptions.segmentConcurrencies, id: \.self) { Text(verbatim: "\($0)").tag(Int?.some($0)) }
                }
                Toggle("Arrêter au premier morceau en échec", isOn: $settings.options.failFast)
            }
            Section {
                Toggle("Tenir l'index des médias de gamdl", isOn: $settings.options.useDatabase)
                TemplateField(title: "Emplacement de l'index", text: $settings.options.databasePath, placeholder: "~/.gamdl/media.sqlite3")
                    .disabled(!settings.options.useDatabase)
                Toggle("Y garder aussi les métadonnées", isOn: $settings.options.saveMetadata)
                    .disabled(!settings.options.useDatabase)
            } header: {
                Text("Index des médias")
            } footer: {
                Text("L'index permet à gamdl de reconnaître un morceau déjà téléchargé sans rien redemander à Apple.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Afficher les traces Python dans le journal", isOn: $settings.options.showTracebacks)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Utile pour signaler un bug à gamdl. Ces traces peuvent contenir des liens signés ou des informations de compte : relis-les avant de les partager.")
                    Gamdl4OnlyNote()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Rétablir les emplacements par défaut") {
                    settings.resetPaths()
                    Task { await model.runDiagnostics() }
                }
                Button("Afficher le dossier de l'app") {
                    try? FileManager.default.createDirectory(at: AppSettings.applicationSupport, withIntermediateDirectories: true)
                    model.reveal(AppSettings.applicationSupport)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown under gamdl 4 settings when gamdl 3 is installed.
private struct Gamdl4OnlyNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.report?.generation == .v3 {
            Text("Ces réglages ne s'appliquent qu'avec gamdl 4.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// Editable path field with a "Choose…" button (NSOpenPanel).
private struct PathField: View {
    let title: LocalizedStringKey
    @Binding var path: String
    let directory: Bool

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(verbatim: path.isEmpty ? "—" : (path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(path)
                Button("Choisir…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: (path as NSString).expandingTildeInPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}



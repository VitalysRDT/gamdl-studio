import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralSettings() }
            Tab("Téléchargement", systemImage: "arrow.down.circle") { DownloadSettings() }
            Tab("Avancé", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 560)
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

private struct DownloadSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Qualité", selection: $settings.options.codec) {
                    ForEach(SongCodec.allCases) { codec in
                        VStack(alignment: .leading) {
                            Text(codec.label)
                            Text(codec.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(codec)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("L'ALAC (sans perte) et le Dolby Atmos exigent le wrapper FairPlay, que gamdl ne peut pas utiliser avec de simples cookies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Paroles") {
                Picker("Paroles synchronisées", selection: $settings.options.lyricsMode) {
                    ForEach(LyricsMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Format", selection: $settings.options.lyricsFormat) {
                    ForEach(LyricsFormat.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Pochette") {
                Picker("Taille intégrée", selection: $settings.options.coverSize) {
                    ForEach(CoverSize.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Enregistrer aussi un fichier Cover.jpg", isOn: $settings.options.saveCover)
            }
            Section("Artistes") {
                Picker("Depuis une page d'artiste, prendre", selection: $settings.options.artistSelection) {
                    ForEach(ArtistSelection.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Réécrire les fichiers existants", isOn: $settings.options.overwrite)
            }
        }
        .formStyle(.grouped)
    }
}

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

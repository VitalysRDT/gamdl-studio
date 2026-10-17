import AppKit
import Foundation
import Observation

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case download, queue, library, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: "Télécharger"
        case .queue: "File d'attente"
        case .library: "Bibliothèque"
        case .diagnostics: "Diagnostic"
        }
    }

    var symbol: String {
        switch self {
        case .download: "arrow.down.circle.fill"
        case .queue: "list.bullet.rectangle.portrait.fill"
        case .library: "square.grid.2x2.fill"
        case .diagnostics: "stethoscope"
        }
    }
}

/// App-wide state, shared by every window through the environment.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let queue: DownloadQueue
    let library = LibraryStore()
    let player = PlayerController()

    var selection: SidebarItem? = .download
    var report: DiagnosticReport?
    var isCheckingDiagnostics = false
    /// Link detected on the clipboard, offered in a banner on the Download screen.
    var clipboardSuggestion: AppleMusicLink?
    /// URL field text, shared so ⌘⇧V can fill it.
    var draftURL = ""
    var toast: Toast?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let symbol: String
        let message: String
        var action: String?
    }

    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var dismissedSuggestions = Set<String>()

    init(settings: AppSettings? = nil) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        queue = DownloadQueue(environment: { [settings] in
            DownloadEnvironment.live(settings: SettingsSnapshot(settings))
        })
        queue.maxConcurrent = settings.maxConcurrentJobs
        queue.notifyOnCompletion = settings.notifyOnCompletion
        queue.playSound = settings.playSoundOnCompletion
        queue.onJobFinished = { [weak self] job in self?.jobFinished(job) }
    }

    func start() {
        library.refresh(root: settings.outputURL)
        Task { await runDiagnostics() }
        DownloadQueue.requestNotificationPermission()
    }

    func applySettings() {
        queue.maxConcurrent = settings.maxConcurrentJobs
        queue.notifyOnCompletion = settings.notifyOnCompletion
        queue.playSound = settings.playSoundOnCompletion
    }

    func runDiagnostics() async {
        isCheckingDiagnostics = true
        report = await Diagnostics.run(settings: SettingsSnapshot(settings))
        isCheckingDiagnostics = false
    }

    // MARK: - Downloads

    @discardableResult
    func enqueue(_ links: [AppleMusicLink], previews: [AppleMusicLink: MediaPreview] = [:]) -> Int {
        let usable = links.filter(\.kind.isDownloadable)
        for link in usable {
            queue.enqueue(link, options: settings.options, preview: previews[link])
        }
        if !usable.isEmpty {
            show(Toast(
                symbol: "arrow.down.circle.fill",
                message: usable.count == 1 ? "Ajouté à la file d'attente" : "\(usable.count) liens ajoutés à la file",
                action: "Voir"
            ))
        }
        return usable.count
    }

    private func jobFinished(_ job: DownloadJob) {
        guard let started = job.startedAt else { return }
        let task = library.refresh(root: settings.outputURL)
        Task {
            await task.value
            let written = library.albums(modifiedSince: started).map { $0.folder.standardizedFileURL }
            job.resultFolders = written + job.existingFolders.filter { f in !written.contains { $0.path == f.path } }
        }
    }

    /// Preview for the download screen. Personalized playlists have no public
    /// page, so they are read through the subscriber's session instead.
    func preview(for link: AppleMusicLink) async throws -> MediaPreview? {
        guard link.needsResolution else { return try await MediaPreviewService().preview(for: link) }
        let environment = DownloadEnvironment.live(settings: SettingsSnapshot(settings))
        let paths = try await environment.paths()
        return try await environment.resolvePlaylist(link, paths).preview()
    }

    // MARK: - Clipboard

    /// Checked when the app becomes active, so a link copied in Safari or Music
    /// is offered without having to paste it.
    func checkPasteboard() {
        guard settings.watchClipboard else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        guard let text = pb.string(forType: .string),
              let link = AppleMusicLink.extractAll(from: text).first,
              !dismissedSuggestions.contains(link.absoluteString),
              link.absoluteString != draftURL.trimmed
        else { return }
        clipboardSuggestion = link
    }

    func dismissSuggestion() {
        if let s = clipboardSuggestion { dismissedSuggestions.insert(s.absoluteString) }
        clipboardSuggestion = nil
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        draftURL = AppleMusicLink.extractAll(from: text).first?.absoluteString ?? text.trimmed
        selection = .download
        clipboardSuggestion = nil
    }

    func show(_ toast: Toast) {
        self.toast = toast
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if self.toast?.id == id { self.toast = nil }
        }
    }

    // MARK: - Finder

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInMusic(_ urls: [URL]) {
        guard let music = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: music, configuration: NSWorkspace.OpenConfiguration())
    }
}

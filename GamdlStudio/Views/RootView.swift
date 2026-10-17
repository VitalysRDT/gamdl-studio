import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .id(model.selection)

                VStack(spacing: 10) {
                    if let toast = model.toast {
                        ToastView(toast: toast) { model.selection = .queue; model.toast = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.player.current != nil {
                        MiniPlayerBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.toast)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.player.current)
            }
            .animation(.easeInOut(duration: 0.2), value: model.selection)
        }
        .onChange(of: model.settings.outputPath) { model.library.refresh(root: model.settings.outputURL) }
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .download {
        case .download: DownloadView()
        case .queue: QueueView()
        case .library: LibraryView()
        case .diagnostics: DiagnosticsView()
        }
    }

    /// A link dropped anywhere in the window goes straight to the queue.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let model = model
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.enqueue(AppleMusicLink.extractAll(from: url.absoluteString)) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in model.enqueue(AppleMusicLink.extractAll(from: text)) }
                }
            }
        }
        return handled
    }
}

struct ToastView: View {
    let toast: AppModel.Toast
    var onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.symbol)
                .font(.title3)
                .foregroundStyle(.brandGradient)
            Text(toast.message).font(.callout.weight(.medium))
            if let action = toast.action {
                Button(action, action: onAction)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }
}

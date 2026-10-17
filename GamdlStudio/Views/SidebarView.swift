import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.symbol)
                                .foregroundStyle(item == model.selection ? AnyShapeStyle(.white) : AnyShapeStyle(.brandGradient))
                        }
                        .badge(badge(for: item))
                    }
                }
            } header: {
                brand
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let job = model.queue.active.first {
                ActiveJobPill(job: job)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.selection = .queue }
            }
        }
        .animation(.spring(response: 0.4), value: model.queue.active.first?.id)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.brandGradient, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("Gamdl Studio").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                Text(model.report?.gamdl.version.map { "gamdl \($0)" } ?? "Apple Music")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 10)
        .textCase(nil)
    }

    private func badge(for item: SidebarItem) -> Text? {
        switch item {
        case .queue:
            let n = model.queue.pendingCount
            return n > 0 ? Text("\(n)") : nil
        case .library:
            return model.library.albums.isEmpty ? nil : Text("\(model.library.albums.count)")
        case .diagnostics:
            guard let report = model.report else { return nil }
            return report.isReady ? nil : Text("!")
        case .download:
            return nil
        }
    }
}

/// Summary of the active download at the bottom of the sidebar.
struct ActiveJobPill: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                ArtworkView(source: job.preview?.artworkURL, size: 36, cornerRadius: 8, maxPixel: 120)
                ProgressRing(value: job.overallFraction, lineWidth: 2.5)
                    .frame(width: 46, height: 46)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(job.currentTrackTitle ?? "Préparation…")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(Int(job.overallFraction * 100)) %")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }
}

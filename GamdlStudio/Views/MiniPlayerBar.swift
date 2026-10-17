import SwiftUI

/// Floating glass player pinned to the bottom of the content area.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var scrubbing: Double?

    var body: some View {
        let player = model.player
        if let track = player.current {
            HStack(spacing: 14) {
                ArtworkView(source: player.album?.artworkSource ?? track.url, size: 44, cornerRadius: 8, maxPixel: 160)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(verbatim: player.album?.subtitle ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 180, alignment: .leading)

                HStack(spacing: 4) {
                    control("backward.fill") { player.previous() }
                    control(player.isPlaying ? "pause.fill" : "play.fill", big: true) { player.toggle() }
                    control("forward.fill") { player.next() }
                }

                HStack(spacing: 8) {
                    Text(Formatters.duration(seconds: (scrubbing ?? player.fraction) * player.duration))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    Slider(value: Binding(
                        get: { scrubbing ?? player.fraction },
                        set: { scrubbing = $0 }
                    ), in: 0...1) { editing in
                        if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
                    }
                    .controlSize(.mini)
                    .tint(.brand)
                    Text(Formatters.duration(seconds: player.duration))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                }

                Button {
                    if let album = player.album { model.reveal(album.folder) }
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Afficher dans le Finder")

                Button { player.stop() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Fermer le lecteur")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 820)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        }
    }

    private func control(_ symbol: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 18 : 13, weight: .semibold))
                .frame(width: big ? 34 : 26, height: big ? 34 : 26)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
    }
}

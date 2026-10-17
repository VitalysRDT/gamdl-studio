import SwiftUI

/// Lazily loaded artwork, with a placeholder gradient while loading and a
/// fade-in once it arrives.
struct ArtworkView: View {
    let source: URL?
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 12
    var maxPixel: Int = 512
    var symbol: String = "music.note"

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.35)))
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .task(id: source) {
            image = nil
            guard let source else { return }
            let loaded = await ArtworkCache.shared.image(for: source, maxPixel: maxPixel)
            withAnimation { image = loaded }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(white: 0.32), Color(white: 0.18)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: symbol)
                .font(.system(size: (size ?? 120) * 0.3, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

/// Extracts an artwork's palette and passes it up to the parent view.
struct PaletteReader: ViewModifier {
    let source: URL?
    @Binding var palette: ImagePalette

    func body(content: Content) -> some View {
        content.task(id: source) {
            guard let source else {
                withAnimation(.easeInOut(duration: 0.8)) { palette = .fallback }
                return
            }
            let p = await ArtworkCache.shared.palette(for: source)
            withAnimation(.easeInOut(duration: 1.2)) { palette = p }
        }
    }
}

extension View {
    func readPalette(from source: URL?, into palette: Binding<ImagePalette>) -> some View {
        modifier(PaletteReader(source: source, palette: palette))
    }
}

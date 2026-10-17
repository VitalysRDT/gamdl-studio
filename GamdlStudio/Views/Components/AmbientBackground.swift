import SwiftUI

/// Animated background: a MeshGradient whose points drift slowly, tinted with
/// the colors of the current artwork.
///
/// Colors are "tamed" (brightness clamped) and then dimmed so the background
/// sets the mood without competing with the text on top of it.
struct AmbientBackground: View {
    var palette: ImagePalette
    var intensity: Double = 1
    var animated = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3,
                points: points(t),
                colors: colors,
                smoothsColors: true
            )
        }
        .overlay(scheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.35))
        .overlay(.ultraThinMaterial.opacity(0.35))
        .opacity(intensity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: palette)
    }

    private var colors: [Color] {
        let base = (palette.colors.isEmpty ? ImagePalette.fallback.colors : palette.colors).map { $0.tamed() }
        func c(_ i: Int) -> Color { base[i % base.count].color }
        let deep = scheme == .dark ? Color(white: 0.06) : Color(white: 0.94)
        return [
            c(0), c(1), deep,
            c(2), c(0), c(1),
            deep, c(3), c(2),
        ]
    }

    /// The 4 corners stay fixed (otherwise the edges show). The other 5 points
    /// oscillate on coprime periods so the motion never visibly loops.
    private func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ period: Double, _ amp: Double, _ phase: Double = 0) -> Float {
            Float(sin(t / period + phase) * amp)
        }
        return [
            [0, 0], [0.5 + w(7, 0.12), 0], [1, 0],
            [0, 0.5 + w(11, 0.1, 1)], [0.5 + w(13, 0.15, 2), 0.5 + w(9, 0.15)], [1, 0.5 + w(8, 0.1, 3)],
            [0, 1], [0.5 + w(10, 0.12, 4), 1], [1, 1],
        ]
    }
}

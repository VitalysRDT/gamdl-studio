import SwiftUI

extension Color {
    static let brand = Color(red: 0.98, green: 0.18, blue: 0.33)
    static let brandSecondary = Color(red: 0.99, green: 0.45, blue: 0.25)
}

extension ShapeStyle where Self == Color {
    static var brand: Color { Color.brand }
}

extension ShapeStyle where Self == LinearGradient {
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [.brand, .brandSecondary], startPoint: .leading, endPoint: .trailing)
    }
}

/// Liquid Glass card with continuous corners.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 22
    var padding: CGFloat = 20
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassCard(radius: CGFloat = 22, padding: CGFloat = 20, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, padding: padding, tint: tint))
    }

    /// Section title: small caps with letter spacing.
    func sectionLabel() -> some View {
        font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Capsule progress bar with a moving shimmer while work is in progress.
struct ProgressCapsule: View {
    var value: Double
    var isActive = true
    var height: CGFloat = 8
    var tint: AnyShapeStyle = AnyShapeStyle(.brandGradient)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width * min(max(value, 0), 1), value > 0 ? height : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: width)
                    .overlay {
                        if isActive && !reduceMotion {
                            TimelineView(.animation) { ctx in
                                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                                LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 80)
                                    .offset(x: -80 + (width + 80) * phase)
                            }
                            .clipShape(Capsule())
                            .blendMode(.plusLighter)
                        }
                    }
                    .shadow(color: .brand.opacity(isActive ? 0.45 : 0), radius: 6)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: value)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value * 100)) %"))
    }
}

/// Small rounded badge (content type, status).
struct Pill: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Progress ring for compact thumbnails (sidebar).
struct ProgressRing: View {
    var value: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0.02), 1))
                .stroke(.brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5), value: value)
        }
    }
}

/// Shared hover effect for clickable cards.
struct HoverLift: ViewModifier {
    @State private var hovering = false
    var scale: CGFloat = 1.03

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.03) -> some View { modifier(HoverLift(scale: scale)) }
}

/// Skeleton shimmer shown while loading.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

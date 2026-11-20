import CoreImage
import SwiftUI

// MARK: - Palette

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Theme {
    // Accent (violet)
    /// Fills: buttons, selected pills.
    static let accent = Color(hex: 0x6D4AFF)
    /// Marks: progress, rings, indicators.
    static let accentMark = Color(hex: 0x7C5CFF)
    /// Accent text on light backgrounds.
    static let accentInk = Color(hex: 0x5B3DE0)

    // Dark glass
    static let darkBackground = Color(hex: 0x0D0B14)
    static let glassFill = Color.white.opacity(0.12)
    static let glassStroke = Color.white.opacity(0.20)
    /// Solid stand-in for glass when "Reduce transparency" is on.
    static let glassSolid = Color(hex: 0x2A2635)

    // Light editorial
    static let cream = Color(hex: 0xF6F3EC)
    static let ink = Color(hex: 0x141014)
    static let plum = Color(hex: 0x3B2340)
    static let plumSoft = Color(hex: 0x8C7A92)
    static let gray = Color(hex: 0xEDECEF)

    /// Minimum hit target for every button.
    static let minTap: CGFloat = 44
}

// MARK: - Type & case

/// Section labels, technical tags, mono data and short calls to action:
/// small, uppercase, positive tracking.
struct LottaLabel: ViewModifier {
    var mono: Bool
    var tracking: CGFloat

    func body(content: Content) -> some View {
        content
            .font(mono ? .caption2.monospaced().weight(.medium) : .caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(tracking)
    }
}

/// Condensed editorial title with negative tracking that still follows
/// Dynamic Type (the size scales relative to `relativeTo`).
struct LottaEditorialTitle: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight
    var tracking: CGFloat

    init(size: CGFloat, weight: Font.Weight, tracking: CGFloat, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.tracking = tracking
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight).width(.condensed))
            .tracking(tracking)
    }
}

extension View {
    /// Uppercase label (sección, FLAC, "11 pistas · 46 min", "seguir"…).
    /// Only changes how the text is drawn, never the data.
    func lottaLabel(mono: Bool = false, tracking: CGFloat = 0.9) -> some View {
        modifier(LottaLabel(mono: mono, tracking: tracking))
    }

    /// Lowercase display (titles, songs, albums, artists, buttons, lyrics).
    /// Only changes how the text is drawn: the data and VoiceOver keep the
    /// original casing.
    func lottaLower() -> some View {
        textCase(.lowercase)
    }

    /// Condensed editorial title.
    func lottaEditorial(size: CGFloat, weight: Font.Weight = .bold, tracking: CGFloat? = nil,
                        relativeTo style: Font.TextStyle = .largeTitle) -> some View {
        modifier(LottaEditorialTitle(size: size, weight: weight,
                                     tracking: tracking ?? -size * 0.035, relativeTo: style))
    }
}

// MARK: - Screens

/// Uppercase section header for lists.
struct LottaListHeader: View {
    let text: String
    var mono = false
    init(_ text: String, mono: Bool = false) { self.text = text; self.mono = mono }

    var body: some View {
        Text(text).lottaLabel(mono: mono, tracking: 1.0).foregroundStyle(.white.opacity(0.6))
    }
}

extension View {
    /// Dark glass screen (library, downloads, search): dark background,
    /// dark navigation bar and controls.
    func lottaDarkScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.darkBackground.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .toolbarBackground(Theme.darkBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

// MARK: - Glass

/// Liquid Glass on iOS 26, ultra-thin material before that, and a solid
/// fill when "Reduce transparency" is on.
struct LottaGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Theme.glassSolid, in: shape)
                .overlay(shape.stroke(Theme.glassStroke, lineWidth: 1))
        } else if #available(iOS 26, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(Theme.glassFill, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.glassStroke, lineWidth: 1))
        }
    }
}

extension View {
    func lottaGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(LottaGlass(shape: shape, interactive: interactive))
    }
}

// MARK: - Components

/// Round icon button. `.glass` draws its own glass; `.inset` is a soft
/// white disc for use inside a `GlassCapsule` (which already is glass).
struct GlassCircleButton: View {
    enum Style { case glass, inset }

    let systemImage: String
    let accessibilityLabel: String
    var size: CGFloat = 46
    var style: Style = .glass
    var isActive = false
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .frame(width: max(size, Theme.minTap), height: max(size, Theme.minTap))
                .background {
                    if isActive {
                        Circle().fill(Theme.accent)
                    } else if style == .inset {
                        Circle().fill(reduceTransparency ? Theme.glassSolid : Theme.glassFill)
                    }
                }
                .modifier(OptionalGlass(enabled: style == .glass && !isActive))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct OptionalGlass: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.lottaGlass(in: Circle(), interactive: true) } else { content }
    }
}

/// Top bar: a glass capsule holding 46 pt round buttons and a centre slot.
struct GlassCapsule<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            center.frame(maxWidth: .infinity)
            trailing
        }
        .padding(5)
        .frame(minHeight: 56)
        .lottaGlass(in: Capsule())
    }
}

/// Pill with an icon and a short lowercase title.
struct GlassPill: View {
    let systemImage: String
    let title: String
    var isActive = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.subheadline.weight(.semibold))
            if !title.isEmpty {
                Text(title).font(.subheadline.weight(.medium)).lottaLower().lineLimit(1)
            }
        }
        .padding(.horizontal, title.isEmpty ? 0 : 16)
        .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
        .background { if isActive { Capsule().fill(Theme.accent) } }
        .modifier(PillGlass(enabled: !isActive))
        .contentShape(Capsule())
    }
}

private struct PillGlass: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.lottaGlass(in: Capsule(), interactive: true) } else { content }
    }
}

/// Small technical tag: FLAC, 24/96, LRC.
struct TechBadge: View {
    let text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .lottaLabel(mono: true, tracking: 0.8)
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1))
    }
}

/// The current artwork, heavily blurred, under a dark gradient.
/// The blur is computed once per cover on a tiny copy (cheap) instead of
/// a live full-screen blur filter, which is expensive to redraw.
struct AmbientBackground: View {
    let itemId: String?
    /// Blur radius in points at full-screen size (50 or more).
    var blurRadius: CGFloat = 60
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.darkBackground
            Color.clear.overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.45), Theme.darkBackground.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: itemId) {
            guard let itemId else {
                withAnimation(.easeInOut(duration: 0.6)) { image = nil }
                return
            }
            let img = await AmbientBlur.image(for: itemId, radius: blurRadius)
            withAnimation(.easeInOut(duration: 0.6)) { image = img }
        }
    }
}

@MainActor
private enum AmbientBlur {
    private static var cache: [String: UIImage] = [:]
    private static var order: [String] = []

    static func image(for itemId: String, radius: CGFloat) async -> UIImage? {
        if let hit = cache[itemId] { return hit }
        guard let source = await ArtworkCache.shared.image(for: itemId, size: ArtworkSize.small),
              let cg = source.cgImage else { return nil }
        let out = await Task.detached(priority: .userInitiated) { blur(cg, radius: radius) }.value
        if let out {
            cache[itemId] = out
            order.append(itemId)
            if order.count > 12 { cache[order.removeFirst()] = nil }
        }
        return out
    }

    /// Downscale to ~64 px and blur there. Shown full screen, a sigma of
    /// radius/7 at that size is roughly a `radius`-point blur.
    nonisolated private static func blur(_ cg: CGImage, radius: CGFloat) -> UIImage? {
        let input = CIImage(cgImage: cg)
        let scale = 64 / max(input.extent.width, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius) / 7)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .cropped(to: small.extent)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = ctx.createCGImage(blurred, from: small.extent) else { return nil }
        return UIImage(cgImage: out)
    }
}

/// Decorative vinyl record drawn only with shapes.
struct VinylDisc: View {
    var labelColor: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Theme.ink)
                ForEach(1..<7) { i in
                    Circle()
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                        .padding(d * (0.06 + CGFloat(i) * 0.045))
                }
                Circle().fill(labelColor).frame(width: d * 0.36, height: d * 0.36)
                Circle().fill(Theme.cream).frame(width: d * 0.04, height: d * 0.04)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

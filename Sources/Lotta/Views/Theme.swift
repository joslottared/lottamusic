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

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Light/dark appearance chosen in Ajustes.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let storageKey = "lotta.appearance"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Oscuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the appearance chosen in Ajustes (or follows the iPhone).
struct LottaAppearance: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func lottaAppearance() -> some View { modifier(LottaAppearance()) }
}

/// Colors resolve against the view's color scheme: light = cream editorial,
/// dark = violet glass. Text pairs checked for WCAG AA (≥ 4.5:1) on their
/// backgrounds; marks (bars, rings, icons) for ≥ 3:1.
enum Theme {
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // Accent (violet)
    /// Fills: buttons, selected pills (white text on it: 5.2:1).
    static let accent = Color(hex: 0x6D4AFF)
    /// Marks: progress, rings, indicators (3.9:1 on cream, 4.5:1 on dark).
    static let accentMark = Color(hex: 0x7C5CFF)
    /// Accent text: #5B3DE0 on cream (5.9:1), #A48FFF on dark (7.4:1).
    static let accentText = dynamic(light: UIColor(hex: 0x5B3DE0), dark: UIColor(hex: 0xA48FFF))

    // Surfaces
    /// Screen background: cream #F6F3EC / night #0D0B14.
    static let background = dynamic(light: UIColor(hex: 0xF6F3EC), dark: UIColor(hex: 0x0D0B14))
    /// Always-dark background (player, text on white buttons).
    static let darkBackground = Color(hex: 0x0D0B14)
    static let glassFill = dynamic(light: UIColor(white: 1, alpha: 0.6), dark: UIColor(white: 1, alpha: 0.12))
    static let glassStroke = dynamic(light: UIColor(hex: 0x141014, alpha: 0.10), dark: UIColor(white: 1, alpha: 0.20))
    /// Soft disc behind icons inside a glass capsule.
    static let insetFill = dynamic(light: UIColor(hex: 0x141014, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.12))
    /// Solid stand-in for glass when "Reduce transparency" is on.
    static let glassSolid = dynamic(light: UIColor(hex: 0xFFFFFF), dark: UIColor(hex: 0x2A2635))
    /// Unfilled part of progress bars.
    static let track = dynamic(light: UIColor(hex: 0x141014, alpha: 0.14), dark: UIColor(white: 1, alpha: 0.22))

    // Text
    /// Primary text: ink #141014 on cream (17:1) / cream on night (17.6:1).
    static let ink = dynamic(light: UIColor(hex: 0x141014), dark: UIColor(hex: 0xF6F3EC))
    /// Headings in plum: #3B2340 (12.6:1) / #D9C6DE on dark.
    static let plum = dynamic(light: UIColor(hex: 0x3B2340), dark: UIColor(hex: 0xD9C6DE))
    /// Secondary text: #6E5F75 on cream (5.3:1) / #A99BB0 on dark (7.4:1).
    /// (The original #8C7A92 was 3.6:1 on cream: too low for small text.)
    static let secondaryText = dynamic(light: UIColor(hex: 0x6E5F75), dark: UIColor(hex: 0xA99BB0))
    static let separator = dynamic(light: UIColor(hex: 0x141014, alpha: 0.10), dark: UIColor(white: 1, alpha: 0.10))

    // Fixed editorial colors
    static let cream = Color(hex: 0xF6F3EC)
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
        Text(text).lottaLabel(mono: mono, tracking: 1.0).foregroundStyle(Theme.secondaryText)
    }
}

extension View {
    /// Themed screen (library, downloads, search, playlist): cream in light
    /// mode, night violet in dark mode.
    func lottaScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbarBackground(Theme.background, for: .navigationBar)
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
                        Circle().fill(reduceTransparency ? Theme.glassSolid : Theme.insetFill)
                    }
                }
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
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
        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
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
            .foregroundStyle(tint)
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
            // Dark enough at the top too, so white text stays readable over light covers.
            LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.55), Theme.darkBackground.opacity(0.92)],
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
                Circle().fill(Color(hex: 0x1A1620))
                Circle().stroke(.white.opacity(0.12), lineWidth: 1) // rim, visible on dark screens
                ForEach(1..<7) { i in
                    Circle()
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                        .padding(d * (0.06 + CGFloat(i) * 0.045))
                }
                Circle().fill(labelColor).frame(width: d * 0.36, height: d * 0.36)
                Circle().fill(Theme.background).frame(width: d * 0.04, height: d * 0.04)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

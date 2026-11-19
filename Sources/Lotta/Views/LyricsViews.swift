import Photos
import PhotosUI
import SwiftUI

/// Synced lyrics with Spotify/Apple Music-style line selection for sharing.
struct LyricsView: View {
    let lyrics: Lyrics?
    let loaded: Bool
    var onShare: ([String]) -> Void

    @EnvironmentObject private var player: Player
    @State private var selecting = false
    @State private var selected: Set<Int> = []

    static let maxSelection = 6

    var body: some View {
        if !loaded {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics, !lyrics.lines.isEmpty {
            content(lyrics)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble").font(.largeTitle)
                Text("Esta canción no tiene letra").font(.headline)
                Text("Agrega un archivo .lrc con el mismo nombre que la canción en tu servidor Jellyfin.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .opacity(0.6)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ lyrics: Lyrics) -> some View {
        let current = selecting ? nil : lyrics.currentIndex(at: player.currentTime)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: selecting ? 8 : 22) {
                    ForEach(lyrics.lines) { line in
                        lineView(line, isCurrent: line.id == current, synced: lyrics.isSynced)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 40)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.07),
                                       .init(color: .black, location: 0.9),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: current) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: 0.3))
                }
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .overlay(alignment: .topTrailing) {
                // Enters selection mode; tapping again leaves it.
                Button {
                    withAnimation {
                        selecting.toggle()
                        selected = []
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(selecting ? 0.35 : 0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selecting ? "Salir de la selección" : "Seleccionar letra para compartir")
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selected.isEmpty {
                    shareButton(lyrics)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Small tap on long-press and each line picked/unpicked.
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: selected) { _, new in
                !new.isEmpty
            }
        }
    }

    private func lineView(_ line: Lyrics.Line, isCurrent: Bool, synced: Bool) -> some View {
        let isSelected = selected.contains(line.id)
        let opacity: Double = selecting ? (isSelected ? 1 : 0.4) : (synced ? (isCurrent ? 1 : 0.35) : 0.9)
        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 28, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, selecting ? 8 : 0)
            .padding(.horizontal, selecting ? 12 : 0)
            .background {
                if selecting && isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.18))
                }
            }
            .opacity(opacity)
            .scaleEffect(isCurrent ? 1.0 : 0.97, anchor: .leading)
            .animation(.easeOut(duration: 0.3), value: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting {
                    toggle(line)
                } else if let start = line.start {
                    player.seek(to: start)
                }
            }
            .onLongPressGesture {
                guard !line.text.isEmpty else { return }
                withAnimation {
                    selecting = true
                    selected = [line.id]
                }
            }
    }

    private func toggle(_ line: Lyrics.Line) {
        guard !line.text.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            if selected.contains(line.id) {
                selected.remove(line.id)
                if selected.isEmpty { selecting = false } // last line removed → leave
            } else if selected.count < Self.maxSelection {
                selected.insert(line.id)
            }
        }
    }

    private func shareButton(_ lyrics: Lyrics) -> some View {
        Button {
            let lines = lyrics.lines.filter { selected.contains($0.id) }.map(\.text)
            onShare(lines)
            withAnimation { selecting = false; selected = [] }
        } label: {
            Label("Compartir", systemImage: "square.and.arrow.up")
                .font(.headline)
                .padding(.horizontal, 26)
                .padding(.vertical, 13)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }
}

// MARK: - Share card

enum CardStyle: String, CaseIterable, Identifiable {
    case color, artwork, light, photo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: "Color"
        case .artwork: "Portada"
        case .light: "Claro"
        case .photo: "Foto"
        }
    }
}

/// 9:16 image, story-ready. Rendered with ImageRenderer, so it takes images
/// as UIImage (async views would render empty) and avoids system materials
/// (they don't render there): the frosted glass is a masked, blurred copy.
struct LyricsCard: View {
    let title: String
    let artist: String
    let lines: [String]
    let artwork: UIImage?
    let baseColor: UIColor
    let style: CardStyle
    var photo: UIImage? = nil
    /// Card size relative to the default (fonts, padding and width scale together,
    /// so lines wrap the same way at every size).
    var cardScale: CGFloat = 1
    /// Card position as a fraction of the canvas width (so preview → export match).
    var cardOffset: CGSize = .zero
    var width: CGFloat = 360

    static let scaleRange: ClosedRange<CGFloat> = 0.5...1.15

    private var offsetPoints: CGSize { CGSize(width: cardOffset.width * width, height: cardOffset.height * width) }

    private var s: CGFloat { width / 360 }
    /// Metric unit for everything inside the card.
    private var k: CGFloat { s * cardScale }
    private var sidePadding: CGFloat { max(8 * s, (width - (width - 52 * s) * cardScale) / 2) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18 * k, style: .continuous) }
    private var isGlass: Bool { style == .photo && photo != nil }

    private var cardColor: UIColor {
        switch style {
        case .color: baseColor.adjusted(brightness: 0.45...0.7, minSaturation: 0.4)
        case .artwork, .photo: .black
        case .light: UIColor(white: 0.97, alpha: 1)
        }
    }

    private var foreground: Color {
        switch style {
        case .light: .black
        case .artwork, .photo: .white
        case .color: cardColor.luminance > 0.62 ? .black : .white
        }
    }

    var body: some View {
        ZStack {
            canvas
            if isGlass, let photo {
                // Same photo, blurred, visible only where the card is.
                FillImage(image: photo, blur: 22 * s)
                    .mask {
                        content.background(Color.black).clipShape(shape)
                            .padding(.horizontal, sidePadding)
                            .offset(offsetPoints)
                    }
            }
            card.padding(.horizontal, sidePadding).offset(offsetPoints)
        }
        .frame(width: width, height: width * 16 / 9)
        .clipped()
    }

    @ViewBuilder private var canvas: some View {
        switch style {
        case .artwork:
            ZStack {
                if let artwork { FillImage(image: artwork, blur: 40 * s) }
                Color.black.opacity(0.35)
            }
        case .photo:
            if let photo {
                FillImage(image: photo)
            } else {
                Color(uiColor: baseColor.adjusted(brightness: 0.18...0.32, minSaturation: 0.3))
            }
        case .color:
            Color(uiColor: baseColor.adjusted(brightness: 0.18...0.32, minSaturation: 0.3))
        case .light:
            Color(uiColor: baseColor.adjusted(brightness: 0.55...0.8, minSaturation: 0.3))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20 * k) {
            HStack(spacing: 12 * k) {
                Group {
                    if let artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        Color.gray
                    }
                }
                .frame(width: 46 * k, height: 46 * k)
                .clipShape(RoundedRectangle(cornerRadius: 6 * k, style: .continuous))

                VStack(alignment: .leading, spacing: 2 * k) {
                    Text(title).font(.system(size: 15 * k, weight: .bold)).lineLimit(1)
                    Text(artist).font(.system(size: 14 * k, weight: .medium)).opacity(0.75).lineLimit(1)
                }
            }

            Text(lines.joined(separator: "\n"))
                .font(.system(size: (lines.count > 4 ? 22 : 26) * k, weight: .bold))
                .lineSpacing(4 * k)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5 * k) {
                Image(systemName: "waveform")
                Text("Lotta")
            }
            .font(.system(size: 12 * k, weight: .semibold))
            .opacity(0.6)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22 * k)
    }

    private var card: some View {
        content
            .shadow(color: isGlass ? .black.opacity(0.35) : .clear, radius: 6 * k, y: 1 * k)
            .background {
                if isGlass {
                    ZStack {
                        Color.black.opacity(0.18)
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                } else {
                    ZStack {
                        Color(uiColor: cardColor)
                        if style == .artwork, let artwork {
                            FillImage(image: artwork, blur: 18 * k)
                            Color.black.opacity(0.4)
                        }
                    }
                }
            }
            .clipShape(shape)
            .overlay { if isGlass { shape.stroke(.white.opacity(0.35), lineWidth: 1 * k) } }
            .shadow(color: .black.opacity(isGlass ? 0.15 : 0.25), radius: 20 * k, y: 10 * k)
    }
}

/// Aspect-fill image that never affects layout size (an overflowing
/// scaledToFill image shifts ImageRenderer output and crops the card).
private struct FillImage: View {
    let image: UIImage
    var blur: CGFloat = 0

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: blur, opaque: true)
            }
            .clipped()
    }
}

struct LyricsShareView: View {
    let item: BaseItem
    let lines: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var style: CardStyle = .color
    @State private var artwork: UIImage?
    @State private var baseColor: UIColor = .darkGray
    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var cardScale: CGFloat = 1
    @State private var cardOffset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @State private var drag: CGSize = .zero
    @State private var isDragging = false
    @State private var snapX = false
    @State private var snapY = false
    @State private var snapCount = 0
    @State private var rendered: UIImage?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                card(width: Self.previewWidth, live: true)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                    .contentShape(Rectangle())
                    .overlay { guides }
                    .gesture(cardGesture, including: style == .photo && photo != nil ? .all : .subviews)
                    .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: snapCount)
                    .onTapGesture(count: 2) {
                        guard style == .photo else { return }
                        cardScale = 1
                        cardOffset = .zero
                        render()
                    }

                Picker("Estilo", selection: $style) {
                    ForEach(CardStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if style == .photo {
                    VStack(spacing: 6) {
                        if photo != nil {
                            Text("Pellizca para cambiar el tamaño · arrastra para moverla")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button { showPicker = true } label: {
                            Label(photo == nil ? "Elegir foto de la galería" : "Cambiar foto",
                                  systemImage: "photo.on.rectangle")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }

                HStack(spacing: 12) {
                    if let rendered {
                        ShareLink(item: Image(uiImage: rendered),
                                  preview: SharePreview(item.title, image: Image(uiImage: rendered))) {
                            Label("Compartir", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Guardar en Fotos", systemImage: "photo.badge.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(rendered == nil)
                }
                .controlSize(.large)
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Compartir letra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
            .task {
                artwork = await ArtworkCache.shared.image(for: item.artworkItemId, size: ArtworkSize.large)
                baseColor = artwork?.averageColor ?? .darkGray
                render()
            }
            .onChange(of: style) { _, new in
                if new == .photo && photo == nil { showPicker = true }
                render()
            }
            .photosPicker(isPresented: $showPicker, selection: $photoItem, matching: .images)
            .onChange(of: showPicker) { _, open in
                // Closed the picker without choosing anything → back to the previous look.
                if !open && photoItem == nil && photo == nil && style == .photo { style = .color }
            }
            .onChange(of: photoItem) { _, newItem in
                Task { await loadPhoto(newItem) }
            }
        }
        .environment(\.colorScheme, .light)
    }

    static let previewWidth: CGFloat = 250

    /// Size/position only apply to the photo style; `live` adds the in-flight gesture.
    private func card(width: CGFloat, live: Bool = false) -> LyricsCard {
        let isPhoto = style == .photo
        return LyricsCard(title: item.title, artist: item.trackArtist, lines: lines,
                          artwork: artwork, baseColor: baseColor, style: style, photo: photo,
                          cardScale: isPhoto ? (live ? liveScale : cardScale) : 1,
                          cardOffset: isPhoto ? (live ? liveOffset : cardOffset) : .zero,
                          width: width)
    }

    private func clampScale(_ v: CGFloat) -> CGFloat {
        min(max(v, LyricsCard.scaleRange.lowerBound), LyricsCard.scaleRange.upperBound)
    }

    private func clampOffset(_ o: CGSize) -> CGSize {
        CGSize(width: min(max(o.width, -0.42), 0.42), height: min(max(o.height, -0.75), 0.75))
    }

    private var liveScale: CGFloat { clampScale(cardScale * pinch) }

    // Magnetic center guides, with hysteresis: the card grabs the guide when
    // within `snapIn` and only lets go past `snapOut` (you have to mean it).
    static let snapIn: CGFloat = 0.03   // ≈ 7 pt on the preview
    static let snapOut: CGFloat = 0.11  // ≈ 27 pt on the preview

    private var rawOffset: CGSize {
        clampOffset(CGSize(width: cardOffset.width + drag.width / Self.previewWidth,
                           height: cardOffset.height + drag.height / Self.previewWidth))
    }

    private var liveOffset: CGSize {
        var o = rawOffset
        if snapX { o.width = 0 }
        if snapY { o.height = 0 }
        return o
    }

    private func updateSnaps() {
        let r = rawOffset
        let newX = abs(r.width) < (snapX ? Self.snapOut : Self.snapIn)
        let newY = abs(r.height) < (snapY ? Self.snapOut : Self.snapIn)
        if (newX && !snapX) || (newY && !snapY) { snapCount += 1 }
        snapX = newX
        snapY = newY
    }

    @ViewBuilder private var guides: some View {
        if isDragging && style == .photo {
            ZStack {
                if snapX {
                    Rectangle().fill(.yellow).frame(width: 1).frame(maxHeight: .infinity)
                }
                if snapY {
                    Rectangle().fill(.yellow).frame(height: 1).frame(maxWidth: .infinity)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 1)
            .allowsHitTesting(false)
        }
    }

    private var cardGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                cardScale = clampScale(cardScale * value.magnification)
                render()
            }
            .simultaneously(with:
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isDragging {
                            // Starting on a guide counts as attached to it.
                            isDragging = true
                            snapX = cardOffset.width == 0
                            snapY = cardOffset.height == 0
                        }
                        drag = value.translation
                        updateSnaps()
                    }
                    .onEnded { _ in
                        cardOffset = liveOffset
                        drag = .zero
                        isDragging = false
                        render()
                    }
            )
    }

    private func loadPhoto(_ pick: PhotosPickerItem?) async {
        guard let pick,
              let data = try? await pick.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        // Big camera photos make rendering slow; 1920px covers the 1080×1920 output.
        let maxSide: CGFloat = 1920
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        photo = await image.byPreparingThumbnail(ofSize: target) ?? image
        render()
    }

    private func render() {
        let renderer = ImageRenderer(content: card(width: 360))
        renderer.scale = 3 // 1080 × 1920
        rendered = renderer.uiImage
    }

    private func save() async {
        guard let rendered else { return }
        let ok = await PhotoSaver.save(rendered)
        withAnimation { toast = ok ? "Guardada en Fotos" : "Permite el acceso a Fotos en Ajustes" }
        try? await Task.sleep(for: .seconds(2))
        withAnimation { toast = nil }
    }
}

enum PhotoSaver {
    static func save(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }
}

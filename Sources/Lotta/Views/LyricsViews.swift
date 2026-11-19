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
    /// Selected lines are always one contiguous block (line ids are indices).
    @State private var selected: ClosedRange<Int>?
    @State private var rejectTick = 0

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
                Text(AppSettings.lrclibEnabled
                     ? "No está en tu servidor ni en LRCLIB. Puedes agregar un archivo .lrc con el mismo nombre que la canción en Jellyfin."
                     : "Agrega un archivo .lrc con el mismo nombre que la canción en tu servidor Jellyfin, o activa LRCLIB en Ajustes.")
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
                    if let source = lyrics.source, !selecting {
                        Text("Letra: \(source)")
                            .font(.caption.weight(.medium))
                            .opacity(0.5)
                            .padding(.top, 8)
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
                        selected = nil
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
                if selecting && selected != nil {
                    shareButton(lyrics)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Small tap on long-press and each line picked/unpicked.
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: selected) { _, new in
                new != nil
            }
            .sensoryFeedback(.warning, trigger: rejectTick)
        }
    }

    private func lineView(_ line: Lyrics.Line, isCurrent: Bool, synced: Bool) -> some View {
        let isSelected = selected?.contains(line.id) ?? false
        let opacity: Double = selecting
            ? (isSelected ? 1 : (canReach(line) ? 0.4 : 0.2))
            : (synced ? (isCurrent ? 1 : 0.35) : 0.9)
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
            .onLongPressGesture(minimumDuration: 0.25) {
                guard !line.text.isEmpty else { return }
                withAnimation {
                    selecting = true
                    selected = line.id...line.id
                }
            }
    }

    /// Whether tapping this line can grow the block to include it.
    private func canReach(_ line: Lyrics.Line) -> Bool {
        guard let r = selected else { return true }
        let span = max(r.upperBound, line.id) - min(r.lowerBound, line.id) + 1
        return span <= Self.maxSelection
    }

    /// Tapping outside the block grows it up to that line (filling any gap);
    /// tapping its first/last line removes it; tapping a middle line trims the
    /// block so it ends there.
    private func toggle(_ line: Lyrics.Line) {
        withAnimation(.easeOut(duration: 0.2)) {
            guard let r = selected else {
                if !line.text.isEmpty { selected = line.id...line.id }
                return
            }
            let i = line.id
            if r.contains(i) {
                if r.count == 1 {
                    selected = nil
                    selecting = false // last line removed → leave
                } else if i == r.lowerBound {
                    selected = (i + 1)...r.upperBound
                } else if i == r.upperBound {
                    selected = r.lowerBound...(i - 1)
                } else {
                    selected = r.lowerBound...i
                }
            } else if canReach(line) {
                selected = min(r.lowerBound, i)...max(r.upperBound, i)
            } else {
                rejectTick += 1
            }
        }
    }

    private func shareButton(_ lyrics: Lyrics) -> some View {
        Button {
            guard let r = selected else { return }
            // Song order; instrumental "♪" gaps inside the block are skipped.
            let lines = lyrics.lines.filter { r.contains($0.id) && !$0.text.isEmpty }.map(\.text)
            guard !lines.isEmpty else { return }
            onShare(lines)
            withAnimation { selecting = false; selected = nil }
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
    case color, artwork, light, photo, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: "Color"
        case .artwork: "Portada"
        case .light: "Claro"
        case .photo: "Foto"
        case .video: "Video"
        }
    }
    /// Styles over the user's own media, where the card can be moved/resized.
    var isMedia: Bool { self == .photo || self == .video }
}

/// What to draw: everything, or (for video export) only the card on a
/// transparent canvas / only the card's shape as a mask.
enum CardLayer { case full, overlay, mask }

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
    var layer: CardLayer = .full
    /// Live preview over video: frosted glass with a real material.
    var liveGlass = false

    static let scaleRange: ClosedRange<CGFloat> = 0.5...1.15

    private var offsetPoints: CGSize { CGSize(width: cardOffset.width * width, height: cardOffset.height * width) }

    private var s: CGFloat { width / 360 }
    /// Metric unit for everything inside the card.
    private var k: CGFloat { s * cardScale }
    private var sidePadding: CGFloat { max(8 * s, (width - (width - 52 * s) * cardScale) / 2) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18 * k, style: .continuous) }
    private var isGlass: Bool { (style == .photo && photo != nil) || style == .video }

    private var cardColor: UIColor {
        switch style {
        case .color: baseColor.adjusted(brightness: 0.45...0.7, minSaturation: 0.4)
        case .artwork, .photo, .video: .black
        case .light: UIColor(white: 0.97, alpha: 1)
        }
    }

    private var foreground: Color {
        switch style {
        case .light: .black
        case .artwork, .photo, .video: .white
        case .color: cardColor.luminance > 0.62 ? .black : .white
        }
    }

    var body: some View {
        ZStack {
            switch layer {
            case .full:
                canvas
                if isGlass, let photo {
                    // Same photo, blurred, visible only where the card is.
                    FillImage(image: photo, blur: 15 * s).mask { cardShapeMask }
                }
                card.padding(.horizontal, sidePadding).offset(offsetPoints)
            case .overlay:
                Color.clear
                card.padding(.horizontal, sidePadding).offset(offsetPoints)
            case .mask:
                Color.clear
                cardShapeMask
            }
        }
        .frame(width: width, height: width * 16 / 9)
        .clipped()
    }

    private var cardShapeMask: some View {
        content.background(Color.black).clipShape(shape)
            .padding(.horizontal, sidePadding)
            .offset(offsetPoints)
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
        case .color, .video:
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
                    Text(artist).font(.system(size: 14 * k, weight: .semibold)).opacity(0.75).lineLimit(1)
                }
            }

            Text(lines.joined(separator: "\n"))
                .font(.system(size: (lines.count > 4 ? 22 : 26) * k, weight: .heavy))
                .lineSpacing(4 * k)
                .fixedSize(horizontal: false, vertical: true)
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
                        if liveGlass { Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark).opacity(0.75) }
                        Color.black.opacity(0.08)
                        LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.02)],
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
    // Video style
    @State private var videoURL: URL?
    @State private var pickingVideo = false
    @State private var loadingMedia = false
    @State private var exporting = false
    @State private var exported: ExportedVideo?
    @State private var shareFile: ShareableFile?

    private struct ExportedVideo {
        struct Key: Equatable { let video: URL; let scale: CGFloat; let offset: CGSize }
        let key: Key
        let url: URL
    }

    private var isMovable: Bool {
        (style == .photo && photo != nil) || (style == .video && videoURL != nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                    .contentShape(Rectangle())
                    .overlay { guides }
                    .gesture(cardGesture, including: isMovable ? .all : .subviews)
                    .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: snapCount)
                    .onTapGesture(count: 2) {
                        guard style.isMedia else { return }
                        cardScale = 1
                        cardOffset = .zero
                        render()
                    }

                Picker("Estilo", selection: $style) {
                    ForEach(CardStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if style == .video {
                    VStack(spacing: 6) {
                        Text(videoURL == nil ? "Videos de máximo 15 segundos"
                                             : "Pellizca para cambiar el tamaño · arrastra para moverla")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button { openPicker(video: true) } label: {
                            if loadingMedia {
                                ProgressView()
                            } else {
                                Label(videoURL == nil ? "Elegir video de la galería" : "Cambiar video",
                                      systemImage: "video")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .disabled(loadingMedia)
                    }
                } else if style == .photo {
                    VStack(spacing: 6) {
                        if photo != nil {
                            Text("Pellizca para cambiar el tamaño · arrastra para moverla")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button { openPicker(video: false) } label: {
                            Label(photo == nil ? "Elegir foto de la galería" : "Cambiar foto",
                                  systemImage: "photo.on.rectangle")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }

                if style == .video {
                    videoButtons
                } else {
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
                if new == .photo && photo == nil { openPicker(video: false) }
                if new == .video && videoURL == nil { openPicker(video: true) }
                render()
            }
            .photosPicker(isPresented: $showPicker, selection: $photoItem,
                          matching: pickingVideo ? .videos : .images)
            .onChange(of: showPicker) { _, open in
                guard !open else { return }
                // Closed the picker without choosing anything → back to the previous look.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard photoItem == nil, !loadingMedia else { return }
                    if (style == .photo && photo == nil) || (style == .video && videoURL == nil) { style = .color }
                }
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if pickingVideo { await loadVideo(newItem) } else { await loadPhoto(newItem) }
                    photoItem = nil
                }
            }
            .sheet(item: $shareFile) { file in
                ShareSheet(items: [file.url]).presentationDetents([.medium, .large])
            }
            .onDisappear {
                for url in [videoURL, exported?.url].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        .environment(\.colorScheme, .light)
    }

    static let previewWidth: CGFloat = 250

    @ViewBuilder private var preview: some View {
        if style == .video, let videoURL {
            ZStack {
                LoopingVideoView(url: videoURL)
                card(width: Self.previewWidth, live: true, layer: .overlay, liveGlass: true)
            }
            .frame(width: Self.previewWidth, height: Self.previewWidth * 16 / 9)
        } else {
            card(width: Self.previewWidth, live: true)
        }
    }

    /// Size/position only apply to photo/video styles; `live` adds the in-flight gesture.
    private func card(width: CGFloat, live: Bool = false, layer: CardLayer = .full,
                      liveGlass: Bool = false) -> LyricsCard {
        let movable = style.isMedia
        return LyricsCard(title: item.title, artist: item.trackArtist, lines: lines,
                          artwork: artwork, baseColor: baseColor, style: style, photo: photo,
                          cardScale: movable ? (live ? liveScale : cardScale) : 1,
                          cardOffset: movable ? (live ? liveOffset : cardOffset) : .zero,
                          width: width, layer: layer, liveGlass: liveGlass)
    }

    private var videoButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task { if let url = await exportVideo() { shareFile = ShareableFile(url: url) } }
            } label: {
                Label("Compartir", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                Task {
                    guard let url = await exportVideo() else { return }
                    let ok = await PhotoSaver.saveVideo(url)
                    await showToast(ok ? "Video guardado en Fotos" : "Permite el acceso a Fotos en Ajustes")
                }
            } label: {
                Label("Guardar en Fotos", systemImage: "photo.badge.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(videoURL == nil || exporting)
        .overlay {
            if exporting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Creando video…").font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private func openPicker(video: Bool) {
        pickingVideo = video
        showPicker = true
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
        if isDragging && style.isMedia {
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

    private func loadVideo(_ pick: PhotosPickerItem) async {
        loadingMedia = true
        defer { loadingMedia = false }
        guard let movie = try? await pick.loadTransferable(type: PickedMovie.self) else {
            if videoURL == nil { style = .color }
            await showToast("No se pudo abrir el video")
            return
        }
        let seconds = await VideoCardExporter.duration(of: movie.url) ?? .infinity
        // Small tolerance: "15 s" clips are often 15.0x s long.
        guard seconds <= VideoCardExporter.maxDuration + 0.5 else {
            try? FileManager.default.removeItem(at: movie.url)
            if videoURL == nil { style = .color }
            let shown = seconds.isFinite ? "dura \(Int(seconds.rounded())) s" : "no se pudo leer"
            await showToast("Ese video \(shown). Elige uno de máximo 15 s")
            return
        }
        if let old = videoURL { try? FileManager.default.removeItem(at: old) }
        videoURL = movie.url
    }

    /// Renders the MP4 for the current video/size/position (reused if nothing changed).
    private func exportVideo() async -> URL? {
        guard let videoURL else { return nil }
        let key = ExportedVideo.Key(video: videoURL, scale: cardScale, offset: cardOffset)
        if let exported, exported.key == key { return exported.url }
        guard let overlay = renderLayer(.overlay), let mask = renderLayer(.mask) else { return nil }
        exporting = true
        defer { exporting = false }
        do {
            let url = try await VideoCardExporter.export(video: videoURL, overlay: overlay, mask: mask, blur: 34)
            if let old = exported?.url { try? FileManager.default.removeItem(at: old) }
            exported = ExportedVideo(key: key, url: url)
            return url
        } catch {
            await showToast(error.localizedDescription)
            return nil
        }
    }

    private func renderLayer(_ layer: CardLayer) -> UIImage? {
        let renderer = ImageRenderer(content: card(width: 360, layer: layer))
        renderer.scale = 3 // 1080 × 1920
        renderer.isOpaque = false
        return renderer.uiImage
    }

    private func showToast(_ message: String) async {
        withAnimation { toast = message }
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { if toast == message { toast = nil } }
    }

    private func render() {
        guard style != .video else { return }
        let renderer = ImageRenderer(content: card(width: 360))
        renderer.scale = 3 // 1080 × 1920
        rendered = renderer.uiImage
    }

    private func save() async {
        guard let rendered else { return }
        let ok = await PhotoSaver.save(rendered)
        await showToast(ok ? "Guardada en Fotos" : "Permite el acceso a Fotos en Ajustes")
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

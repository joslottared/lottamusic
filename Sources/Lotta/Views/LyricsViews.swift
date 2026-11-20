import Photos
import PhotosUI
import SwiftUI

/// Lines picked for a lyric card, with their timing when the lyrics are synced.
struct LyricsSelection {
    var lines: [String]
    /// Song time where the first selected line starts (synced lyrics only).
    var start: Double?
    /// Seconds from the first selected line to each line (synced lyrics only).
    var offsets: [Double]?
    /// Fragment length in seconds: until the next line starts (last line held ≤ 5 s).
    var duration: Double?

    static let maxVideoDuration: Double = 20
    var canAnimate: Bool { offsets != nil && (duration ?? .infinity) <= Self.maxVideoDuration }
}

/// Synced lyrics with Spotify/Apple Music-style line selection for sharing.
struct LyricsView: View {
    let lyrics: Lyrics?
    let loaded: Bool
    var onShare: (LyricsSelection) -> Void

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
                Text(AppSettings.lrclibEnabled || AppSettings.neteaseEnabled
                     ? "No se encontró en tu servidor ni en las bases de letras. Puedes agregar un archivo .lrc con el mismo nombre que la canción en Jellyfin."
                     : "Agrega un archivo .lrc con el mismo nombre que la canción en tu servidor Jellyfin, o activa LRCLIB/NetEase en Ajustes.")
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
            let picked = lyrics.lines.filter { r.contains($0.id) && !$0.text.isEmpty }
            guard !picked.isEmpty else { return }
            var selection = LyricsSelection(lines: picked.map(\.text))
            let starts = picked.compactMap(\.start)
            if lyrics.isSynced, starts.count == picked.count, let t0 = starts.first, let last = starts.last {
                let next = lyrics.lines.dropFirst(r.upperBound + 1).first { $0.start != nil }?.start
                let songEnd = player.duration > 0 ? player.duration : last + 5
                let end = min(next ?? songEnd, last + 5)
                selection.start = t0
                selection.offsets = starts.map { $0 - t0 }
                selection.duration = max(end - t0, last - t0 + 1.5)
            }
            onShare(selection)
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
/// transparent canvas / only the card's shape as a mask / only what's behind
/// the card (canvas plus the frosted-photo region) for still backgrounds.
enum CardLayer { case full, overlay, mask, background }

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
    /// Per-line opacity for animated lyrics (nil = all lines fully visible).
    /// Hidden lines keep their space so the card never changes size.
    var lineOpacities: [Double]? = nil
    /// Animated mode: the card is one line tall (the tallest line) and lines
    /// replace each other in place.
    var singleLine = false
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
            case .background:
                canvas
                if isGlass, let photo {
                    FillImage(image: photo, blur: 15 * s).mask { cardShapeMask }
                }
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

            Group {
                if singleLine {
                    ZStack(alignment: .leading) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in lyricLine(line, i) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4 * k) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in lyricLine(line, i) }
                    }
                }
            }
            .font(.system(size: (singleLine || lines.count <= 4 ? 26 : 22) * k, weight: .heavy))
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22 * k)
    }

    private func lyricLine(_ line: String, _ i: Int) -> some View {
        Text(line)
            .lineSpacing(4 * k)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(lineOpacities.map { $0.indices.contains(i) ? $0[i] : 1 } ?? 1)
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
    @EnvironmentObject private var downloads: DownloadManager
    let item: BaseItem
    let selection: LyricsSelection
    private var lines: [String] { selection.lines }

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
    @State private var videoLength: Double = 0
    /// Where the used part of the gallery video starts (seconds).
    @State private var videoStart: Double = 0
    /// Same as videoStart, but only updated when a drag ends (drives the preview).
    @State private var committedStart: Double = 0
    @State private var pickingVideo = false
    @State private var loadingMedia = false
    @State private var exporting = false
    @State private var exported: ExportedVideo?
    @State private var shareFile: ShareableFile?
    // Animated lyrics (lines appear at their synced time)
    @State private var animated = false
    @State private var animationStart = Date()
    @State private var withSong = true
    @State private var song: (url: URL, temporary: Bool)?
    @State private var exportPhase = "Creando video…"
    @State private var exportTask: Task<Void, Never>?

    private var timeline: LyricTimeline? {
        guard let offsets = selection.offsets, let duration = selection.duration else { return nil }
        return LyricTimeline(offsets: offsets, duration: duration)
    }

    /// How much of the gallery video is used: the lyric fragment when
    /// animated, otherwise up to 15 s.
    private var clipLength: Double {
        let wanted = animated ? (timeline?.duration ?? VideoCardExporter.maxDuration) : VideoCardExporter.maxDuration
        return videoLength > 0 ? min(wanted, videoLength) : wanted
    }

    /// Keeps the chosen part inside the video when the clip length changes.
    private func clampVideoStart() {
        let maxStart = max(0, videoLength - clipLength)
        if videoStart > maxStart { videoStart = maxStart }
        committedStart = videoStart
    }

    /// Result is a video: video background and/or animated lyrics.
    private var makesVideo: Bool { style == .video || animated }

    private struct ExportedVideo {
        struct Key: Equatable {
            let style: CardStyle; let video: URL?; let videoStart: Double; let photo: Int?
            let scale: CGFloat; let offset: CGSize; let animated: Bool; let withSong: Bool
        }
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
                        if let videoURL, videoLength > clipLength + 0.5 {
                            VideoTrimmer(url: videoURL, videoLength: videoLength, clipLength: clipLength,
                                         start: $videoStart) { committedStart = videoStart }
                        } else {
                            Text(videoURL == nil ? "Si el video es largo, eliges qué parte usar"
                                                 : "Pellizca para cambiar el tamaño · arrastra para moverla")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

                if selection.offsets != nil { animationToggle }

                if makesVideo {
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
                exportTask?.cancel() // stop a render nobody will see
                let tempSong = song?.temporary == true ? song?.url : nil
                for url in [videoURL, exported?.url, tempSong].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        .environment(\.colorScheme, .light)
    }

    static let previewWidth: CGFloat = 250

    @ViewBuilder private var preview: some View {
        if animated, let timeline {
            // Plays the fragment on a loop (with a short pause at the end).
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSince(animationStart)
                    .truncatingRemainder(dividingBy: timeline.duration + 0.8)
                previewCard(opacities: timeline.opacities(at: min(t, timeline.duration)))
            }
        } else {
            previewCard(opacities: nil)
        }
    }

    @ViewBuilder private func previewCard(opacities: [Double]?) -> some View {
        if style == .video, let videoURL {
            ZStack {
                LoopingVideoView(url: videoURL, range: committedStart...(committedStart + clipLength))
                card(width: Self.previewWidth, live: true, layer: .overlay, liveGlass: true,
                     opacities: opacities)
            }
            .frame(width: Self.previewWidth, height: Self.previewWidth * 16 / 9)
        } else {
            card(width: Self.previewWidth, live: true, opacities: opacities)
        }
    }

    private var animationToggle: some View {
        VStack(spacing: 4) {
            Toggle(isOn: $animated) {
                Label("Letra animada", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(!selection.canAnimate)
            .onChange(of: animated) { _, on in
                if on { animationStart = Date() }
                clampVideoStart()
            }
            if animated {
                Toggle(isOn: $withSong) {
                    Label("Con el audio de la canción", systemImage: "music.note")
                        .font(.subheadline.weight(.medium))
                }
            }
            let seconds = Int((selection.duration ?? 0).rounded(.up))
            Text(selection.canAnimate
                 ? "Una línea a la vez, al ritmo de la canción · video de \(seconds) s"
                 : "El fragmento dura \(seconds) s. Selecciona menos líneas (máximo \(Int(LyricsSelection.maxVideoDuration)) s).")
                .font(.caption)
                .foregroundStyle(selection.canAnimate ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Size/position only apply to photo/video styles; `live` adds the in-flight gesture.
    private func card(width: CGFloat, live: Bool = false, layer: CardLayer = .full,
                      liveGlass: Bool = false, opacities: [Double]? = nil) -> LyricsCard {
        let movable = style.isMedia
        return LyricsCard(title: item.title, artist: item.trackArtist, lines: lines,
                          artwork: artwork, baseColor: baseColor, style: style, photo: photo,
                          cardScale: movable ? (live ? liveScale : cardScale) : 1,
                          cardOffset: movable ? (live ? liveOffset : cardOffset) : .zero,
                          width: width, layer: layer, lineOpacities: opacities, singleLine: animated,
                          liveGlass: liveGlass)
    }

    private var videoButtons: some View {
        HStack(spacing: 12) {
            Button {
                exportTask = Task { if let url = await exportVideo() { shareFile = ShareableFile(url: url) } }
            } label: {
                Label("Compartir", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                exportTask = Task {
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
        .disabled((style == .video && videoURL == nil) || exporting)
        .overlay {
            if exporting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(exportPhase).font(.subheadline.weight(.medium))
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
        guard seconds <= VideoCardExporter.maxSourceDuration else {
            try? FileManager.default.removeItem(at: movie.url)
            if videoURL == nil { style = .color }
            await showToast(seconds.isFinite ? "Ese video es muy largo. Elige uno de máximo 5 min"
                                             : "No se pudo leer el video")
            return
        }
        if let old = videoURL { try? FileManager.default.removeItem(at: old) }
        videoLength = seconds
        videoStart = 0
        committedStart = 0
        videoURL = movie.url
    }

    /// Renders the MP4 for the current look (reused if nothing changed).
    private func exportVideo() async -> URL? {
        if style == .video && videoURL == nil { return nil }
        let key = ExportedVideo.Key(style: style, video: style == .video ? videoURL : nil, videoStart: videoStart,
                                    photo: photo.map { ObjectIdentifier($0).hashValue },
                                    scale: cardScale, offset: cardOffset, animated: animated,
                                    withSong: animated && withSong)
        if let exported, exported.key == key { return exported.url }
        exporting = true
        defer { exporting = false }
        do {
            let url: URL
            if animated, let timeline {
                // One overlay per step: nothing, line 1, lines 1-2 (1 dimmed)…
                let states = (0...lines.count).compactMap { renderLayer(.overlay, opacities: timeline.state($0)) }
                let background: CardVideoWriter.Background
                if style == .video, let videoURL, let mask = renderLayer(.mask) {
                    background = .video(videoURL, start: videoStart, mask: mask, blur: 34)
                } else if let still = renderLayer(.background) {
                    background = .still(still)
                } else { return nil }
                var audio: (url: URL, start: Double)?
                if withSong, let start = selection.start {
                    if song == nil {
                        exportPhase = "Obteniendo la canción…"
                        song = try? await SongAudio.file(for: item, downloads: downloads)
                    }
                    if let song { audio = (song.url, start) }
                    else { await showToast("No se pudo obtener la canción; el video va sin audio") }
                }
                exportPhase = "Creando video…"
                url = try await CardVideoWriter.write(background: background, states: states,
                                                      timeline: timeline, audio: audio) { p in
                    exportPhase = "Creando video… \(Int(p * 100))%"
                }
            } else if let videoURL, let overlay = renderLayer(.overlay), let mask = renderLayer(.mask) {
                url = try await VideoCardExporter.export(video: videoURL, start: videoStart, length: clipLength,
                                                         overlay: overlay, mask: mask, blur: 34)
            } else {
                return nil
            }
            if let old = exported?.url { try? FileManager.default.removeItem(at: old) }
            exported = ExportedVideo(key: key, url: url)
            return url
        } catch {
            await showToast(error.localizedDescription)
            return nil
        }
    }

    private func renderLayer(_ layer: CardLayer, opacities: [Double]? = nil) -> UIImage? {
        let renderer = ImageRenderer(content: card(width: 360, layer: layer, opacities: opacities))
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

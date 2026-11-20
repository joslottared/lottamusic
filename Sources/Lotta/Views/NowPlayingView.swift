import SwiftUI

private enum NowPlayingPanel { case artwork, lyrics, queue }

struct ShareRequest: Identifiable {
    let id = UUID()
    let item: BaseItem
    let selection: LyricsSelection
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadManager
    @State private var panel: NowPlayingPanel = .artwork
    @State private var lyrics: Lyrics?
    @State private var lyricsLoaded = false
    @State private var share: ShareRequest?
    @State private var dragOffset: CGFloat = 0
    @State private var swipeOffset: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var skipCount = 0
    @State private var addToPlaylist: BaseItem?
    @State private var selectionRequest = 0
    @Environment(\.dismiss) private var dismiss

    /// One drag, two meanings, decided by the first movement:
    /// vertical (down) closes the player, horizontal changes track.
    /// Measured in global space: in local space the view moves with the
    /// finger and the drag lags.
    private var playerDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { g in
                let t = g.translation
                if dragAxis == nil {
                    dragAxis = abs(t.width) > abs(t.height) ? .horizontal : .vertical
                }
                switch dragAxis {
                case .vertical: dragOffset = max(0, t.height)
                case .horizontal: swipeOffset = panel == .artwork ? t.width : 0
                case nil: break
                }
            }
            .onEnded { g in
                let axis = dragAxis
                dragAxis = nil
                if axis == .vertical {
                    if dragOffset > 100 || (dragOffset > 0 && g.predictedEndTranslation.height > 260) {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                    }
                } else if axis == .horizontal, panel == .artwork {
                    let w = g.translation.width, predicted = g.predictedEndTranslation.width
                    if w < -80 || predicted < -220 {
                        player.next()
                        skipCount += 1
                    } else if w > 80 || predicted > 220 {
                        player.previousTrack()
                        skipCount += 1
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { swipeOffset = 0 }
                }
            }
    }

    var body: some View {
        let item = player.current
        ZStack {
            // Opaque base: the presentation background is clear (for the
            // drag-down reveal), so the background must not be see-through.
            Color.black.ignoresSafeArea()
            AmbientBackground(itemId: item?.artworkItemId)

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    topBar(item).padding(.bottom, 12)

                    if panel != .artwork, let item {
                        compactHeader(item).padding(.bottom, 8)
                    }
                }
                .contentShape(Rectangle())
                .gesture(playerDrag)

                Group {
                    switch panel {
                    case .artwork:
                        ArtworkView(itemId: item?.artworkItemId, size: ArtworkSize.large, cornerRadius: 30)
                            .frame(maxWidth: 310, maxHeight: 310)
                            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                            .scaleEffect(player.isPlaying ? 1 : 0.86)
                            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                            .offset(x: swipeOffset)
                            .opacity(1 - min(0.5, abs(swipeOffset) / 400))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(playerDrag)
                    case .lyrics:
                        LyricsView(lyrics: lyrics, loaded: lyricsLoaded, onShare: { selection in
                            if let item { share = ShareRequest(item: item, selection: selection) }
                        }, selectionRequest: selectionRequest)
                    case .queue:
                        QueueView()
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)

                if panel == .artwork, let item {
                    titleRow(item)
                        .padding(.top, 18)
                        .contentShape(Rectangle())
                        .simultaneousGesture(playerDrag)
                }

                if let item { badgeRow(item).padding(.top, 8) }

                Scrubber().padding(.top, 8)
                controls.padding(.vertical, 14)
                bottomBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .offset(y: dragOffset)
        .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
        .presentationBackground(.clear) // the app shows behind while dragging down
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .sheet(item: $share) { req in
            LyricsShareView(item: req.item, selection: req.selection)
        }
        .sheet(item: $addToPlaylist) { item in
            AddToPlaylistView(tracks: [item])
                .environment(\.colorScheme, .light)
        }
        .task(id: item?.id) {
            lyrics = nil
            lyricsLoaded = false
            guard let item else { return }
            lyrics = await LyricsStore.shared.lyrics(for: item)
            lyricsLoaded = true
        }
    }

    // MARK: Top

    private func topBar(_ item: BaseItem?) -> some View {
        GlassCapsule {
            GlassCircleButton(systemImage: "chevron.down", accessibilityLabel: "Cerrar", style: .inset) {
                dismiss()
            }
        } center: {
            VStack(spacing: 1) {
                Text("Sonando desde").lottaLabel().opacity(0.65)
                Text(item?.album ?? item?.trackArtist ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lottaLower()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } trailing: {
            AirPlayButton()
                .frame(width: 46, height: 46)
                .background(Circle().fill(Theme.glassFill))
                .accessibilityLabel("AirPlay")
        }
    }

    private func compactHeader(_ item: BaseItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: item.artworkItemId, cornerRadius: 10)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lottaLower().lineLimit(1)
                Text(item.trackArtist).font(.subheadline).lottaLower().opacity(0.7).lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: Title, badges

    private func titleRow(_ item: BaseItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title2.bold()).lottaLower().lineLimit(1)
                Text(item.trackArtist).font(.title3).lottaLower().opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
            // Placeholder: favorites aren't implemented yet.
            GlassCircleButton(systemImage: "heart", accessibilityLabel: "Favorito (próximamente)", size: 44) {}
                .disabled(true)
        }
    }

    private func badgeRow(_ item: BaseItem) -> some View {
        let badges = downloads.formatBadges(for: item.id) + ((lyrics?.isSynced ?? false) ? ["LRC"] : [])
        let hasLyrics = !(lyrics?.lines.isEmpty ?? true)
        return HStack(spacing: 6) {
            ForEach(badges, id: \.self) { TechBadge(text: $0) }
            Spacer(minLength: 0)
            if hasLyrics {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { panel = .lyrics }
                    selectionRequest += 1
                } label: {
                    Text("Crear tarjeta ›")
                        .font(.footnote.weight(.semibold))
                        .lottaLower()
                        .frame(minHeight: Theme.minTap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.85)
                .accessibilityLabel("Crear tarjeta con la letra")
            }
        }
        .frame(minHeight: Theme.minTap)
    }

    // MARK: Transport

    private var controls: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "backward.fill", accessibilityLabel: "Anterior", size: 64) {
                player.previous()
            }
            Spacer(minLength: 0)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Theme.darkBackground)
                    .frame(width: 86, height: 86)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pausa" : "Reproducir")
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "forward.fill", accessibilityLabel: "Siguiente", size: 64) {
                player.next()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        // Full pills when they fit; icon-only pills with big text sizes.
        ViewThatFits(in: .horizontal) {
            bottomRow(compact: false)
            bottomRow(compact: true)
        }
    }

    private func bottomRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            panelPill(.lyrics, icon: "quote.bubble", title: "Letra", compact: compact)
            panelPill(.queue, icon: "list.bullet", title: "Cola", compact: compact)
            if let item = player.current { downloadPill(item, compact: compact) }
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "shuffle",
                              accessibilityLabel: player.isShuffled ? "Desactivar aleatorio" : "Aleatorio",
                              size: 44, isActive: player.isShuffled) {
                player.toggleShuffle()
            }
            GlassCircleButton(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                              accessibilityLabel: "Repetir", size: 44,
                              isActive: player.repeatMode != .off) {
                player.repeatMode = player.repeatMode.next
            }
        }
    }

    private func panelPill(_ target: NowPlayingPanel, icon: String, title: String, compact: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { panel = panel == target ? .artwork : target }
        } label: {
            GlassPill(systemImage: icon, title: compact ? "" : title, isActive: panel == target)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(panel == target ? .isSelected : [])
    }

    private func downloadPill(_ item: BaseItem, compact: Bool) -> some View {
        let state = downloads.state(for: item.id)
        let (icon, title): (String, String) = switch state {
        case .done: ("checkmark.circle.fill", "Guardada")
        case .downloading, .queued: ("arrow.down.circle.dotted", "Descargando")
        default: ("arrow.down.circle", "Descargar")
        }
        return Menu {
            Button { addToPlaylist = item } label: {
                Label("Añadir a playlist…", systemImage: "music.note.list")
            }
            if downloads.isDownloaded(item.id) {
                Button(role: .destructive) { downloads.delete([item.id]) } label: {
                    Label("Eliminar descarga", systemImage: "trash")
                }
            } else if downloads.pending[item.id] == nil {
                Button { downloads.download([item]) } label: {
                    Label("Descargar", systemImage: "arrow.down.circle")
                }
            }
        } label: {
            GlassPill(systemImage: icon, title: compact ? "" : title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Format tags for the track that's playing, from data the app already has:
/// the downloaded file's type, or the streaming quality when it's a fixed MP3.
/// Unknown (original-quality streaming) → no tag.
extension DownloadManager {
    func formatBadges(for id: String) -> [String] {
        if let file = downloaded[id]?.fileName {
            let ext = (file as NSString).pathExtension.lowercased()
            return ext.isEmpty ? [] : [ext.uppercased()]
        }
        switch AppSettings.streamQuality {
        case .original: return []
        case .high: return ["MP3", "320"]
        case .saver: return ["MP3", "192"]
        }
    }
}

struct Scrubber: View {
    @EnvironmentObject private var player: Player
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let value = dragValue ?? player.currentTime
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = max(0, min(w, w * value / duration))
                let thumb: CGFloat = dragValue == nil ? 14 : 22
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 6)
                    Capsule().fill(.white).frame(width: x, height: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        .offset(x: min(max(0, x - thumb / 2), w - thumb))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in dragValue = min(max(0, g.location.x / w), 1) * duration }
                        .onEnded { _ in
                            if let v = dragValue { player.seek(to: v) }
                            dragValue = nil
                        }
                )
            }
            .frame(height: 28)
            .animation(.easeOut(duration: 0.15), value: dragValue == nil)
            .accessibilityElement()
            .accessibilityLabel("Posición")
            .accessibilityValue(formatTime(value))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: player.seek(to: min(duration, player.currentTime + 10))
                case .decrement: player.seek(to: max(0, player.currentTime - 10))
                @unknown default: break
                }
            }

            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit().monospaced())
            .opacity(0.6)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: Player
    /// Carousel of covers by default; the list is where tracks are removed.
    @AppStorage("lotta.queue.carousel") private var carousel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("A continuación").lottaLabel().foregroundStyle(.white.opacity(0.7))
                Spacer()
                GlassCircleButton(systemImage: carousel ? "list.bullet" : "square.stack",
                                  accessibilityLabel: carousel ? "Ver como lista" : "Ver como carrusel",
                                  size: 44) {
                    withAnimation(.easeInOut(duration: 0.25)) { carousel.toggle() }
                }
            }
            if player.upNext.isEmpty {
                Text("No hay más canciones en la cola.")
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if carousel {
                QueueCarousel()
                    .transition(.opacity)
            } else {
                queueList
                    .transition(.opacity)
            }
        }
    }

    private var queueList: some View {
        let start = player.index + 1
        return List {
            ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, item in
                HStack(spacing: 12) {
                    ArtworkView(itemId: item.artworkItemId, cornerRadius: 8).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lottaLower().lineLimit(1)
                        Text(item.trackArtist).font(.caption).lottaLower().opacity(0.6).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { player.jump(to: start + offset) }
                .swipeActions {
                    Button(role: .destructive) { player.removeFromQueue(at: start + offset) } label: {
                        Label("Quitar", systemImage: "minus.circle")
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Up next as a 3D carousel of covers. Tapping one jumps to it.
private struct QueueCarousel: View {
    @EnvironmentObject private var player: Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let start = player.index + 1
        GeometryReader { geo in
            let side = max(80, min(geo.size.height - 70, geo.size.width * 0.62, 240))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, item in
                        Button { player.jump(to: start + offset) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ArtworkView(itemId: item.artworkItemId, cornerRadius: 22)
                                    .frame(width: side, height: side)
                                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).lottaLower().lineLimit(1)
                                    Text(item.trackArtist).font(.caption).lottaLower().opacity(0.6).lineLimit(1)
                                }
                                .frame(width: side, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.title), \(item.trackArtist)")
                        .accessibilityHint("Reproducir ahora")
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .rotation3DEffect(.degrees(reduceMotion ? 0 : phase.value * -32),
                                                  axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                .scaleEffect(1 - abs(phase.value) * 0.14)
                                .opacity(1 - abs(phase.value) * 0.35)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, max(0, (geo.size.width - side) / 2), for: .scrollContent)
            .frame(maxHeight: .infinity)
        }
    }
}

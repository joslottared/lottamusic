import SwiftUI

private enum NowPlayingPanel { case artwork, lyrics, queue }

struct ShareRequest: Identifiable {
    let id = UUID()
    let item: BaseItem
    let lines: [String]
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadManager
    @State private var panel: NowPlayingPanel = .artwork
    @State private var lyrics: Lyrics?
    @State private var lyricsLoaded = false
    @State private var background = Color(white: 0.2)
    @State private var share: ShareRequest?
    @State private var dragOffset: CGFloat = 0
    @State private var swipeOffset: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var skipCount = 0
    @State private var addToPlaylist: BaseItem?
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
            // drag-down reveal), so the gradient must not be see-through.
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [background, background.opacity(0.55), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .opacity(0.8)
                        .onTapGesture { dismiss() }
                        .padding(.bottom, 8)

                    if panel != .artwork, let item {
                        compactHeader(item).padding(.bottom, 8)
                    }
                }
                .contentShape(Rectangle())
                .gesture(playerDrag)

                Group {
                    switch panel {
                    case .artwork:
                        ArtworkView(itemId: item?.artworkItemId, size: ArtworkSize.large, cornerRadius: 12)
                            .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
                            .scaleEffect(player.isPlaying ? 1 : 0.86)
                            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                            .offset(x: swipeOffset)
                            .opacity(1 - min(0.5, abs(swipeOffset) / 400))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(playerDrag)
                    case .lyrics:
                        LyricsView(lyrics: lyrics, loaded: lyricsLoaded) { lines in
                            if let item { share = ShareRequest(item: item, lines: lines) }
                        }
                    case .queue:
                        QueueView()
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)

                if panel == .artwork, let item {
                    titleRow(item)
                        .padding(.top, 20)
                        .contentShape(Rectangle())
                        .simultaneousGesture(playerDrag)
                }

                Scrubber().padding(.top, 18)
                controls.padding(.vertical, 18)
                bottomBar
            }
            .padding(.horizontal, 26)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .offset(y: dragOffset)
        .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
        .presentationBackground(.clear) // the app shows behind while dragging down
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .sheet(item: $share) { req in
            LyricsShareView(item: req.item, lines: req.lines)
        }
        .sheet(item: $addToPlaylist) { item in
            AddToPlaylistView(tracks: [item])
                .environment(\.colorScheme, .light)
        }
        .task(id: item?.id) {
            lyrics = nil
            lyricsLoaded = false
            guard let item else { return }
            if let img = await ArtworkCache.shared.image(for: item.artworkItemId, size: ArtworkSize.large),
               let avg = img.averageColor {
                let c = Color(uiColor: avg.adjusted(brightness: 0.28...0.55, minSaturation: 0.35))
                withAnimation(.easeInOut(duration: 0.6)) { background = c }
            }
            lyrics = await LyricsStore.shared.lyrics(for: item)
            lyricsLoaded = true
        }
    }

    private func compactHeader(_ item: BaseItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: item.artworkItemId, cornerRadius: 6)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.trackArtist).font(.subheadline).opacity(0.7).lineLimit(1)
            }
            Spacer()
        }
    }

    private func titleRow(_ item: BaseItem) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title3.bold()).lineLimit(1)
                Text(item.trackArtist).font(.title3).opacity(0.7).lineLimit(1)
            }
            Spacer()
            Menu {
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
                Image(systemName: "ellipsis")
                    .font(.body.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.15), in: Circle())
            }
        }
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 70, height: 70)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack {
            panelButton(.lyrics, icon: "quote.bubble")
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            Button { player.repeatMode = player.repeatMode.next } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .opacity(player.repeatMode == .off ? 0.55 : 1)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            panelButton(.queue, icon: "list.bullet")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    private func panelButton(_ target: NowPlayingPanel, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { panel = panel == target ? .artwork : target }
        } label: {
            Image(systemName: icon)
                .frame(width: 44, height: 44)
                .background(panel == target ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 10))
                .opacity(panel == target ? 1 : 0.7)
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
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(dragValue == nil ? 0.75 : 1))
                        .frame(width: max(0, min(w, w * value / duration)))
                }
                .frame(height: dragValue == nil ? 6 : 11)
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
            .frame(height: 22)
            .animation(.easeOut(duration: 0.15), value: dragValue == nil)

            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit())
            .opacity(0.6)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        let start = player.index + 1
        List {
            Section {
                if player.upNext.isEmpty {
                    Text("No hay más canciones en la cola.").opacity(0.6)
                }
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, item in
                    HStack(spacing: 12) {
                        ArtworkView(itemId: item.artworkItemId, cornerRadius: 4).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(1)
                            Text(item.trackArtist).font(.caption).opacity(0.6).lineLimit(1)
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
            } header: {
                Text("A continuación").font(.headline).foregroundStyle(.white)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

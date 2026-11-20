import SwiftUI

enum LibraryTab: String, CaseIterable {
    case albums, artists, playlists
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var player: Player
    @Environment(\.openPlayer) private var openPlayer
    @Environment(\.selectTab) private var selectTab
    @AppStorage("lotta.library.tab") private var tab: LibraryTab = .albums
    @AppStorage("lotta.library.downloadedOnly") private var downloadedOnly = false
    @State private var showSettings = false
    @State private var songCount = 0

    private var onlyDownloaded: Bool { downloadedOnly || !network.isOnline }

    private var albums: [BaseItem] {
        onlyDownloaded ? downloads.downloadedAlbums : library.albums
    }

    private var artists: [BaseItem] {
        guard onlyDownloaded else { return library.artists }
        let names = Set(downloads.downloadedAlbums.compactMap(\.albumArtist))
        return library.artists.filter { names.contains($0.title) }
    }

    private var playlists: [BaseItem] {
        onlyDownloaded ? downloads.downloadedPlaylists : library.playlists
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                serverCapsule

                Text(player.current != nil ? "Sigue donde lo dejaste" : "Tu biblioteca")
                    .lottaEditorial(size: 44, weight: .heavy)
                    .lottaLower()
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)

                if player.current != nil {
                    ResumeStack()
                }

                filterPills

                if let sync = library.sync {
                    SyncProgressRow(sync: sync)
                        .padding(12)
                        .lottaGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if !network.isOnline {
                    Label(network.hasNetwork ? "Servidor no disponible · mostrando tus descargas"
                                             : "Sin conexión · mostrando tus descargas",
                          systemImage: network.hasNetwork ? "server.rack" : "wifi.slash")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if let err = library.lastError, library.albums.isEmpty {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }

                Group {
                    switch tab {
                    case .albums:
                        if albums.isEmpty { emptyState } else { AlbumGrid(albums: albums).padding(.horizontal, -16) }
                    case .playlists:
                        if playlists.isEmpty { emptyState } else { PlaylistList(playlists: playlists).padding(.horizontal, -16) }
                    case .artists:
                        if artists.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(artists) { artist in
                                    NavigationLink(value: artist) {
                                        ArtistRow(artist: artist).padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 60)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .animation(.spring(response: 0.35), value: library.isSyncing)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.darkBackground.ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .navigationTitle("biblioteca") // only shown as the back button
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await library.refresh() }
        .task { if library.albums.isEmpty { await library.refresh() } }
        .task(id: library.albums.count &+ (library.lastSync.map { Int($0.timeIntervalSince1970) } ?? 0)) {
            songCount = library.albums.reduce(0) { $0 + library.cachedTracks(albumId: $1.id).count }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: Server capsule

    private var statusColor: Color {
        if network.isOnline { return .green }
        return network.hasNetwork ? .orange : .gray
    }

    private var serverCapsule: some View {
        GlassCapsule {
            EmptyView()
        } center: {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: statusColor.opacity(0.8), radius: network.isOnline ? 4 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.creds?.serverURL.host ?? "Jellyfin")
                        .font(.subheadline.weight(.semibold))
                        .lottaLower()
                        .lineLimit(1)
                    if songCount > 0 {
                        Text("\(songCount) canciones").lottaLabel(mono: true).opacity(0.6)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Servidor \(model.creds?.serverURL.host ?? ""), \(network.isOnline ? "en línea" : "sin conexión"), \(songCount) canciones")
        } trailing: {
            if library.isSyncing {
                ProgressView()
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Theme.glassFill))
            } else {
                GlassCircleButton(systemImage: "arrow.triangle.2.circlepath",
                                  accessibilityLabel: "Sincronizar biblioteca", style: .inset) {
                    library.startSync()
                }
                .disabled(!network.isOnline)
            }
            GlassCircleButton(systemImage: "magnifyingglass", accessibilityLabel: "Buscar", style: .inset) {
                selectTab(.search)
            }
            GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Ajustes", style: .inset) {
                showSettings = true
            }
        }
    }

    // MARK: Filters

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(.albums, "Álbumes", icon: "square.grid.2x2")
                filterPill(.artists, "Artistas", icon: "music.mic")
                filterPill(.playlists, "Playlists", icon: "music.note.list")
                Button { downloadedOnly.toggle() } label: {
                    GlassPill(systemImage: downloadedOnly ? "arrow.down.circle.fill" : "arrow.down.circle",
                              title: "Descargado", isActive: downloadedOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Solo descargado")
                .accessibilityAddTraits(downloadedOnly ? .isSelected : [])
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func filterPill(_ value: LibraryTab, _ title: String, icon: String) -> some View {
        Button { tab = value } label: {
            GlassPill(systemImage: icon, title: title, isActive: tab == value)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    @ViewBuilder private var emptyState: some View {
        if library.isRefreshing {
            ProgressView().padding(.top, 60)
        } else if onlyDownloaded {
            ContentUnavailableView("Nada descargado aún", systemImage: "arrow.down.circle",
                                   description: Text("Abre un álbum y toca ↓ para escucharlo sin conexión."))
                .padding(.top, 40)
        } else {
            ContentUnavailableView("Biblioteca vacía", systemImage: "music.note.list",
                                   description: Text("Desliza hacia abajo para actualizar."))
                .padding(.top, 40)
        }
    }
}

/// Restored / current playback: three tilted covers and a glass panel to
/// pick up where you left off.
private struct ResumeStack: View {
    @EnvironmentObject private var player: Player
    @Environment(\.openPlayer) private var openPlayer

    /// Current track first, then what comes next (or what came before).
    private var covers: [BaseItem] {
        guard let current = player.current else { return [] }
        var out = [current]
        for item in player.upNext where out.count < 3 && !out.contains(where: { $0.artworkItemId == item.artworkItemId }) {
            out.append(item)
        }
        for item in player.queue.prefix(player.index).reversed() where out.count < 3
            && !out.contains(where: { $0.artworkItemId == item.artworkItemId }) {
            out.append(item)
        }
        return out
    }

    var body: some View {
        if let item = player.current {
            let covers = covers
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    ForEach(Array(covers.enumerated().reversed()), id: \.offset) { i, cover in
                        ArtworkView(itemId: cover.artworkItemId, cornerRadius: 16)
                            .frame(width: 118, height: 118)
                            .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                            .rotationEffect(.degrees([-4, 8, -12][i]))
                            .offset(x: CGFloat(i) * 14, y: CGFloat(i) * -6)
                            .opacity(i == 0 ? 1 : 0.85)
                    }
                }
                .frame(width: 150, height: 150)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Seguir").lottaLabel(tracking: 1.2).foregroundStyle(Theme.accentMark)
                    Text(item.title).font(.headline).lottaLower().lineLimit(2)
                    Text(item.trackArtist).font(.subheadline).lottaLower().opacity(0.65).lineLimit(1)
                    HStack(spacing: 10) {
                        GeometryReader { geo in
                            let f = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2))
                                Capsule().fill(Theme.accentMark).frame(width: geo.size.width * f)
                            }
                        }
                        .frame(height: 4)
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .font(.body.weight(.bold))
                                .foregroundStyle(Theme.darkBackground)
                                .frame(width: Theme.minTap, height: Theme.minTap)
                                .background(Circle().fill(.white))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(player.isPlaying ? "Pausa" : "Seguir reproduciendo")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lottaGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openPlayer)
            .accessibilityAction(named: "Abrir reproductor", openPlayer)
        }
    }
}

struct AlbumGrid: View {
    let albums: [BaseItem]
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        let downloadedIds = downloads.downloadedAlbumIds
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 22) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(itemId: album.id, cornerRadius: 14)
                        Text(album.title)
                            .font(.subheadline.weight(.semibold))
                            .lottaLower()
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if downloadedIds.contains(album.id) {
                                Image(systemName: "arrow.down.circle.fill").font(.caption2)
                                    .foregroundStyle(Theme.accentMark)
                                    .accessibilityLabel("Descargado")
                            }
                            Text(album.artistLine).lottaLower().lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}

struct AlbumView: View {
    let album: BaseItem

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: Player
    @State private var tracks: [BaseItem] = []
    @State private var loading = true
    @State private var addToPlaylist = false
    @State private var syncedLyrics: Set<String> = []

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))

            if loading && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track, badge: syncedLyrics.contains(track.id) ? "LRC" : nil)
                    .onTapGesture { player.play(tracks, startAt: i) }
                    .trackContextMenu(track)
                    .swipeActions(edge: .trailing) {
                        if downloads.isDownloaded(track.id) {
                            Button(role: .destructive) { downloads.delete([track.id]) } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        } else {
                            Button { downloads.download([track], album: album) } label: {
                                Label("Descargar", systemImage: "arrow.down")
                            }
                            .tint(Theme.accent)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.ink.opacity(0.1))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.cream.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .tint(Theme.accentInk)
        .preferredColorScheme(.light)
        .environment(\.colorScheme, .light)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addToPlaylist = true } label: { Image(systemName: "text.badge.plus") }
                    .disabled(tracks.isEmpty)
                    .accessibilityLabel("Añadir álbum a playlist")
            }
            ToolbarItem(placement: .topBarTrailing) { downloadButton }
        }
        .sheet(isPresented: $addToPlaylist) { AddToPlaylistView(tracks: tracks) }
        .task {
            tracks = library.cachedTracks(albumId: album.id)
            loading = true
            let fresh = await library.tracks(for: album)
            if !fresh.isEmpty { tracks = fresh }
            loading = false
        }
        .task(id: tracks.map(\.id)) {
            syncedLyrics = await CachedLyricsPeek.syncedIds(tracks.map(\.id))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .leading) {
                VinylDisc()
                    .frame(width: 210, height: 210)
                    .offset(x: 92)
                ArtworkView(itemId: album.id, size: ArtworkSize.large, cornerRadius: 6)
                    .frame(width: 230, height: 230)
                    .shadow(color: Theme.plum.opacity(0.25), radius: 18, y: 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .lottaEditorial(size: 40, weight: .heavy)
                    .lottaLower()
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(album.artistLine)
                    .font(.title3.weight(.semibold))
                    .lottaLower()
                    .foregroundStyle(Theme.accentInk)
                Text(dataLine)
                    .lottaLabel(mono: true, tracking: 1.0)
                    .foregroundStyle(Theme.plumSoft)
            }

            EditorialButtons(disabled: tracks.isEmpty,
                             play: { player.play(tracks) },
                             shuffle: { player.play(tracks, shuffle: true) })
        }
        .padding(.top, 8)
    }

    /// "2019 · 11 pistas · 46 min"
    private var dataLine: String {
        var parts: [String] = []
        if let y = album.productionYear { parts.append(String(y)) }
        if !tracks.isEmpty {
            let minutes = Int(tracks.compactMap(\.duration).reduce(0, +) / 60)
            parts.append("\(tracks.count) pistas")
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var downloadButton: some View {
        switch downloads.state(of: tracks) {
        case .done:
            Menu {
                Button(role: .destructive) { downloads.delete(albumId: album.id) } label: {
                    Label("Eliminar descarga", systemImage: "trash")
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
            }
        case .downloading(let p):
            Button { downloads.cancel(tracks.map(\.id)) } label: {
                ProgressRing(progress: p, lineWidth: 2.5)
                    .frame(width: 22, height: 22)
                    .overlay { Image(systemName: "stop.fill").font(.system(size: 7)) }
            }
        default:
            Button { downloads.download(tracks, album: album) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .disabled(tracks.isEmpty)
        }
    }
}

/// "reproducir" (filled) and "aleatorio" (outline) for the light editorial screens.
private struct EditorialButtons: View {
    var disabled: Bool
    var play: () -> Void
    var shuffle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Reproducir", systemImage: "play.fill")
                    .lottaLower()
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Theme.accent))
            }
            Button(action: shuffle) {
                Label("Aleatorio", systemImage: "shuffle")
                    .lottaLower()
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.ink)
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 1.5))
            }
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Reads the lyrics cache on disk (never the network) to tell which tracks
/// already have synced lyrics, for the LRC tag.
enum CachedLyricsPeek {
    private struct Entry: Decodable { var lyrics: Lyrics? }

    static func syncedIds(_ ids: [String]) async -> Set<String> {
        let dir = Storage.lyrics
        return await Task.detached(priority: .utility) {
            var out = Set<String>()
            for id in ids {
                let file = dir.appendingPathComponent(id + ".json")
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data),
                      entry.lyrics?.isSynced == true else { continue }
                out.insert(id)
            }
            return out
        }.value
    }
}

struct ArtistView: View {
    let artist: BaseItem
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @State private var albums: [BaseItem] = []
    @State private var tracks: [BaseItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(artist.title)
                    .lottaEditorial(size: 104, weight: .black)
                    .lottaLower()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Runs off the right edge on purpose.
                    .padding(.trailing, -140)
                    .accessibilityAddTraits(.isHeader)

                if !dataLine.isEmpty {
                    Text(dataLine)
                        .lottaLabel(mono: true, tracking: 1.0)
                        .foregroundStyle(Theme.plumSoft)
                }

                EditorialButtons(disabled: tracks.isEmpty,
                                 play: { player.play(tracks) },
                                 shuffle: { player.play(tracks, shuffle: true) })

                if !albums.isEmpty {
                    HStack {
                        Text("Discografía").lottaLabel(tracking: 1.2).foregroundStyle(Theme.plum)
                        Spacer()
                        Text("\(albums.count)").lottaLabel(mono: true).foregroundStyle(Theme.plumSoft)
                    }
                    .padding(.top, 8)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { i, album in
                            NavigationLink(value: album) {
                                HStack(spacing: 14) {
                                    Text(String(format: "%02d", i + 1))
                                        .font(.subheadline.monospaced())
                                        .foregroundStyle(Theme.plumSoft)
                                        .frame(minWidth: 26, alignment: .leading)
                                    ArtworkView(itemId: album.id, cornerRadius: 4)
                                        .frame(width: 48, height: 48)
                                    Text(album.title)
                                        .font(.body.weight(.semibold))
                                        .lottaLower()
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(2)
                                    Spacer(minLength: 8)
                                    if let y = album.productionYear {
                                        Text(String(y))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Theme.plumSoft)
                                    }
                                }
                                .padding(.vertical, 8)
                                .frame(minHeight: Theme.minTap)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Theme.ink.opacity(0.08))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical)
        }
        .scrollContentBackground(.hidden)
        .background(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
                Theme.cream
                VinylDisc(labelColor: Theme.plum)
                    .frame(width: 260, height: 260)
                    .offset(x: 90, y: 70)
                    .opacity(0.9)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .preferredColorScheme(.light)
        .environment(\.colorScheme, .light)
        .tint(Theme.accentInk)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = await library.albums(for: artist)
            tracks = await artistTracks()
        }
    }

    /// "5 álbumes · 62 pistas · 2009–2023"
    private var dataLine: String {
        var parts: [String] = []
        if !albums.isEmpty { parts.append("\(albums.count) \(albums.count == 1 ? "álbum" : "álbumes")") }
        if !tracks.isEmpty { parts.append("\(tracks.count) pistas") }
        let years = albums.compactMap(\.productionYear)
        if let lo = years.min(), let hi = years.max() {
            parts.append(lo == hi ? String(lo) : "\(lo)–\(hi)")
        }
        return parts.joined(separator: " · ")
    }

    /// All of the artist's tracks, album by album: cached tracklists first,
    /// fetching (and caching) the ones we haven't seen yet.
    private func artistTracks() async -> [BaseItem] {
        let ordered = albums.sorted { ($0.productionYear ?? 0) < ($1.productionYear ?? 0) }
        var out: [BaseItem] = []
        for album in ordered {
            let cached = library.cachedTracks(albumId: album.id)
            out += cached.isEmpty ? await library.tracks(for: album) : cached
        }
        return out
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: Player

    var body: some View {
        let albums = downloads.downloadedAlbums
        let playlists = downloads.downloadedPlaylists
        let pending = downloads.pending.values.sorted { $0.title < $1.title }
        List {
            if !pending.isEmpty {
                Section("Descargando") {
                    ForEach(pending) { item in
                        HStack(spacing: 12) {
                            ArtworkView(itemId: item.artworkItemId, cornerRadius: 4).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(item.trackArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            DownloadIndicator(state: downloads.state(for: item.id))
                        }
                        .swipeActions {
                            Button("Cancelar", role: .destructive) { downloads.cancel([item.id]) }
                        }
                    }
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { p in
                        NavigationLink(value: p) {
                            AlbumRow(album: p, subtitle: "\(downloads.tracks(inPlaylist: p.id).count) canciones")
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.delete(playlistId: p.id) } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !albums.isEmpty {
                Section {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumRow(album: album, subtitle: "\(downloads.tracks(inAlbum: album.id).count) canciones · \(album.artistLine)")
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.delete(albumId: album.id) } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("\(downloads.downloaded.count) canciones · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if albums.isEmpty && playlists.isEmpty && pending.isEmpty {
                ContentUnavailableView("Sin descargas", systemImage: "arrow.down.circle",
                                       description: Text("Toca ↓ en un álbum para tenerlo sin conexión."))
            }
        }
        .navigationTitle("Descargas")
        .toolbar {
            if !downloads.downloaded.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { player.play(downloads.allTracks, shuffle: true) } label: {
                        Image(systemName: "shuffle")
                    }
                    .accessibilityLabel("Aleatorio de todo lo descargado")
                }
            }
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var searching = false

    var body: some View {
        let artists = results.filter(\.isArtist)
        let albums = results.filter(\.isAlbum)
        let songs = results.filter(\.isTrack)
        let playlists = results.filter(\.isPlaylist)
        List {
            if !artists.isEmpty {
                Section("Artistas") {
                    ForEach(artists) { a in NavigationLink(value: a) { ArtistRow(artist: a) } }
                }
            }
            if !albums.isEmpty {
                Section("Álbumes") {
                    ForEach(albums) { a in NavigationLink(value: a) { AlbumRow(album: a) } }
                }
            }
            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { p in NavigationLink(value: p) { AlbumRow(album: p, subtitle: "Playlist") } }
                }
            }
            if !songs.isEmpty {
                Section("Canciones") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        TrackRow(track: s, showArtwork: true)
                            .onTapGesture { player.play(songs, startAt: i) }
                            .trackContextMenu(s)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Busca en tu biblioteca", systemImage: "magnifyingglass",
                                       description: Text("Artistas, álbumes o canciones."))
            } else if results.isEmpty && !searching && query.count >= 2 {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Artistas, álbumes o canciones")
        .navigationTitle("Buscar")
        .task(id: query) {
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let r = await library.search(query)
            guard !Task.isCancelled else { return }
            results = r
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var network: NetworkMonitor
    @AppStorage(AppSettings.autoSyncKey) private var autoSync = false
    @AppStorage(AppSettings.syncArtworkKey) private var syncArtwork = true
    @AppStorage(AppSettings.lrclibKey) private var lrclib = true
    @AppStorage(AppSettings.neteaseKey) private var netease = true
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.streamQualityKey) private var streamQuality: AudioQuality = .original
    @AppStorage(AppSettings.downloadQualityKey) private var downloadQuality: AudioQuality = .original
    @State private var confirmDelete = false
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            Form {
                if let c = model.creds {
                    Section("Cuenta") {
                        LabeledContent("Servidor", value: c.serverURL.host ?? c.serverURL.absoluteString)
                        LabeledContent("Usuario", value: c.userName)
                    }
                }

                Section {
                    Picker("Streaming", selection: $streamQuality) {
                        ForEach(AudioQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Descargas", selection: $downloadQuality) {
                        ForEach(AudioQuality.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Calidad de audio")
                } footer: {
                    Text("“Original” usa el archivo tal cual (FLAC, ALAC, AAC, MP3). Si iOS no soporta el formato, el servidor lo convierte a MP3.")
                }

                Section {
                    if let sync = library.sync {
                        SyncProgressRow(sync: sync)
                        Button("Cancelar", role: .destructive) { library.cancelSync() }
                    } else {
                        Button {
                            library.startSync()
                        } label: {
                            Label("Sincronizar biblioteca", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!network.isOnline)
                    }
                    LabeledContent("Última sincronización") {
                        if let last = library.lastSync {
                            Text(last, format: .relative(presentation: .named))
                        } else {
                            Text("Nunca")
                        }
                    }
                    Toggle("Sincronizar al abrir la app", isOn: $autoSync)
                    Toggle("Guardar portadas", isOn: $syncArtwork)
                } header: {
                    Text("Biblioteca")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let summary = library.lastSyncSummary { Text(summary) }
                        if let err = library.lastError, !library.isSyncing {
                            Text(err).foregroundStyle(.red)
                        }
                        Text("Guarda álbumes, artistas, playlists y sus canciones para navegar sin conexión, y actualiza tus playlists y álbumes descargados con los cambios del servidor. Al abrir la app se sincroniza como máximo una vez al día.")
                    }
                }

                Section {
                    Toggle("Buscar letras en LRCLIB", isOn: $lrclib)
                        .onChange(of: lrclib) { _, on in
                            if on { Task { await LyricsStore.shared.forgetMissing() } }
                        }
                    Toggle("Buscar también en NetEase", isOn: $netease)
                        .onChange(of: netease) { _, on in
                            if on { Task { await LyricsStore.shared.forgetMissing() } }
                        }
                } header: {
                    Text("Letras")
                } footer: {
                    Text("Si tu servidor no tiene la letra, Lotta la busca primero en lrclib.net (base de letras gratuita) y luego en NetEase Cloud Music (catálogo enorme; servicio no oficial con servidores en China). Se envían el título, artista, álbum y duración de la canción.")
                }

                Section("Almacenamiento") {
                    LabeledContent("Descargas",
                                   value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                    Button("Eliminar todas las descargas", role: .destructive) { confirmDelete = true }
                        .disabled(downloads.downloaded.isEmpty)
                }

                Section {
                    Button("Cerrar sesión", role: .destructive) { confirmLogout = true }
                } footer: {
                    Text("Lotta \(JellyfinClient.clientVersion)")
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            .confirmationDialog("¿Eliminar todas las descargas?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Eliminar", role: .destructive) { downloads.deleteAll() }
            }
            .confirmationDialog("¿Qué hacemos con tus descargas?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Cerrar sesión y conservarlas") {
                    dismiss()
                    model.logout(keepDownloads: true)
                }
                Button("Cerrar sesión y borrarlas", role: .destructive) {
                    dismiss()
                    model.logout(keepDownloads: false)
                }
            } message: {
                Text("Si las conservas, siguen en el teléfono cuando vuelvas a entrar a tu servidor.")
            }
        }
    }
}

struct SyncProgressRow: View {
    let sync: LibraryStore.SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sincronizando · \(sync.phase)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            if let f = sync.fraction {
                ProgressView(value: f).animation(.default, value: f)
            }
        }
    }
}

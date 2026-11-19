import SwiftUI

enum LibraryTab: String, CaseIterable {
    case albums, artists, playlists
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var network: NetworkMonitor
    @AppStorage("lotta.library.tab") private var tab: LibraryTab = .albums
    @AppStorage("lotta.library.downloadedOnly") private var downloadedOnly = false
    @State private var showSettings = false

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
            VStack(spacing: 16) {
                Picker("Sección", selection: $tab) {
                    Text("Álbumes").tag(LibraryTab.albums)
                    Text("Artistas").tag(LibraryTab.artists)
                    Text("Playlists").tag(LibraryTab.playlists)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if let sync = library.sync {
                    SyncProgressRow(sync: sync)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if !network.isOnline {
                    Label("Sin conexión · mostrando tus descargas", systemImage: "wifi.slash")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if let err = library.lastError, library.albums.isEmpty {
                    Text(err).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }

                switch tab {
                case .albums:
                    if albums.isEmpty { emptyState } else { AlbumGrid(albums: albums) }
                case .playlists:
                    if playlists.isEmpty { emptyState } else { PlaylistList(playlists: playlists) }
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
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 20)
            .animation(.spring(response: 0.35), value: library.isSyncing)
        }
        .navigationTitle("Biblioteca")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { downloadedOnly.toggle() } label: {
                    Image(systemName: downloadedOnly ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityLabel("Solo descargado")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if library.isSyncing {
                    ProgressView()
                } else {
                    Button { library.startSync() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!network.isOnline)
                    .accessibilityLabel("Sincronizar biblioteca")
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .refreshable { await library.refresh() }
        .task { if library.albums.isEmpty { await library.refresh() } }
        .sheet(isPresented: $showSettings) { SettingsView() }
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

struct AlbumGrid: View {
    let albums: [BaseItem]
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        let downloadedIds = downloads.downloadedAlbumIds
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 22) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(itemId: album.id)
                        Text(album.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if downloadedIds.contains(album.id) {
                                Image(systemName: "arrow.down.circle.fill").font(.caption2)
                            }
                            Text(album.artistLine).lineLimit(1)
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

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))

            if loading && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            }

            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
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
                            .tint(.lotta)
                        }
                    }
            }

            if !tracks.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
            }
        }
        .listStyle(.plain)
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
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(itemId: album.id, size: ArtworkSize.large, cornerRadius: 10)
                .frame(maxWidth: 250)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(album.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(album.artistLine)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.center)
                if let y = album.productionYear {
                    Text(String(y)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button { player.play(tracks) } label: {
                    Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { player.play(tracks, shuffle: true) } label: {
                    Label("Aleatorio", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var footer: String {
        let minutes = Int(tracks.compactMap(\.duration).reduce(0, +) / 60)
        return "\(tracks.count) canciones · \(minutes) min"
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

struct ArtistView: View {
    let artist: BaseItem
    @EnvironmentObject private var library: LibraryStore
    @State private var albums: [BaseItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    ArtworkView(itemId: artist.id, size: ArtworkSize.large)
                        .frame(width: 170, height: 170)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    Text(artist.title).font(.title.bold()).multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                AlbumGrid(albums: albums)
            }
            .padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { albums = await library.albums(for: artist) }
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
            let r = await library.search(query)
            guard !Task.isCancelled else { return }
            results = r
            searching = false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var network: NetworkMonitor
    @AppStorage(AppSettings.autoSyncKey) private var autoSync = true
    @AppStorage(AppSettings.syncArtworkKey) private var syncArtwork = true
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
            .confirmationDialog("Se borrarán también tus descargas.", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    dismiss()
                    model.logout()
                }
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

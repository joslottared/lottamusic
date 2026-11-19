import SwiftUI

struct PlaylistList: View {
    let playlists: [BaseItem]
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(playlists) { p in
                NavigationLink(value: p) {
                    HStack(spacing: 12) {
                        ArtworkView(itemId: p.id, cornerRadius: 6).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).lineLimit(1)
                            HStack(spacing: 4) {
                                if downloads.playlistInfo[p.id] != nil {
                                    Image(systemName: "arrow.down.circle.fill").font(.caption2)
                                }
                                Text(p.childCount.map { "\($0) canciones" } ?? "Playlist")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 68)
            }
        }
        .padding(.horizontal)
    }
}

struct PlaylistView: View {
    let playlist: BaseItem

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var network: NetworkMonitor
    @State private var tracks: [BaseItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))

            if loading && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if tracks.isEmpty {
                Text("Esta playlist está vacía. Añade canciones desde el menú de cualquier canción.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                TrackRow(track: track, showArtwork: true)
                    .onTapGesture { player.play(tracks, startAt: i) }
                    .trackContextMenu(track)
                    .swipeActions(edge: .trailing) {
                        if network.isOnline && track.playlistItemId != nil {
                            Button(role: .destructive) { Task { await remove(track) } } label: {
                                Label("Quitar", systemImage: "minus.circle")
                            }
                        }
                    }
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { downloadButton }
        }
        .refreshable { await reload() }
        .task {
            tracks = library.cachedTracks(playlistId: playlist.id)
            await reload()
        }
    }

    private func reload() async {
        loading = true
        let fresh = await library.tracks(forPlaylist: playlist)
        if !fresh.isEmpty || network.isOnline { tracks = fresh }
        loading = false
    }

    private func remove(_ track: BaseItem) async {
        do {
            try await library.remove(track, from: playlist)
            tracks.removeAll { $0.playlistItemId == track.playlistItemId }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(itemId: playlist.id, size: ArtworkSize.large, cornerRadius: 10)
                .frame(maxWidth: 230)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(playlist.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
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

    private var subtitle: String {
        let minutes = Int(tracks.compactMap(\.duration).reduce(0, +) / 60)
        return "Playlist · \(tracks.count) canciones · \(minutes) min"
    }

    @ViewBuilder private var downloadButton: some View {
        let isSaved = downloads.playlistInfo[playlist.id] != nil
        switch downloads.state(of: tracks) {
        case .done where isSaved:
            Menu {
                Button(role: .destructive) { downloads.delete(playlistId: playlist.id) } label: {
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
            // Also re-syncs: picks up tracks added to the playlist since last time.
            Button { downloads.download(tracks, playlist: playlist) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .disabled(tracks.isEmpty)
        }
    }
}

struct AddToPlaylistView: View {
    let tracks: [BaseItem]

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if creating {
                        TextField("Nombre de la playlist", text: $newName)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { Task { await create() } }
                    } else {
                        Button {
                            creating = true
                            nameFocused = true
                        } label: {
                            Label("Nueva playlist", systemImage: "plus")
                        }
                    }
                }

                if !library.playlists.isEmpty {
                    Section("Tus playlists") {
                        ForEach(library.playlists) { p in
                            Button { Task { await add(to: p) } } label: {
                                AlbumRow(album: p, subtitle: p.childCount.map { "\($0) canciones" } ?? "Playlist")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .navigationTitle(tracks.count == 1 ? "Añadir a playlist" : "Añadir \(tracks.count) canciones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                if creating {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Crear") { Task { await create() } }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.success, trigger: busy) { old, new in old && !new && error == nil }
    }

    private func add(to playlist: BaseItem) async {
        await run { try await library.add(tracks, to: playlist) }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await run { try await library.createPlaylist(name: name, with: tracks) }
    }

    private func run(_ action: () async throws -> Void) async {
        busy = true
        error = nil
        do {
            try await action()
            busy = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
            busy = false
        }
    }
}

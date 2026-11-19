import Combine
import Foundation
import Network

/// Library metadata, cached on disk so the app can be browsed offline.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var albums: [BaseItem] = []
    @Published private(set) var artists: [BaseItem] = []
    @Published private(set) var playlists: [BaseItem] = []
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?
    @Published private(set) var sync: SyncProgress?
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncSummary: String?
    private var syncTask: Task<Void, Never>?

    struct SyncProgress: Equatable {
        var phase: String
        /// 0…1, or nil while the amount of work isn't known yet.
        var fraction: Double?
    }

    private var tracksByAlbum: [String: [BaseItem]] = [:]
    weak var downloads: DownloadManager?

    private struct Snapshot: Codable {
        var albums: [BaseItem]
        var artists: [BaseItem]
        var tracksByAlbum: [String: [BaseItem]]
        var playlists: [BaseItem]?
    }

    private static let fileName = "library.json"

    init() {
        if let s = Storage.readJSON(Snapshot.self, Self.fileName) {
            albums = s.albums
            artists = s.artists
            tracksByAlbum = s.tracksByAlbum
            playlists = s.playlists ?? []
        }
        lastSync = UserDefaults.standard.object(forKey: AppSettings.lastSyncKey) as? Date
    }

    private func save() {
        Storage.writeJSON(Snapshot(albums: albums, artists: artists, tracksByAlbum: tracksByAlbum, playlists: playlists), Self.fileName)
    }

    func reset() {
        albums = []
        artists = []
        playlists = []
        tracksByAlbum = [:]
        Storage.remove(Self.fileName)
        cancelSync()
        lastSync = nil
        lastSyncSummary = nil
        UserDefaults.standard.removeObject(forKey: AppSettings.lastSyncKey)
    }

    func refresh() async {
        guard let client = ClientBox.shared.client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let a = client.albums()
            async let r = client.artists()
            let (newAlbums, newArtists) = try await (a, r)
            albums = newAlbums
            artists = newArtists
            playlists = (try? await client.playlists()) ?? playlists
            lastError = nil
            save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Full sync

    var isSyncing: Bool { sync != nil }

    /// Starts a full sync unless one is running. Survives the calling view
    /// going away.
    func startSync() {
        guard syncTask == nil, ClientBox.shared.client != nil else { return }
        syncTask = Task { [weak self] in
            await self?.runSync()
            self?.syncTask = nil
        }
    }

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        sync = nil
    }

    /// Auto sync on launch, at most once a day.
    func autoSyncIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: AppSettings.autoSyncKey) as? Bool ?? true else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 24 * 3600 { return }
        startSync()
    }

    /// Downloads the whole library's metadata (albums, artists, playlists and
    /// every tracklist) so it can be browsed offline, updates downloaded
    /// albums/playlists with server changes, and caches cover art.
    private func runSync() async {
        guard let client = ClientBox.shared.client else { return }
        sync = SyncProgress(phase: "Álbumes y artistas", fraction: nil)
        defer { sync = nil }
        do {
            // 1. Collections.
            async let a = client.albums()
            async let r = client.artists()
            async let p = client.playlists()
            let (newAlbums, newArtists, newPlaylists) = try await (a, r, p)
            try Task.checkCancellation()
            albums = newAlbums
            artists = newArtists
            playlists = newPlaylists
            save()

            // 2. Every track, grouped into album tracklists.
            sync = SyncProgress(phase: "Canciones", fraction: 0)
            let all = try await client.allTracks { @MainActor [weak self] loaded, total in
                self?.sync = SyncProgress(phase: "Canciones (\(loaded) de \(total))",
                                          fraction: total > 0 ? Double(loaded) / Double(total) : nil)
            }
            var byAlbum: [String: [BaseItem]] = [:]
            for t in all {
                if let id = t.albumId { byAlbum[id, default: []].append(t) }
            }
            for k in byAlbum.keys { byAlbum[k]?.sort(by: BaseItem.trackOrder) }

            // 3. Playlist tracklists.
            var byPlaylist: [String: [BaseItem]] = [:]
            for (i, pl) in newPlaylists.enumerated() {
                try Task.checkCancellation()
                sync = SyncProgress(phase: "Playlists (\(i + 1) de \(newPlaylists.count))",
                                    fraction: Double(i) / Double(max(newPlaylists.count, 1)))
                if let t = try? await client.tracks(playlistId: pl.id) { byPlaylist[pl.id] = t }
            }
            try Task.checkCancellation()
            tracksByAlbum = byAlbum.merging(byPlaylist) { a, _ in a }
            save()

            // 4. Downloads follow the server.
            var added = 0, removed = 0
            if let downloads {
                sync = SyncProgress(phase: "Descargas", fraction: nil)
                for id in downloads.syncedAlbumIds {
                    if let album = self.album(id: id), let t = byAlbum[id] {
                        added += downloads.syncAlbum(album, tracks: t)
                    }
                }
                for id in downloads.syncedPlaylistIds {
                    if let pl = newPlaylists.first(where: { $0.id == id }), let t = byPlaylist[id] {
                        let r = downloads.syncPlaylist(pl, tracks: t)
                        added += r.added
                        removed += r.removed
                    }
                }
            }

            // 5. Cover art for offline browsing.
            if UserDefaults.standard.object(forKey: AppSettings.syncArtworkKey) as? Bool ?? true {
                let ids = (newAlbums + newPlaylists + newArtists)
                    .filter { $0.imageTags?["Primary"] != nil }
                    .map(\.id)
                try await prefetchArtwork(ids)
            }

            let now = Date()
            lastSync = now
            UserDefaults.standard.set(now, forKey: AppSettings.lastSyncKey)
            var summary = "\(newAlbums.count) álbumes · \(all.count) canciones · \(newPlaylists.count) playlists"
            if added > 0 { summary += " · \(added) descargas nuevas" }
            if removed > 0 { summary += " · \(removed) quitadas" }
            lastSyncSummary = summary
            lastError = nil
        } catch is CancellationError {
            // User cancelled.
        } catch {
            if !Task.isCancelled { lastError = error.localizedDescription }
        }
    }

    private func prefetchArtwork(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let total = ids.count
        var done = 0
        sync = SyncProgress(phase: "Portadas (0 de \(total))", fraction: 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(6, total) {
                let id = ids[next]; next += 1
                group.addTask { await ArtworkCache.shared.prefetch(id, size: ArtworkSize.small) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                done += 1
                if done % 10 == 0 || done == total {
                    sync = SyncProgress(phase: "Portadas (\(done) de \(total))",
                                        fraction: Double(done) / Double(total))
                }
                if next < total {
                    let id = ids[next]; next += 1
                    group.addTask { await ArtworkCache.shared.prefetch(id, size: ArtworkSize.small) }
                }
            }
        }
    }

    func album(id: String) -> BaseItem? { albums.first { $0.id == id } }

    /// Cached tracklist (full album if we've seen it online, else downloaded tracks).
    func cachedTracks(albumId: String) -> [BaseItem] {
        if let t = tracksByAlbum[albumId], !t.isEmpty { return t }
        return downloads?.tracks(inAlbum: albumId) ?? []
    }

    func tracks(for album: BaseItem) async -> [BaseItem] {
        if let client = ClientBox.shared.client, let fetched = try? await client.tracks(albumId: album.id) {
            tracksByAlbum[album.id] = fetched
            save()
            return fetched
        }
        return cachedTracks(albumId: album.id)
    }

    // MARK: - Playlists
    // Playlist tracklists share the tracksByAlbum cache (keyed by playlist id).

    func cachedTracks(playlistId: String) -> [BaseItem] {
        if let t = tracksByAlbum[playlistId], !t.isEmpty { return t }
        return downloads?.tracks(inPlaylist: playlistId) ?? []
    }

    func tracks(forPlaylist playlist: BaseItem) async -> [BaseItem] {
        if let client = ClientBox.shared.client, let fetched = try? await client.tracks(playlistId: playlist.id) {
            tracksByAlbum[playlist.id] = fetched
            save()
            return fetched
        }
        return cachedTracks(playlistId: playlist.id)
    }

    private func requireClient() throws -> JellyfinClient {
        guard let client = ClientBox.shared.client else { throw JellyfinError.offline }
        return client
    }

    private func reloadPlaylists(_ client: JellyfinClient) async {
        if let p = try? await client.playlists() {
            playlists = p
            save()
        }
    }

    func add(_ tracks: [BaseItem], to playlist: BaseItem) async throws {
        let client = try requireClient()
        try await client.addToPlaylist(playlist.id, itemIds: tracks.map(\.id))
        _ = await self.tracks(forPlaylist: playlist)
        await reloadPlaylists(client)
    }

    func createPlaylist(name: String, with tracks: [BaseItem]) async throws {
        let client = try requireClient()
        try await client.createPlaylist(name: name, itemIds: tracks.map(\.id))
        await reloadPlaylists(client)
    }

    func remove(_ track: BaseItem, from playlist: BaseItem) async throws {
        let client = try requireClient()
        guard let entry = track.playlistItemId else { return }
        try await client.removeFromPlaylist(playlist.id, entryIds: [entry])
        tracksByAlbum[playlist.id]?.removeAll { $0.playlistItemId == entry }
        save()
        await reloadPlaylists(client)
    }

    func albums(for artist: BaseItem) async -> [BaseItem] {
        if let client = ClientBox.shared.client, let fetched = try? await client.albums(artistId: artist.id) {
            return fetched
        }
        let local = albums.isEmpty ? (downloads?.downloadedAlbums ?? []) : albums
        return local.filter { $0.albumArtist == artist.name }
    }

    func search(_ term: String) async -> [BaseItem] {
        if let client = ClientBox.shared.client, let results = try? await client.search(term) {
            return results
        }
        // Offline: search what we have locally.
        let match: (BaseItem) -> Bool = { $0.title.localizedCaseInsensitiveContains(term) }
        let tracks = (downloads?.allTracks ?? []).filter {
            match($0) || $0.trackArtist.localizedCaseInsensitiveContains(term)
        }
        return artists.filter(match) + albums.filter(match) + playlists.filter(match) + tracks
    }
}

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "lotta.network"))
    }
}

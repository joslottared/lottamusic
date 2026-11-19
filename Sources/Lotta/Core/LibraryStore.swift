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

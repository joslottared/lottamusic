import Combine
import Foundation

struct DownloadedTrack: Codable, Sendable {
    var item: BaseItem
    var fileName: String
    var bytes: Int64
    var date: Date
}

enum DownloadState: Equatable {
    case none, queued, downloading(Double), partial, done, failed
}

/// Offline downloads over a background URLSession: they keep going when the
/// app is suspended, and the system relaunches us to finish them.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let sessionId = "com.lottamusic.lotta.downloads"

    @Published private(set) var downloaded: [String: DownloadedTrack] = [:]
    @Published private(set) var pending: [String: BaseItem] = [:]
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failed: Set<String> = []
    private var albumInfo: [String: BaseItem] = [:]
    @Published private(set) var playlistInfo: [String: BaseItem] = [:]
    /// Ordered track ids of each downloaded playlist.
    private var playlistTracks: [String: [String]] = [:]

    /// Set by the AppDelegate when iOS wakes us for background session events.
    var backgroundCompletion: (() -> Void)?

    private struct Manifest: Codable {
        var downloaded: [String: DownloadedTrack]
        var pending: [String: BaseItem]
        var albums: [String: BaseItem]
        var playlists: [String: BaseItem]?
        var playlistTracks: [String: [String]]?
    }

    private static let manifestName = "downloads.json"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        if let m = Storage.readJSON(Manifest.self, Self.manifestName) {
            downloaded = m.downloaded
            pending = m.pending
            albumInfo = m.albums
            playlistInfo = m.playlists ?? [:]
            playlistTracks = m.playlistTracks ?? [:]
        }
    }

    /// Reconnects to the background session and restarts anything that was
    /// queued but lost (e.g. after the app was force-quit).
    func start() {
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for (id, item) in self.pending where !running.contains(id) {
                    self.startTask(item)
                }
            }
        }
    }

    private func save() {
        Storage.writeJSON(Manifest(downloaded: downloaded, pending: pending, albums: albumInfo,
                                    playlists: playlistInfo, playlistTracks: playlistTracks), Self.manifestName)
    }

    // MARK: - Queries

    func state(for id: String) -> DownloadState {
        if downloaded[id] != nil { return .done }
        if let p = progress[id] { return .downloading(p) }
        if pending[id] != nil { return .queued }
        if failed.contains(id) { return .failed }
        return .none
    }

    func state(of tracks: [BaseItem]) -> DownloadState {
        guard !tracks.isEmpty else { return .none }
        var done = 0, active = 0
        var fraction = 0.0
        for t in tracks {
            if downloaded[t.id] != nil {
                done += 1; fraction += 1
            } else if pending[t.id] != nil {
                active += 1; fraction += progress[t.id] ?? 0
            }
        }
        if done == tracks.count { return .done }
        if active > 0 { return .downloading(fraction / Double(tracks.count)) }
        if done > 0 { return .partial }
        return .none
    }

    func isDownloaded(_ id: String) -> Bool { downloaded[id] != nil }

    func localURL(for id: String) -> URL? {
        guard let d = downloaded[id] else { return nil }
        let url = Storage.downloads.appendingPathComponent(d.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func tracks(inAlbum albumId: String) -> [BaseItem] {
        downloaded.values.map(\.item).filter { $0.albumId == albumId }.sorted(by: BaseItem.trackOrder)
    }

    var allTracks: [BaseItem] { downloaded.values.map(\.item) }

    var downloadedAlbumIds: Set<String> { Set(downloaded.values.compactMap(\.item.albumId)) }

    /// Albums shown in Downloads: explicitly downloaded ones, plus albums of
    /// loose tracks. Tracks that only came in through a playlist stay there.
    var downloadedAlbums: [BaseItem] {
        let viaPlaylist = Set(playlistTracks.values.joined())
        var byAlbum: [String: BaseItem] = [:]
        for d in downloaded.values {
            let t = d.item
            guard let albumId = t.albumId, byAlbum[albumId] == nil else { continue }
            if viaPlaylist.contains(t.id) && albumInfo[albumId] == nil { continue }
            byAlbum[albumId] = albumInfo[albumId] ?? BaseItem(
                id: albumId, name: t.album, type: "MusicAlbum",
                albumArtist: t.albumArtist ?? t.artists?.first, productionYear: t.productionYear)
        }
        return byAlbum.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var downloadedPlaylists: [BaseItem] {
        playlistInfo.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func tracks(inPlaylist playlistId: String) -> [BaseItem] {
        (playlistTracks[playlistId] ?? []).compactMap { downloaded[$0]?.item }
    }

    var totalBytes: Int64 { downloaded.values.reduce(0) { $0 + $1.bytes } }

    // MARK: - Actions

    func download(_ tracks: [BaseItem], album: BaseItem? = nil, playlist: BaseItem? = nil) {
        if let album { albumInfo[album.id] = album }
        if let playlist {
            playlistInfo[playlist.id] = playlist
            playlistTracks[playlist.id] = tracks.map(\.id)
        }
        var artworkIds = Set<String>()
        for t in tracks where downloaded[t.id] == nil && pending[t.id] == nil {
            pending[t.id] = t
            failed.remove(t.id)
            startTask(t)
            artworkIds.insert(t.artworkItemId)
            Task.detached(priority: .utility) { _ = await LyricsStore.shared.lyrics(for: t) }
        }
        if let album { artworkIds.insert(album.id) }
        if let playlist { artworkIds.insert(playlist.id) }
        for id in artworkIds {
            Task.detached(priority: .utility) {
                _ = await ArtworkCache.shared.image(for: id, size: ArtworkSize.small)
                _ = await ArtworkCache.shared.image(for: id, size: ArtworkSize.large)
            }
        }
        save()
    }

    private func startTask(_ item: BaseItem) {
        guard let client = ClientBox.shared.client else { return }
        let url = client.audioURL(itemId: item.id, quality: AppSettings.downloadQuality)
        let task = session.downloadTask(with: client.authorizedRequest(url))
        task.taskDescription = item.id
        task.resume()
    }

    func cancel(_ ids: [String]) {
        let set = Set(ids)
        session.getAllTasks { tasks in
            for t in tasks where set.contains(t.taskDescription ?? "") { t.cancel() }
        }
        for id in ids {
            pending[id] = nil
            progress[id] = nil
        }
        save()
    }

    func delete(_ ids: [String]) {
        cancel(ids.filter { pending[$0] != nil })
        for id in ids {
            if let d = downloaded.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: Storage.downloads.appendingPathComponent(d.fileName))
            }
            failed.remove(id)
        }
        save()
    }

    func delete(albumId: String) {
        let ids = downloaded.values.filter { $0.item.albumId == albumId }.map(\.item.id)
            + pending.values.filter { $0.albumId == albumId }.map(\.id)
        albumInfo[albumId] = nil
        delete(ids)
    }

    /// Removes the playlist and the tracks that aren't kept by a downloaded
    /// album or another downloaded playlist.
    func delete(playlistId: String) {
        let ids = playlistTracks[playlistId] ?? []
        playlistInfo[playlistId] = nil
        playlistTracks[playlistId] = nil
        delete(unreferenced(ids))
    }

    /// Of `ids`, those no downloaded playlist or downloaded album still needs.
    private func unreferenced(_ ids: [String]) -> [String] {
        let keptByPlaylists = Set(playlistTracks.values.joined())
        return ids.filter { id in
            let albumId = downloaded[id]?.item.albumId ?? pending[id]?.albumId
            return !keptByPlaylists.contains(id) && albumId.map { albumInfo[$0] == nil } ?? true
        }
    }

    // MARK: - Sync

    /// Albums the user downloaded explicitly (not loose tracks).
    var syncedAlbumIds: [String] { Array(albumInfo.keys) }
    var syncedPlaylistIds: [String] { Array(playlistInfo.keys) }

    /// Brings a downloaded album in line with the server. Returns how many
    /// new tracks were queued.
    @discardableResult
    func syncAlbum(_ album: BaseItem, tracks: [BaseItem]) -> Int {
        guard albumInfo[album.id] != nil, !tracks.isEmpty else { return 0 }
        refreshMetadata(tracks)
        let new = tracks.filter { downloaded[$0.id] == nil && pending[$0.id] == nil }.count
        download(tracks, album: album)
        return new
    }

    /// Brings a downloaded playlist in line with the server: queues added
    /// tracks and drops removed ones (unless something else keeps them).
    /// Returns (added, removed).
    @discardableResult
    func syncPlaylist(_ playlist: BaseItem, tracks: [BaseItem]) -> (added: Int, removed: Int) {
        guard playlistInfo[playlist.id] != nil else { return (0, 0) }
        let old = playlistTracks[playlist.id] ?? []
        let newIds = Set(tracks.map(\.id))
        // Safety: an empty answer, or one that drops most of the playlist, is
        // more likely a server hiccup than a real edit — leave it untouched.
        let dropping = old.filter { !newIds.contains($0) }.count
        if tracks.isEmpty || (old.count >= 4 && dropping > old.count / 2) { return (0, 0) }
        refreshMetadata(tracks)
        let added = tracks.filter { downloaded[$0.id] == nil && pending[$0.id] == nil }.count
        download(tracks, playlist: playlist)
        let gone = unreferenced(old.filter { !newIds.contains($0) })
        delete(gone)
        return (added, gone.count)
    }

    /// Keeps titles/artists of downloaded tracks current.
    private func refreshMetadata(_ tracks: [BaseItem]) {
        for t in tracks {
            guard var d = downloaded[t.id] else { continue }
            var fresh = t
            fresh.playlistItemId = t.playlistItemId ?? d.item.playlistItemId
            if d.item != fresh {
                d.item = fresh
                downloaded[t.id] = d
            }
        }
    }

    func deleteAll() {
        cancel(Array(pending.keys))
        downloaded = [:]
        failed = []
        albumInfo = [:]
        playlistInfo = [:]
        playlistTracks = [:]
        try? FileManager.default.removeItem(at: Storage.downloads)
        try? FileManager.default.createDirectory(at: Storage.downloads, withIntermediateDirectories: true)
        save()
    }

    // MARK: - Delegate callbacks (main actor)

    fileprivate func finish(id: String, fileName: String, bytes: Int64) {
        progress[id] = nil
        guard let item = pending.removeValue(forKey: id) else {
            // Cancelled meanwhile: drop the file.
            try? FileManager.default.removeItem(at: Storage.downloads.appendingPathComponent(fileName))
            return
        }
        downloaded[id] = DownloadedTrack(item: item, fileName: fileName, bytes: bytes, date: Date())
        save()
    }

    fileprivate func markFailed(_ id: String) {
        guard pending.removeValue(forKey: id) != nil else { return }
        progress[id] = nil
        failed.insert(id)
        save()
    }

    fileprivate func updateProgress(_ id: String, _ value: Double) {
        guard pending[id] != nil else { return }
        let old = progress[id] ?? -1
        if value - old >= 0.02 || value >= 1 { progress[id] = value }
    }

    nonisolated static func fileExtension(mime: String?, url: URL?) -> String {
        switch mime?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/alac": return "m4a"
        case "audio/aac", "audio/aacp", "audio/x-aac": return "aac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        default:
            if let ext = url?.pathExtension, !ext.isEmpty, ext != "universal" { return ext }
            return "mp3"
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            Task { @MainActor in self.markFailed(id) }
            return
        }
        // The temp file is deleted when this method returns: move it now.
        let name = "\(id).\(Self.fileExtension(mime: http.mimeType, url: http.url))"
        let dest = Storage.downloads.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in self.markFailed(id) }
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        Task { @MainActor in self.finish(id: id, fileName: name, bytes: bytes) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        // Transcoded streams have no Content-Length; show an empty ring then.
        let value = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in self.updateProgress(id, value) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in self.markFailed(id) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

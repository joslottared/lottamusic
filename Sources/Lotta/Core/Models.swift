import Foundation

/// Subset of Jellyfin's BaseItemDto that the app needs (albums, artists, tracks).
struct BaseItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String? = nil
    var type: String? = nil
    var album: String? = nil
    var albumId: String? = nil
    var albumArtist: String? = nil
    var artists: [String]? = nil
    var runTimeTicks: Int64? = nil
    var indexNumber: Int? = nil
    var parentIndexNumber: Int? = nil
    var productionYear: Int? = nil
    var imageTags: [String: String]? = nil
    var childCount: Int? = nil
    var mediaType: String? = nil
    /// Entry id inside a playlist (needed to remove it from that playlist).
    var playlistItemId: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case runTimeTicks = "RunTimeTicks"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case productionYear = "ProductionYear"
        case imageTags = "ImageTags"
        case childCount = "ChildCount"
        case mediaType = "MediaType"
        case playlistItemId = "PlaylistItemId"
    }

    var title: String { name ?? "Sin título" }

    var isArtist: Bool { type == "MusicArtist" }
    var isAlbum: Bool { type == "MusicAlbum" }
    var isTrack: Bool { type == "Audio" }
    var isPlaylist: Bool { type == "Playlist" }

    /// Album artist (for albums) or performing artists (for tracks).
    var artistLine: String {
        if let a = albumArtist, !a.isEmpty { return a }
        if let a = artists, !a.isEmpty { return a.joined(separator: ", ") }
        return "Artista desconocido"
    }

    var trackArtist: String {
        if let a = artists, !a.isEmpty { return a.joined(separator: ", ") }
        return artistLine
    }

    var duration: TimeInterval? {
        runTimeTicks.map { Double($0) / 10_000_000 }
    }

    /// Tracks usually don't have their own art; fall back to the album's.
    var artworkItemId: String {
        if imageTags?["Primary"] != nil { return id }
        return albumId ?? id
    }

    static func trackOrder(_ a: BaseItem, _ b: BaseItem) -> Bool {
        let da = a.parentIndexNumber ?? 1, db = b.parentIndexNumber ?? 1
        if da != db { return da < db }
        let ia = a.indexNumber ?? .max, ib = b.indexNumber ?? .max
        if ia != ib { return ia < ib }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

struct ItemsResponse: Decodable {
    let items: [BaseItem]
    var totalRecordCount: Int? = nil
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct Lyrics: Codable, Sendable, Equatable {
    struct Line: Codable, Sendable, Equatable, Identifiable {
        var id: Int
        var text: String
        /// Seconds from start; nil for unsynced lyrics.
        var start: TimeInterval?
    }

    var lines: [Line]
    /// Where the lyrics came from when it wasn't the Jellyfin server (e.g. "LRCLIB").
    var source: String? = nil

    var isSynced: Bool { lines.contains { $0.start != nil } }

    func currentIndex(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        var result: Int?
        for line in lines {
            guard let s = line.start else { continue }
            if s <= time + 0.15 { result = line.id } else { break }
        }
        return result
    }
}

enum AudioQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case original, high, saver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .high: "Alta (MP3 320)"
        case .saver: "Ahorro (MP3 192)"
        }
    }

    var maxBitrate: Int {
        switch self {
        case .original: 999_999_999
        case .high: 320_000
        case .saver: 192_000
        }
    }
}

enum AppSettings {
    static let streamQualityKey = "lotta.quality.stream"
    static let downloadQualityKey = "lotta.quality.download"
    static let autoSyncKey = "lotta.sync.auto"
    static let syncArtworkKey = "lotta.sync.artwork"
    static let lastSyncKey = "lotta.sync.last"
    static let lrclibKey = "lotta.lyrics.lrclib"

    static var lrclibEnabled: Bool {
        UserDefaults.standard.object(forKey: lrclibKey) as? Bool ?? true
    }

    static var streamQuality: AudioQuality {
        AudioQuality(rawValue: UserDefaults.standard.string(forKey: streamQualityKey) ?? "") ?? .original
    }

    static var downloadQuality: AudioQuality {
        AudioQuality(rawValue: UserDefaults.standard.string(forKey: downloadQualityKey) ?? "") ?? .original
    }
}

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

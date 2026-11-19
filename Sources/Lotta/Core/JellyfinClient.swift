import Foundation

struct ServerCredentials: Codable, Equatable, Sendable {
    var serverURL: URL
    var userId: String
    var userName: String
    var token: String
}

enum JellyfinError: LocalizedError {
    case invalidURL
    case unauthorized
    case badStatus(Int)
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidURL: "La dirección del servidor no es válida."
        case .unauthorized: "Usuario o contraseña incorrectos."
        case .badStatus(let code): "El servidor respondió con un error (\(code))."
        case .offline: "Necesitas conexión con tu servidor para esto."
        }
    }
}

/// Thread-safe holder for the active client, so actors and views can reach it.
final class ClientBox: @unchecked Sendable {
    static let shared = ClientBox()
    private let lock = NSLock()
    private var _client: JellyfinClient?

    var client: JellyfinClient? {
        get { lock.lock(); defer { lock.unlock() }; return _client }
        set { lock.lock(); _client = newValue; lock.unlock() }
    }
}

struct JellyfinClient: Sendable {
    let creds: ServerCredentials

    static let clientName = "Lotta"
    static let clientVersion = "0.1.0"

    static let deviceId: String = {
        let key = "lotta.deviceId"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    static func authorizationHeader(token: String?) -> String {
        var s = "MediaBrowser Client=\"\(clientName)\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if let token { s += ", Token=\"\(token)\"" }
        return s
    }

    /// Accepts "192.168.1.10:8096", "jellyfin.example.com/", etc.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "http://" + s }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw JellyfinError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw JellyfinError.badStatus(http.statusCode) }
    }

    static func login(server: URL, username: String, password: String) async throws -> ServerCredentials {
        struct AuthResult: Decodable {
            struct User: Decodable { let Id: String; let Name: String }
            let User: User
            let AccessToken: String
        }
        var req = URLRequest(url: server.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(token: nil), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        let r = try JSONDecoder().decode(AuthResult.self, from: data)
        return ServerCredentials(serverURL: server, userId: r.User.Id, userName: r.User.Name, token: r.AccessToken)
    }

    // MARK: - Requests

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: creds.serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        // "+" and "|" must be escaped explicitly for ASP.NET query parsing.
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "|", with: "%7C")
        return comps.url!
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var req = URLRequest(url: url(path, query))
        req.timeoutInterval = 20
        req.setValue(Self.authorizationHeader(token: creds.token), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func items(_ query: [String: String]) async throws -> [BaseItem] {
        var q = query
        q["userId"] = creds.userId
        let r: ItemsResponse = try await get("Items", q)
        return r.items
    }

    func albums() async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "SortBy": "SortName", "SortOrder": "Ascending", "Fields": "ChildCount",
        ])
    }

    func albums(artistId: String) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "AlbumArtistIds": artistId,
            "SortBy": "ProductionYear,SortName", "SortOrder": "Descending", "Fields": "ChildCount",
        ])
    }

    func artists() async throws -> [BaseItem] {
        let r: ItemsResponse = try await get("Artists/AlbumArtists", [
            "userId": creds.userId, "SortBy": "SortName", "SortOrder": "Ascending",
        ])
        return r.items
    }

    func tracks(albumId: String) async throws -> [BaseItem] {
        try await items([
            "ParentId": albumId, "IncludeItemTypes": "Audio", "Recursive": "true",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName",
        ])
    }

    /// Every track in the library, fetched in pages. `onPage` reports (loaded, total).
    func allTracks(pageSize: Int = 1500, onPage: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [BaseItem] {
        var all: [BaseItem] = []
        while true {
            try Task.checkCancellation()
            let r: ItemsResponse = try await get("Items", [
                "userId": creds.userId, "IncludeItemTypes": "Audio", "Recursive": "true",
                "SortBy": "Album,ParentIndexNumber,IndexNumber,SortName",
                "StartIndex": "\(all.count)", "Limit": "\(pageSize)",
            ])
            all += r.items
            let total = r.totalRecordCount ?? all.count
            await onPage(all.count, total)
            if r.items.count < pageSize || all.count >= total { return all }
        }
    }

    func search(_ term: String) async throws -> [BaseItem] {
        try await items([
            "searchTerm": term, "IncludeItemTypes": "MusicArtist,MusicAlbum,Audio,Playlist",
            "Recursive": "true", "Limit": "60",
        ])
    }

    // MARK: - Playlists

    func send(_ method: String, _ path: String, _ query: [String: String] = [:], json: Any? = nil) async throws -> Data {
        var req = authorizedRequest(url(path, query))
        req.httpMethod = method
        req.timeoutInterval = 20
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
        return data
    }

    func playlists() async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Playlist", "Recursive": "true",
            "SortBy": "SortName", "SortOrder": "Ascending", "Fields": "ChildCount",
        ]).filter { $0.mediaType == nil || $0.mediaType == "Audio" }
    }

    func tracks(playlistId: String) async throws -> [BaseItem] {
        let r: ItemsResponse = try await get("Playlists/\(playlistId)/Items", ["userId": creds.userId])
        return r.items.filter(\.isTrack)
    }

    func addToPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        _ = try await send("POST", "Playlists/\(playlistId)/Items",
                           ["ids": itemIds.joined(separator: ","), "userId": creds.userId])
    }

    func createPlaylist(name: String, itemIds: [String]) async throws {
        _ = try await send("POST", "Playlists", json: [
            "Name": name, "Ids": itemIds, "UserId": creds.userId, "MediaType": "Audio",
        ])
    }

    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        _ = try await send("DELETE", "Playlists/\(playlistId)/Items", ["entryIds": entryIds.joined(separator: ",")])
    }

    /// Jellyfin 10.9+: /Audio/{id}/Lyrics. Returns nil when the track has none.
    func lyrics(itemId: String) async throws -> Lyrics? {
        struct DTO: Decodable {
            struct Line: Decodable { let Text: String?; let Start: Int64? }
            let Lyrics: [Line]?
        }
        do {
            let dto: DTO = try await get("Audio/\(itemId)/Lyrics")
            let lines = (dto.Lyrics ?? []).enumerated().map { i, l in
                Lyrics.Line(id: i, text: l.Text?.trimmingCharacters(in: .whitespaces) ?? "",
                            start: l.Start.map { Double($0) / 10_000_000 })
            }
            return lines.isEmpty ? nil : Lyrics(lines: lines)
        } catch JellyfinError.badStatus(404) {
            return nil
        }
    }

    var authHeaders: [String: String] {
        ["Authorization": Self.authorizationHeader(token: creds.token)]
    }

    func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        for (k, v) in authHeaders { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    func imageURL(itemId: String, maxWidth: Int) -> URL {
        url("Items/\(itemId)/Images/Primary", ["maxWidth": "\(maxWidth)", "quality": "90"])
    }

    /// Direct-plays formats iOS supports (FLAC, ALAC, AAC, MP3, WAV); anything
    /// else (Opus, Vorbis, …) or above the bitrate cap is transcoded to MP3.
    func audioURL(itemId: String, quality: AudioQuality) -> URL {
        url("Audio/\(itemId)/universal", [
            "UserId": creds.userId,
            "DeviceId": Self.deviceId,
            // Jellyfin 10.11 rejects the legacy "api_key" by default; "ApiKey" is current.
            // Callers also send the Authorization header (see authorizedRequest).
            "ApiKey": creds.token,
            "MaxStreamingBitrate": "\(quality.maxBitrate)",
            "Container": "mp3,aac,m4a|aac,m4b|aac,m4a|alac,flac,alac,wav",
            "TranscodingContainer": "mp3",
            "TranscodingProtocol": "http",
            "AudioCodec": "mp3",
        ])
    }
}

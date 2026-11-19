import Foundation

/// lrclib.net: free, open lyrics database (no account or API key).
/// Used as a fallback when the Jellyfin server has no lyrics for a track.
enum LRCLib {
    enum Failure: Error { case network }

    private static let base = URL(string: "https://lrclib.net/api/")!
    /// LRCLIB asks clients to identify themselves; kept generic on purpose.
    private static let userAgent = "Lotta/\(JellyfinClient.clientVersion) (Jellyfin music player for iOS)"

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Lyrics for the track, or nil when LRCLIB has none.
    /// Throws `Failure.network` when lrclib.net can't be reached (not cached then).
    static func lyrics(for item: BaseItem) async throws -> Lyrics? {
        guard let title = item.name, !title.isEmpty else { return nil }
        let artist = item.artists?.first ?? item.albumArtist ?? ""
        guard !artist.isEmpty else { return nil }
        let duration = item.duration

        // 1. Exact match (title + artist + album + duration ±2 s on their side).
        var query = ["track_name": title, "artist_name": artist]
        if let album = item.album, !album.isEmpty { query["album_name"] = album }
        if let duration { query["duration"] = String(Int(duration.rounded())) }
        if let r: Record = try await get("get", query), let l = convert(r) { return l }

        // 2. Looser search: same title + artist, closest duration, synced first.
        let results: [Record] = try await get("search", ["track_name": title, "artist_name": artist]) ?? []
        let candidates = results.filter { r in
            guard let duration, let d = r.duration else { return true }
            return abs(d - duration) <= 3
        }
        let best = candidates.first { $0.syncedLyrics?.isEmpty == false } ?? candidates.first
        return best.flatMap(convert)
    }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T? {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.network
        }
        guard let http = resp as? HTTPURLResponse else { throw Failure.network }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw Failure.network }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func convert(_ r: Record) -> Lyrics? {
        if r.instrumental == true { return nil }
        if let synced = r.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return Lyrics(lines: lines, source: "LRCLIB") }
        }
        if let plain = r.plainLyrics, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines).enumerated().map { i, t in
                Lyrics.Line(id: i, text: t.trimmingCharacters(in: .whitespaces), start: nil)
            }
            return Lyrics(lines: lines, source: "LRCLIB")
        }
        return nil
    }

    /// Parses LRC: "[mm:ss.xx]text", several timestamps per line allowed,
    /// metadata tags ([ar:…]) ignored, enhanced word timings (<mm:ss.xx>) stripped.
    static func parseLRC(_ lrc: String) -> [Lyrics.Line] {
        var timed: [(TimeInterval, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let t = parseTime(tag) else { break }
                times.append(t)
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let text = stripWordTimings(String(rest)).trimmingCharacters(in: .whitespaces)
            for t in times { timed.append((t, text)) }
        }
        return timed.sorted { $0.0 < $1.0 }.enumerated().map { i, e in
            Lyrics.Line(id: i, text: e.1, start: e.0)
        }
    }

    private static func parseTime(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]),
              let s = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return m * 60 + s
    }

    private static func stripWordTimings(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = "", skipping = false
        for ch in s {
            if ch == "<" { skipping = true } else if ch == ">" { skipping = false } else if !skipping { out.append(ch) }
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }
}

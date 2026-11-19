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
        guard let q = LyricsQuery(item) else { return nil }
        let duration = item.duration

        // 1. Exact match with the names as they are (title + artist + album + duration).
        var query = ["track_name": q.titles[0], "artist_name": q.artists[0]]
        if let album = item.album, !album.isEmpty { query["album_name"] = album }
        if let duration { query["duration"] = String(Int(duration.rounded())) }
        if let r: Record = try await get("get", query), let l = convert(r) { return l }

        // 2. Searches with cleaned-up names ("Song (feat. X) - Remastered" → "Song",
        //    "A & B" → "A"), closest duration, synced first.
        for (title, artist) in q.combinations {
            let results: [Record] = try await get("search", ["track_name": title, "artist_name": artist]) ?? []
            if let l = best(results, duration: duration) { return l }
        }
        return nil
    }

    private static func best(_ results: [Record], duration: Double?) -> Lyrics? {
        let candidates = results.filter { r in
            guard let duration, let d = r.duration else { return true }
            return abs(d - duration) <= 3
        }
        let pick = candidates.first { $0.syncedLyrics?.isEmpty == false } ?? candidates.first
        return pick.flatMap(convert)
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

/// Title/artist variants to search lyrics with. Library tags often carry
/// extras that lyric databases don't: "(feat. X)", "- Remastered 2011",
/// "[Live]", or several artists in one field.
struct LyricsQuery {
    /// Original first, then cleaned-up versions (no duplicates).
    let titles: [String]
    let artists: [String]

    init?(_ item: BaseItem) {
        guard let title = item.name?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let artist = (item.artists?.first ?? item.albumArtist)?.trimmingCharacters(in: .whitespaces),
              !artist.isEmpty else { return nil }
        titles = Self.unique([title, Self.withoutExtras(title), Self.withoutAnyBrackets(title)])
        artists = Self.unique([artist, Self.mainArtist(artist)])
    }

    /// Search order: cleanest title first, at most 4 combinations.
    var combinations: [(String, String)] {
        var out: [(String, String)] = []
        for t in titles.reversed() { for a in artists.reversed() { out.append((t, a)) } }
        var seen = Set<String>()
        return Array(out.filter { seen.insert(($0.0 + "|" + $0.1).lowercased()).inserted }.prefix(4))
    }

    private static let extraWords = [
        "feat", "ft.", "featuring", "with", "con ", "remaster", "live", "en vivo", "version", "versión",
        "edit", "mix", "explicit", "clean", "mono", "stereo", "deluxe", "bonus", "acoustic", "acústic",
        "demo", "instrumental", "radio", "single", "extended", "original", "from ", "bonus track",
    ]

    private static func isExtra(_ s: String) -> Bool {
        let l = s.lowercased()
        return extraWords.contains { l.contains($0) } || l.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression) != nil
    }

    /// Drops "(feat. X)", "[Live]", " - Remastered 2011", "- Radio Edit"…
    static func withoutExtras(_ title: String) -> String {
        var t = title
        // Bracketed groups with an "extra" word inside.
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#] {
            while let r = t.range(of: pattern, options: .regularExpression), isExtra(String(t[r])) {
                t.removeSubrange(r)
            }
        }
        // " - something extra" at the end.
        if let r = t.range(of: " - ", options: .backwards), isExtra(String(t[r.upperBound...])) {
            t = String(t[..<r.lowerBound])
        }
        // Trailing "feat. X" without brackets.
        if let r = t.range(of: #"\s(feat\.?|ft\.|featuring)\s.*$"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Last resort: no brackets at all, no " - …" suffix.
    static func withoutAnyBrackets(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "A, B", "A & B", "A feat. B", "A x B" → "A".
    static func mainArtist(_ artist: String) -> String {
        var a = artist
        for sep in [",", " & ", " feat. ", " feat ", " ft. ", " x ", " X ", ";", " / "] {
            if let r = a.range(of: sep, options: .caseInsensitive) { a = String(a[..<r.lowerBound]) }
        }
        return a.trimmingCharacters(in: .whitespaces)
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

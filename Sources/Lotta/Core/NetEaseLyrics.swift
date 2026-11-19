import Foundation

/// NetEase Cloud Music's public (unofficial) web API: big catalog with synced
/// lyrics, no account or key. Last fallback after the server and LRCLIB.
/// Unofficial, so it may change without notice — failures just mean "no lyrics".
enum NetEaseLyrics {
    private static let base = URL(string: "https://music.163.com/api/")!

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String? }
            let id: Int
            let name: String?
            let artists: [Artist]?
            let duration: Int? // ms
        }
        let result: Result?
    }

    private struct LyricResponse: Decodable {
        struct Block: Decodable { let lyric: String? }
        let lrc: Block?
        let nolyric: Bool?
        let uncollected: Bool?
    }

    /// Lyrics for the track, or nil when NetEase has none / no confident match.
    /// Throws `LRCLib.Failure.network` when it can't be reached.
    static func lyrics(for item: BaseItem) async throws -> Lyrics? {
        guard let q = LyricsQuery(item) else { return nil }
        let wantedArtists = q.artists.map(LibraryStore.fold)

        for (title, artist) in q.combinations.prefix(2) {
            let response: SearchResponse? = try await get("search/get", [
                "s": "\(title) \(artist)", "type": "1", "limit": "10", "offset": "0",
            ])
            let songs = response?.result?.songs ?? []
            // Same artist, and same length (±3 s) when we know it.
            let match = songs.first { song in
                let names = (song.artists ?? []).compactMap(\.name).map(LibraryStore.fold)
                let sameArtist = names.contains { n in wantedArtists.contains { $0.contains(n) || n.contains($0) } }
                guard sameArtist else { return false }
                guard let duration = item.duration, let ms = song.duration else { return true }
                return abs(Double(ms) / 1000 - duration) <= 3
            }
            guard let match else { continue }
            let lyric: LyricResponse? = try await get("song/lyric", ["id": String(match.id), "lv": "1"])
            if lyric?.nolyric == true || lyric?.uncollected == true { return nil }
            guard let lrc = lyric?.lrc?.lyric else { return nil }
            let lines = clean(LRCLib.parseLRC(lrc))
            return lines.isEmpty ? nil : Lyrics(lines: lines, source: "NetEase")
        }
        return nil
    }

    /// NetEase prepends credit lines ("作词 : …", "作曲 : …"), marks
    /// instrumentals with "纯音乐，请欣赏" and missing lyrics with "暂无歌词"; drop those.
    private static func clean(_ lines: [Lyrics.Line]) -> [Lyrics.Line] {
        let creditMarks = ["作词", "作曲", "编曲", "制作", "混音", "母带", "和声", "吉他", "贝斯", "鼓", "录音", "监制",
                           "Lyricist", "Composer", "Arranger", "Producer", "Written by", "Mixed by", "Mastered by"]
        let kept = lines.filter { line in
            let t = line.text
            if t.contains("纯音乐") || t.contains("暂无歌词") { return false } // instrumental / "no lyrics yet"
            if t.contains(":") || t.contains("：") {
                return !creditMarks.contains { t.hasPrefix($0) || t.contains(" \($0)") || t.hasPrefix("\($0) ") }
            }
            return true
        }
        guard kept.contains(where: { !$0.text.isEmpty }) else { return [] }
        return kept.enumerated().map { i, l in Lyrics.Line(id: i, text: l.text, start: l.start) }
    }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T? {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 12
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw LRCLib.Failure.network
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LRCLib.Failure.network
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

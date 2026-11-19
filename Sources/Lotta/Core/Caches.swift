import CoreImage
import Foundation
import UIKit

enum ArtworkSize {
    static let small = 300
    static let large = 900
}

/// Disk-backed artwork cache. Images are stored permanently so the library
/// keeps its covers offline.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() { memory.countLimit = 300 }

    func image(for itemId: String, size: Int) async -> UIImage? {
        let key = "\(itemId)_\(size)"
        if let img = memory.object(forKey: key as NSString) { return img }

        let file = Storage.artwork.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }

        if let task = inFlight[key] { return await task.value }

        guard let client = ClientBox.shared.client else { return anyCached(itemId) }
        let request = client.authorizedRequest(client.imageURL(itemId: itemId, maxWidth: size))
        let task = Task<UIImage?, Never> {
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil

        if let img {
            memory.setObject(img, forKey: key as NSString)
            return img
        }
        return anyCached(itemId)
    }

    /// Downloads the image to disk if it isn't there yet (no decoding when cached).
    func prefetch(_ itemId: String, size: Int) async {
        let file = Storage.artwork.appendingPathComponent("\(itemId)_\(size).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return }
        _ = await image(for: itemId, size: size)
    }

    /// Offline fallback: any size we have on disk for this item.
    private func anyCached(_ itemId: String) -> UIImage? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Storage.artwork.path) else { return nil }
        for f in files where f.hasPrefix(itemId + "_") {
            if let img = UIImage(contentsOfFile: Storage.artwork.appendingPathComponent(f).path) { return img }
        }
        return nil
    }

    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: Storage.artwork)
        try? FileManager.default.createDirectory(at: Storage.artwork, withIntermediateDirectories: true)
    }
}

actor LyricsStore {
    static let shared = LyricsStore()

    private struct Cached: Codable {
        var lyrics: Lyrics?
        var fetched: Date
        /// 3 = server + LRCLIB (with cleaned-up names) + NetEase.
        /// Older "no lyrics" answers are re-checked.
        var v: Int? = nil
    }

    private static let version = 3
    private var memory: [String: Cached] = [:]

    /// Server first, then LRCLIB, then NetEase (each if enabled). Cached on disk for offline use.
    func lyrics(for item: BaseItem) async -> Lyrics? {
        let itemId = item.id
        if let c = memory[itemId], isFresh(c) { return c.lyrics }

        let file = Storage.lyrics.appendingPathComponent(itemId + ".json")
        let onDisk = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
        if let onDisk, isFresh(onDisk) {
            memory[itemId] = onDisk
            return onDisk.lyrics
        }

        var found: Lyrics?
        var answered = false // someone gave a definite answer (lyrics or "none")
        if let client = ClientBox.shared.client {
            do {
                found = try await client.lyrics(itemId: itemId)
                answered = true
            } catch {}
        }
        if found == nil, AppSettings.lrclibEnabled {
            do {
                found = try await LRCLib.lyrics(for: item)
                answered = true
            } catch {}
        }
        if found == nil, AppSettings.neteaseEnabled {
            do {
                found = try await NetEaseLyrics.lyrics(for: item)
                answered = true
            } catch {}
        }
        guard answered else { return onDisk?.lyrics } // offline / unreachable

        let c = Cached(lyrics: found, fetched: Date(), v: Self.version)
        memory[itemId] = c
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: file, options: .atomic) }
        return found
    }

    /// "No lyrics" answers are re-checked after a week; found lyrics are kept.
    private func isFresh(_ c: Cached) -> Bool {
        if c.lyrics != nil { return true }
        return (c.v ?? 1) >= Self.version && Date().timeIntervalSince(c.fetched) < 7 * 24 * 3600
    }

    /// Drops cached "no lyrics" answers so they're looked up again
    /// (e.g. after turning LRCLIB on).
    func forgetMissing() {
        memory = memory.filter { $0.value.lyrics != nil }
        let dir = Storage.lyrics
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            guard let data = try? Data(contentsOf: f),
                  let c = try? JSONDecoder().decode(Cached.self, from: data), c.lyrics == nil else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    func clearAll() {
        memory = [:]
        try? FileManager.default.removeItem(at: Storage.lyrics)
        try? FileManager.default.createDirectory(at: Storage.lyrics, withIntermediateDirectories: true)
    }
}

// MARK: - Color helpers

extension UIImage {
    var averageColor: UIColor? {
        guard let input = CIImage(image: self) else { return nil }
        let extent = CIVector(cgRect: input.extent)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: extent]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                       blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

extension UIColor {
    func adjusted(brightness range: ClosedRange<CGFloat>, minSaturation: CGFloat = 0) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let sat = s > 0.08 ? max(s, minSaturation) : s // keep greys grey
        return UIColor(hue: h, saturation: sat,
                       brightness: min(max(b, range.lowerBound), range.upperBound), alpha: 1)
    }

    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

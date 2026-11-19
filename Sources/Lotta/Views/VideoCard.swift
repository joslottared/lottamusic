import AVFoundation
import CoreImage
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from Photos, copied into our temp folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("lotta-pick-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

// MARK: - Looping preview

/// Muted, looping, aspect-filled video (muted so it doesn't stop the music).
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    /// Part of the video to loop (seconds); nil = all of it.
    var range: ClosedRange<Double>? = nil

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        let v = LoopingPlayerUIView()
        v.play(url, range: range)
        return v
    }

    func updateUIView(_ v: LoopingPlayerUIView, context: Context) {
        if v.url != url || v.range != range { v.play(url, range: range) }
    }

    static func dismantleUIView(_ v: LoopingPlayerUIView, coordinator: ()) { v.stop() }
}

final class LoopingPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var looper: AVPlayerLooper?
    private(set) var url: URL?
    private(set) var range: ClosedRange<Double>?

    func play(_ url: URL, range: ClosedRange<Double>? = nil) {
        stop()
        self.url = url
        self.range = range
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
        if let range {
            let timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                        end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: timeRange)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        player.play()
    }

    func stop() {
        playerLayer.player?.pause()
        playerLayer.player = nil
        looper = nil
    }
}

// MARK: - Export

enum VideoCardExporter {
    /// Frame rate of every exported card video.
    static let fps: Int32 = 30

    /// Longest clip used for a (non-animated) video card.
    static let maxDuration: Double = 15
    /// Longest gallery video accepted (you then pick which part to use).
    static let maxSourceDuration: Double = 300
    static let size = CGSize(width: 1080, height: 1920)

    enum Failure: LocalizedError {
        case noVideo, exportFailed(String?)
        var errorDescription: String? {
            switch self {
            case .noVideo: "El archivo no tiene video."
            case .exportFailed(let m): "No se pudo crear el video\(m.map { ": \($0)" } ?? ".")"
            }
        }
    }

    static func duration(of url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        return d.seconds.isFinite ? d.seconds : nil
    }

    // MARK: Frame building (shared by both exporters)

    static var canvas: CGRect { CGRect(origin: .zero, size: size) }

    /// Aspect-fills an (already oriented) frame onto the 1080×1920 canvas.
    static func fill(_ src: CIImage) -> CIImage {
        let e = src.extent
        let scale = max(size.width / e.width, size.height / e.height)
        return src
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (size.width - e.width * scale) / 2,
                                               y: (size.height - e.height * scale) / 2))
            .cropped(to: canvas)
    }

    /// Frosted glass, cheaply: only the card's area (plus blur margin) is
    /// blurred, at quarter resolution, then scaled back up — a blur doesn't
    /// need full-res pixels, and this is ~30× less work than blurring 1080×1920.
    static func glass(_ bg: CIImage, mask: CIImage, maskRect: CGRect, sigma: CGFloat) -> CIImage {
        let f: CGFloat = 0.25
        let region = maskRect.insetBy(dx: -sigma * 2, dy: -sigma * 2).intersection(canvas)
        guard !region.isEmpty else { return bg }
        let small = bg.cropped(to: region).transformed(by: CGAffineTransform(scaleX: f, y: f))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma * f)
            .cropped(to: small.extent)
            .transformed(by: CGAffineTransform(scaleX: 1 / f, y: 1 / f))
        return blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Bounding box of the mask's opaque pixels, in Core Image coordinates.
    static func opaqueRect(of image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let ok = alpha.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return CGRect(x: 0, y: 0, width: w, height: h) }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            let row = y * w
            for x in stride(from: 0, to: w, by: 2) where alpha[row + x] > 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return .zero }
        // Bitmap memory starts at the top row; Core Image's origin is bottom-left.
        return CGRect(x: minX - 2, y: h - maxY - 3, width: maxX - minX + 4, height: maxY - minY + 4)
    }

    /// Writes a 1080×1920 MP4: the video aspect-filled, frosted glass inside
    /// the card shape (`mask`), and the card (`overlay`) on top. Keeps the
    /// video's own audio. Output at 30 fps.
    static func export(video: URL, start: Double, length: Double,
                       overlay: UIImage, mask: UIImage, blur: CGFloat) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)

        guard let overlayCG = overlay.cgImage, let maskCG = mask.cgImage else { throw Failure.exportFailed(nil) }
        // Rendered at 1080×1920, so they line up with the canvas pixel for pixel.
        let overlayCI = CIImage(cgImage: overlayCG)
        let maskCI = CIImage(cgImage: maskCG)
        let maskRect = opaqueRect(of: maskCG)

        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let bg = fill(request.sourceImage)
            let frame = overlayCI.composited(over: glass(bg, mask: maskCI, maskRect: maskRect, sigma: blur))
            request.finish(with: frame.cropped(to: canvas), context: nil)
        }
        composition.renderSize = size
        if fps > Float(Self.fps) + 0.5 { composition.frameDuration = CMTime(value: 1, timescale: Self.fps) }

        let out = tempURL()
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed(nil)
        }
        session.videoComposition = composition
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let from = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let available = CMTimeSubtract(duration, from)
        session.timeRange = CMTimeRange(start: from,
                                        duration: CMTimeMinimum(available, CMTime(seconds: length, preferredTimescale: 600)))
        await session.export()
        guard session.status == .completed else {
            throw Failure.exportFailed(session.error?.localizedDescription)
        }
        return out
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Lotta-letra-\(UUID().uuidString.prefix(6)).mp4")
    }
}

// MARK: - Animated lyrics

/// When each selected line shows: it cross-fades in at its synced time and
/// out when the next line starts (one line on screen at a time).
struct LyricTimeline: Sendable {
    let offsets: [Double]
    let duration: Double

    static let fade = 0.25

    func opacities(at t: Double) -> [Double] {
        offsets.indices.map { i in
            let o = offsets[i]
            guard t >= o else { return 0 }
            if i + 1 < offsets.count, t >= offsets[i + 1] {
                return max(0, 1 - (t - offsets[i + 1]) / Self.fade)
            }
            return min(1, (t - o) / Self.fade)
        }
    }

    /// Settled look after `k` lines have started (k = 0…count): only line k-1.
    func state(_ k: Int) -> [Double] {
        offsets.indices.map { i in i == k - 1 ? 1 : 0 }
    }

    /// Which state we're in at `t`, and how far the fade into it has gone.
    func position(at t: Double) -> (state: Int, progress: Double) {
        let k = offsets.filter { $0 <= t }.count
        guard k > 0 else { return (0, 1) }
        return (k, min(1, (t - offsets[k - 1]) / Self.fade))
    }
}

/// Builds the animated lyric video frame by frame with AVAssetWriter (no
/// audio): a still background (pre-rendered, so frames are just a blend) or
/// the user's video looped, with the card states cross-faded on top.
enum CardVideoWriter {
    enum Background {
        case still(UIImage)
        /// The part of the video from `start`, looped if shorter than the fragment.
        case video(URL, start: Double, mask: UIImage, blur: CGFloat)
    }

    static let fps = VideoCardExporter.fps

    /// `audio`: the song file and where the fragment starts in it.
    static func write(background: Background, states: [UIImage], timeline: LyricTimeline,
                      audio: (url: URL, start: Double)? = nil,
                      progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        let size = VideoCardExporter.size
        let canvas = VideoCardExporter.canvas
        let overlays = states.compactMap { $0.cgImage.map(CIImage.init(cgImage:)) }
        guard overlays.count == states.count, !overlays.isEmpty else { throw VideoCardExporter.Failure.exportFailed(nil) }

        let out = VideoCardExporter.tempURL()
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
        var pump: AudioPump?
        if let audio {
            // Best effort: if the song can't be read, the video is made without it.
            pump = try? await AudioPump(url: audio.url, start: audio.start, duration: timeline.duration)
            if let pump { writer.add(pump.input) }
        }
        guard writer.startWriting() else { throw VideoCardExporter.Failure.exportFailed(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)
        pump?.start()

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        var still: CIImage?
        var source: LoopingFrameSource?
        var maskCI: CIImage?, maskRect = CGRect.zero, blur: CGFloat = 0
        switch background {
        case .still(let image):
            guard let cg = image.cgImage else { throw VideoCardExporter.Failure.exportFailed(nil) }
            still = CIImage(cgImage: cg)
        case .video(let url, let start, let mask, let b):
            guard let cg = mask.cgImage else { throw VideoCardExporter.Failure.exportFailed(nil) }
            source = try await LoopingFrameSource(url: url, start: start, length: timeline.duration)
            maskCI = CIImage(cgImage: cg)
            maskRect = VideoCardExporter.opaqueRect(of: cg)
            blur = b
        }

        let frameCount = Int((timeline.duration * Double(fps)).rounded(.up))
        for n in 0..<frameCount {
            try Task.checkCancellation()
            let t = Double(n) / Double(fps)

            // Audio is fed alongside the frames. The writer interleaves the two
            // tracks (in ~1 s chunks) and holds video back until it has enough
            // audio ahead — so while video waits, give audio all it will take.
            pump?.feed(until: t + 1)
            var waited = 0
            while !input.isReadyForMoreMediaData {
                pump?.feed(until: .infinity)
                try await Task.sleep(for: .milliseconds(4))
                waited += 1
                if waited > 2500 { // ~10 s with neither track moving
                    throw VideoCardExporter.Failure.exportFailed("el codificador dejó de responder")
                }
                if writer.status == .failed {
                    throw VideoCardExporter.Failure.exportFailed(writer.error?.localizedDescription)
                }
            }
            if n % 15 == 0 { await progress(Double(n) / Double(frameCount)) }

            // Everything Core Image/AVFoundation hands back for this frame is
            // released here, every frame. Without the pool those objects pile up
            // until the loop ends — and with a video background each one holds a
            // whole decoded frame (≈33 MB in 4K), so iOS kills the app.
            try autoreleasepool {
                var bg: CIImage
                if let still {
                    bg = still
                } else if let source, let maskCI, let frame = source.frame(at: t) {
                    bg = VideoCardExporter.glass(VideoCardExporter.fill(frame), mask: maskCI, maskRect: maskRect, sigma: blur)
                } else {
                    bg = CIImage(color: .black).cropped(to: canvas)
                }

                let (k, p) = timeline.position(at: t)
                var overlay = overlays[min(k, overlays.count - 1)]
                if p < 1, k > 0 {
                    overlay = overlays[k - 1].applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: overlay, kCIInputTimeKey: p,
                    ])
                }
                let frame = overlay.composited(over: bg).cropped(to: canvas)

                guard let pool = adaptor.pixelBufferPool else { throw VideoCardExporter.Failure.exportFailed(nil) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw VideoCardExporter.Failure.exportFailed(nil) }
                context.render(frame, to: buffer, bounds: canvas, colorSpace: colorSpace)
                if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: fps)) {
                    throw VideoCardExporter.Failure.exportFailed(writer.error?.localizedDescription)
                }
            }
        }
        input.markAsFinished()
        while let p = pump, !p.finished {
            p.feed(until: .infinity)
            if !p.finished { try await Task.sleep(for: .milliseconds(4)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoCardExporter.Failure.exportFailed(writer.error?.localizedDescription)
        }
        return out
    }
}

/// Reads the song fragment as PCM (with short fades so it doesn't start or
/// end with a click), retimed to start at 0, and feeds it to an AAC input.
final class AudioPump {
    let input: AVAssetWriterInput
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let offset: CMTime
    private let duration: Double
    private var pending: CMSampleBuffer?
    private(set) var finished = false

    static let sampleRate = 44_100.0
    static let fadeIn = 0.15
    static let fadeOut = 0.6

    init(url: URL, start: Double, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw VideoCardExporter.Failure.exportFailed("la canción no tiene audio")
        }
        reader = try AVAssetReader(asset: asset)
        offset = CMTime(seconds: start, preferredTimescale: 44_100)
        self.duration = duration
        reader.timeRange = CMTimeRange(start: offset, duration: CMTime(seconds: duration, preferredTimescale: 44_100))
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = false
    }

    func start() {
        if !reader.startReading() { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        input.markAsFinished()
    }

    /// Appends samples up to `t` seconds (fragment time) while the input takes them.
    func feed(until t: Double) {
        while !finished, input.isReadyForMoreMediaData {
            let keepGoing: Bool = autoreleasepool {
                if pending == nil { pending = next() }
                guard let buffer = pending else { finish(); return false }
                if CMSampleBufferGetPresentationTimeStamp(buffer).seconds > t { return false }
                if !input.append(buffer) { finish(); return false } // writer failed: stop feeding
                pending = nil
                return true
            }
            if !keepGoing { return }
        }
    }

    private func next() -> CMSampleBuffer? {
        while let raw = output.copyNextSampleBuffer() {
            guard let b = retimed(raw) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(b).seconds
            if pts < 0 { continue }
            applyFades(b, startingAt: pts)
            return b
        }
        return nil
    }

    private func retimed(_ b: CMSampleBuffer) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(b, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(b, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            timing[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: b, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Interleaved 16-bit stereo: scales samples near the start/end of the fragment.
    private func applyFades(_ b: CMSampleBuffer, startingAt pts: Double) {
        let frames = CMSampleBufferGetNumSamples(b)
        let end = pts + Double(frames) / Self.sampleRate
        guard pts < Self.fadeIn || end > duration - Self.fadeOut,
              let block = CMSampleBufferGetDataBuffer(b) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) else { return }
        let samples = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Int16.self)
        let n = min(frames, length / 4)
        for f in 0..<n {
            let t = pts + Double(f) / Self.sampleRate
            let gain = max(0, min(1, t / Self.fadeIn, (duration - t) / Self.fadeOut))
            guard gain < 1 else { continue }
            samples[2 * f] = Int16(Double(samples[2 * f]) * gain)
            samples[2 * f + 1] = Int16(Double(samples[2 * f + 1]) * gain)
        }
    }
}

/// The song as a local file: the download if there is one, otherwise a
/// temporary copy from the server (MP3 320, so it's quick to fetch).
enum SongAudio {
    @MainActor
    static func file(for item: BaseItem, downloads: DownloadManager) async throws -> (url: URL, temporary: Bool) {
        if let local = downloads.localURL(for: item.id) { return (local, false) }
        guard let client = ClientBox.shared.client else { throw JellyfinError.offline }
        var request = client.authorizedRequest(client.audioURL(itemId: item.id, quality: .high))
        request.timeoutInterval = 60
        let (tmp, response) = try await URLSession.shared.download(for: request)
        try JellyfinClient.check(response)
        let ext = DownloadManager.fileExtension(mime: response.mimeType, url: response.url)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("lotta-song-\(item.id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return (dest, true)
    }
}

/// Decodes a video's frames in order, oriented, looping back to the start
/// when the requested time passes its end.
final class LoopingFrameSource {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let orientation: CGImagePropertyOrientation
    private let start: Double
    private let length: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, image: CIImage)?
    private var upcoming: (time: Double, image: CIImage)?
    private var loopStart: Double = 0

    /// Plays `length` seconds from `start` (less if the video ends first), looping.
    init(url: URL, start: Double = 0, length: Double = .infinity) async throws {
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCardExporter.Failure.noVideo
        }
        track = t
        let transform = try await t.load(.preferredTransform)
        orientation = Self.orientation(transform)
        let total = try await asset.load(.duration).seconds
        self.start = min(max(0, start), max(0, total - 0.1))
        self.length = max(0.1, min(length, total - self.start))
        try restart()
    }

    private static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    private func restart() throws {
        upcoming = nil
        output = nil
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                  duration: CMTime(seconds: length, preferredTimescale: 600))
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        o.alwaysCopiesSampleData = false
        r.add(o)
        reader = r
        // A reader that didn't start must never be asked for samples.
        output = r.startReading() ? o : nil
    }

    private func readNext() -> (Double, CIImage)? {
        guard let sample = output?.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
        return (time, CIImage(cvPixelBuffer: buffer).oriented(orientation))
    }

    /// Frame on screen at output time `t` (seconds, increasing).
    func frame(at t: Double) -> CIImage? {
        var local = t - loopStart
        if local >= length {
            // Past the end: loop.
            loopStart += length
            local = t - loopStart
            current = nil
            try? restart()
        }
        if upcoming == nil { upcoming = readNext() }
        while let next = upcoming, next.time <= local {
            current = next
            upcoming = readNext()
        }
        if current == nil, let next = upcoming { current = next }
        return current?.image
    }
}

// MARK: - Picking the part of a long video

/// Filmstrip with a window the size of the clip; drag to choose where it starts.
struct VideoTrimmer: View {
    let url: URL
    let videoLength: Double
    let clipLength: Double
    @Binding var start: Double
    var onCommit: () -> Void

    @State private var thumbnails: [UIImage] = []
    @State private var dragging = false
    private static let count = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let windowWidth = max(28, w * min(1, clipLength / videoLength))
                let x = (start / max(videoLength - clipLength, 0.001)) * (w - windowWidth)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(uiImage: thumbnails[i]).resizable().scaledToFill()
                                .frame(width: w / CGFloat(Self.count), height: 46).clipped()
                        }
                    }
                    .frame(width: w, height: 46, alignment: .leading)
                    .background(Color.gray.opacity(0.3))
                    // Dim what's left out.
                    Color.black.opacity(0.5).frame(width: max(0, x))
                    Color.black.opacity(0.5).frame(width: max(0, w - x - windowWidth)).offset(x: x + windowWidth)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.yellow, lineWidth: 3)
                        .frame(width: windowWidth, height: 46)
                        .offset(x: x)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragging = true
                            let free = max(w - windowWidth, 1)
                            let fraction = min(max((v.location.x - windowWidth / 2) / free, 0), 1)
                            start = fraction * max(videoLength - clipLength, 0)
                        }
                        .onEnded { _ in
                            dragging = false
                            onCommit()
                        }
                )
            }
            .frame(height: 46)
            Text("Desde \(formatTime(start)) · \(Int(clipLength.rounded())) s · arrastra para elegir la parte")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .sensoryFeedback(.selection, trigger: dragging)
        .task(id: url) { await loadThumbnails() }
    }

    private func loadThumbnails() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var images: [UIImage] = []
        for i in 0..<Self.count {
            let t = CMTime(seconds: videoLength * (Double(i) + 0.5) / Double(Self.count), preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: t) { images.append(UIImage(cgImage: cg)) }
        }
        thumbnails = images
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareableFile: Identifiable {
    let url: URL
    var id: URL { url }
}

extension PhotoSaver {
    static func saveVideo(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return true
        } catch {
            return false
        }
    }
}

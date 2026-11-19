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

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        let v = LoopingPlayerUIView()
        v.play(url)
        return v
    }

    func updateUIView(_ v: LoopingPlayerUIView, context: Context) {
        if v.url != url { v.play(url) }
    }

    static func dismantleUIView(_ v: LoopingPlayerUIView, coordinator: ()) { v.stop() }
}

final class LoopingPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    func play(_ url: URL) {
        self.url = url
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
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
    static let maxDuration: Double = 15
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

    /// Writes a 1080×1920 MP4: the video aspect-filled, a blurred copy of it
    /// inside the card shape (`mask`), and the card (`overlay`) on top.
    /// Keeps the video's own audio.
    static func export(video: URL, overlay: UIImage, mask: UIImage, blur: CGFloat) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.noVideo }
        let duration = try await asset.load(.duration)

        guard let overlayCG = overlay.cgImage, let maskCG = mask.cgImage else { throw Failure.exportFailed(nil) }
        let canvas = CGRect(origin: .zero, size: size)
        // Rendered at 1080×1920, so they line up with the canvas pixel for pixel.
        let overlayCI = CIImage(cgImage: overlayCG)
        let maskCI = CIImage(cgImage: maskCG)
        let target = size

        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let src = request.sourceImage
            let e = src.extent
            let scale = max(target.width / e.width, target.height / e.height)
            let bg = src
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (target.width - e.width * scale) / 2,
                                                   y: (target.height - e.height * scale) / 2))
                .cropped(to: canvas)
            let blurred = bg.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: canvas)
            let glass = blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: bg,
                kCIInputMaskImageKey: maskCI,
            ])
            request.finish(with: overlayCI.composited(over: glass).cropped(to: canvas), context: nil)
        }
        composition.renderSize = size

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Lotta-letra-\(UUID().uuidString.prefix(6)).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed(nil)
        }
        session.videoComposition = composition
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: .zero,
                                        duration: CMTimeMinimum(duration, CMTime(seconds: maxDuration, preferredTimescale: 600)))
        await session.export()
        guard session.status == .completed else {
            throw Failure.exportFailed(session.error?.localizedDescription)
        }
        return out
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

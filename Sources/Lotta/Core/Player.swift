import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [BaseItem] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?
    private var itemStatusObservation: NSKeyValueObservation?

    var current: BaseItem? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: ArraySlice<BaseItem> { queue.indices.contains(index) ? queue[(index + 1)...] : [] }

    weak var downloads: DownloadManager?
    var isOnline: () -> Bool = { true }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var nowArtwork: (id: String, artwork: MPMediaItemArtwork)?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - self.duration) > 0.5 {
                    self.duration = d
                    self.updateNowPlaying()
                }
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.advance(auto: true)
            }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) else { return }
            MainActor.assumeIsolated { self?.resume() }
        }

        setupRemoteCommands()
    }

    // MARK: - Queue

    func isPlayable(_ item: BaseItem) -> Bool {
        downloads?.isDownloaded(item.id) == true || (ClientBox.shared.client != nil && isOnline())
    }

    func play(_ tracks: [BaseItem], startAt: Int = 0, shuffle: Bool = false) {
        var list = tracks.filter(isPlayable)
        guard !list.isEmpty else { return }
        var start = 0
        if shuffle {
            list.shuffle()
        } else if tracks.indices.contains(startAt) {
            let target = tracks[startAt]
            guard isPlayable(target) else { return }
            start = list.firstIndex { $0.id == target.id } ?? 0
        }
        queue = list
        index = start
        load(autoplay: true)
    }

    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        load(autoplay: true)
    }

    func playNext(_ item: BaseItem) {
        guard current != nil else { return play([item]) }
        queue.insert(item, at: index + 1)
    }

    func addToQueue(_ item: BaseItem) {
        guard current != nil else { return play([item]) }
        queue.append(item)
    }

    func removeFromQueue(at offset: Int) {
        guard offset != index, queue.indices.contains(offset) else { return }
        queue.remove(at: offset)
        if offset < index { index -= 1 }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil { return load(autoplay: true) }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() { advance(auto: false) }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load(autoplay: true)
        }
    }

    /// Always goes to the previous track (swipe), unlike `previous()` which
    /// first restarts the current one.
    func previousTrack() {
        guard index > 0 else { return seek(to: 0) }
        index -= 1
        load(autoplay: true)
    }

    func seek(to seconds: TimeInterval) {
        let t = max(0, seconds)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    private func advance(auto: Bool) {
        if auto && repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        var i = index + 1
        while i < queue.count && !isPlayable(queue[i]) { i += 1 }
        if i < queue.count {
            index = i
            load(autoplay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            load(autoplay: true)
        } else {
            player.pause()
            seek(to: 0)
            isPlaying = false
        }
    }

    private func load(autoplay: Bool) {
        guard let item = current else { return }
        let asset: AVURLAsset
        if let local = downloads?.localURL(for: item.id) {
            asset = AVURLAsset(url: local)
        } else if isOnline(), let client = ClientBox.shared.client {
            let url = client.audioURL(itemId: item.id, quality: AppSettings.streamQuality)
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders])
        } else {
            return advance(auto: false)
        }

        errorMessage = nil
        let playerItem = AVPlayerItem(asset: asset)
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            let message = Self.describe(it.error)
            Task { @MainActor in
                guard let self, self.player.currentItem === it else { return }
                self.errorMessage = message
                self.isPlaying = false
            }
        }
        player.replaceCurrentItem(with: playerItem)
        currentTime = 0
        duration = item.duration ?? 0
        if autoplay {
            activateSession()
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
        loadNowPlayingArtwork(for: item)
    }

    private nonisolated static func describe(_ error: Error?) -> String {
        let ns = error as NSError?
        let underlying = ns?.userInfo[NSUnderlyingErrorKey] as? NSError
        if ns?.code == -16840 || underlying?.code == -16840 || underlying?.code == -12937 {
            return "El servidor rechazó la reproducción (sin autorización)."
        }
        return "No se pudo reproducir: \(ns?.localizedDescription ?? "error desconocido")"
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
    }

    // MARK: - Lock screen / Control Center

    private func updateNowPlaying() {
        guard let item = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.trackArtist,
            MPMediaItemPropertyAlbumTitle: item.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let nowArtwork, nowArtwork.id == item.artworkItemId {
            info[MPMediaItemPropertyArtwork] = nowArtwork.artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadNowPlayingArtwork(for item: BaseItem) {
        let artId = item.artworkItemId
        guard nowArtwork?.id != artId else { return }
        Task {
            guard let img = await ArtworkCache.shared.image(for: artId, size: ArtworkSize.large) else { return }
            nowArtwork = (artId, Self.makeArtwork(img))
            updateNowPlaying()
        }
    }

    /// Built outside the main actor: MediaPlayer calls the handler on a background queue.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }
}

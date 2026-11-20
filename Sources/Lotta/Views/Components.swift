import AVKit
import SwiftUI

struct ArtworkView: View {
    let itemId: String?
    var size: Int = ArtworkSize.small
    var cornerRadius: CGFloat = 8
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: itemId) {
                guard let itemId else { image = nil; return }
                image = await ArtworkCache.shared.image(for: itemId, size: size)
            }
    }
}

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}

struct DownloadIndicator: View {
    let state: DownloadState

    var body: some View {
        switch state {
        case .done:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let p):
            ProgressRing(progress: p).frame(width: 14, height: 14)
        case .queued:
            ProgressRing(progress: 0).frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        case .none, .partial:
            EmptyView()
        }
    }
}

struct TrackRow: View {
    let track: BaseItem
    var showArtwork = false

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var network: NetworkMonitor

    private var isCurrent: Bool { player.current?.id == track.id }
    private var isAvailable: Bool { network.isOnline || downloads.isDownloaded(track.id) }

    var body: some View {
        HStack(spacing: 12) {
            if showArtwork {
                ArtworkView(itemId: track.artworkItemId, cornerRadius: 4)
                    .frame(width: 44, height: 44)
            } else {
                Group {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .foregroundStyle(.tint)
                    } else {
                        Text(track.indexNumber.map(String.init) ?? "–")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.monospacedDigit())
                .frame(width: 26)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if showArtwork || track.trackArtist != track.albumArtist {
                    Text(track.trackArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            DownloadIndicator(state: downloads.state(for: track.id))
            if let d = track.duration {
                Text(formatTime(d))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isAvailable ? 1 : 0.35)
        .contentShape(Rectangle())
    }
}

struct TrackContextMenu: ViewModifier {
    let track: BaseItem
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadManager
    @State private var addToPlaylist = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { player.playNext(track) } label: {
                Label("Reproducir a continuación", systemImage: "text.insert")
            }
            Button { player.addToQueue(track) } label: {
                Label("Añadir a la cola", systemImage: "text.append")
            }
            Button { addToPlaylist = true } label: {
                Label("Añadir a playlist…", systemImage: "music.note.list")
            }
            Divider()
            if downloads.isDownloaded(track.id) {
                Button(role: .destructive) { downloads.delete([track.id]) } label: {
                    Label("Eliminar descarga", systemImage: "trash")
                }
            } else if downloads.pending[track.id] == nil {
                Button { downloads.download([track]) } label: {
                    Label("Descargar", systemImage: "arrow.down.circle")
                }
            }
        }
        .sheet(isPresented: $addToPlaylist) { AddToPlaylistView(tracks: [track]) }
    }
}

extension View {
    func trackContextMenu(_ track: BaseItem) -> some View {
        modifier(TrackContextMenu(track: track))
    }

    func itemDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { item in
            if item.isArtist {
                ArtistView(artist: item)
            } else if item.isPlaylist {
                PlaylistView(playlist: item)
            } else {
                AlbumView(album: item)
            }
        }
    }
}

struct ArtistRow: View {
    let artist: BaseItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: artist.id)
                .frame(width: 48, height: 48)
                .clipShape(Circle())
            Text(artist.title).lottaLower().lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct AlbumRow: View {
    let album: BaseItem
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: album.id, cornerRadius: 6)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).lottaLower().lineLimit(1)
                Text(subtitle ?? album.artistLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.7)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

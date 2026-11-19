import SwiftUI

struct MainView: View {
    @State private var showPlayer = false

    var body: some View {
        TabView {
            NavigationStack { LibraryView().itemDestinations() }
                .miniPlayer(showPlayer: $showPlayer)
                .tabItem { Label("Biblioteca", systemImage: "square.stack.fill") }

            NavigationStack { DownloadsView().itemDestinations() }
                .miniPlayer(showPlayer: $showPlayer)
                .tabItem { Label("Descargas", systemImage: "arrow.down.circle.fill") }

            NavigationStack { SearchView().itemDestinations() }
                .miniPlayer(showPlayer: $showPlayer)
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView()
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    @Binding var showPlayer: Bool
    @EnvironmentObject private var player: Player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayer { showPlayer = true }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: player.current == nil)
    }
}

extension View {
    func miniPlayer(showPlayer: Binding<Bool>) -> some View {
        modifier(MiniPlayerInset(showPlayer: showPlayer))
    }
}

struct MiniPlayer: View {
    var onTap: () -> Void
    @EnvironmentObject private var player: Player
    @State private var swipeOffset: CGFloat = 0
    @State private var skipCount = 0

    /// Swipe left → next track, right → previous track.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { g in
                guard abs(g.translation.width) > abs(g.translation.height) else { return }
                swipeOffset = g.translation.width
            }
            .onEnded { g in
                let w = swipeOffset, predicted = g.predictedEndTranslation.width
                if w < -60 || (w < 0 && predicted < -180) {
                    player.next()
                    skipCount += 1
                } else if w > 60 || (w > 0 && predicted > 180) {
                    player.previousTrack()
                    skipCount += 1
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { swipeOffset = 0 }
            }
    }

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                ArtworkView(itemId: item.artworkItemId, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let error = player.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else {
                        Text(item.trackArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                    Capsule().fill(.tint)
                        .frame(width: geo.size.width * fraction, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
            }
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
            .offset(x: swipeOffset)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(swipe)
            .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
        }
    }
}

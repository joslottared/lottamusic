import SwiftUI

enum MainTab: Hashable { case library, downloads, search }

private struct OpenPlayerKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct SelectTabKey: EnvironmentKey {
    static let defaultValue: (MainTab) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Opens the full-screen player.
    var openPlayer: () -> Void {
        get { self[OpenPlayerKey.self] }
        set { self[OpenPlayerKey.self] = newValue }
    }

    /// Switches the main tab (e.g. the library's search button).
    var selectTab: (MainTab) -> Void {
        get { self[SelectTabKey.self] }
        set { self[SelectTabKey.self] = newValue }
    }
}

struct MainView: View {
    @State private var showPlayer = false
    @State private var tab: MainTab = .library
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var network: NetworkMonitor

    init() {
        // Editorial large titles ("descargas", "buscar"): condensed, tight
        // tracking, scaled with Dynamic Type.
        let base = UIFont.systemFont(ofSize: 40, weight: .heavy, width: .condensed)
        let font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: base)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: font, .kern: -1.2]
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { LibraryView().itemDestinations() }
                .miniPlayer(showPlayer: $showPlayer)
                .tabItem { Label("Biblioteca", systemImage: "square.stack.fill") }
                .tag(MainTab.library)

            NavigationStack { DownloadsView().itemDestinations() }
                .miniPlayer(showPlayer: $showPlayer)
                .tabItem { Label("Descargas", systemImage: "arrow.down.circle.fill") }
                .tag(MainTab.downloads)

            NavigationStack { SearchView().itemDestinations() }
                .miniPlayer(showPlayer: $showPlayer)
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
                .tag(MainTab.search)
        }
        .modifier(FloatingTabStyle())
        .tint(Theme.accentMark)
        .environment(\.openPlayer) { showPlayer = true }
        .environment(\.selectTab) { tab = $0 }
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView()
        }
        .task { if network.isOnline { library.autoSyncIfNeeded() } }
    }
}

/// The system's floating tab bar: Liquid Glass on iOS 26 (automatic with the
/// current SDK), the adaptable style on iOS 18, the classic bar on iOS 17.
private struct FloatingTabStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
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
    @State private var lyrics: Lyrics?

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

    /// Current synced lyric line, if any.
    private var lyricLine: String? {
        guard let lyrics, let i = lyrics.currentIndex(at: player.currentTime),
              lyrics.lines.indices.contains(i) else { return nil }
        let text = lyrics.lines[i].text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                ArtworkView(itemId: item.artworkItemId, cornerRadius: 10)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lottaLower().lineLimit(1)
                    if let error = player.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if let line = lyricLine {
                        Text(line)
                            .font(.caption)
                            .lottaLower()
                            .foregroundStyle(Theme.accentMark)
                            .lineLimit(1)
                            .id(line)
                            .transition(.opacity)
                    } else {
                        Text(item.trackArtist).font(.caption).lottaLower().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: lyricLine)
                Spacer(minLength: 4)
                Button { player.togglePlayPause() } label: {
                    let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.body.weight(.bold))
                        .frame(width: 38, height: 38)
                        .overlay { ProgressRing(progress: fraction, lineWidth: 2.5).tint(Theme.accentMark) }
                        .frame(width: Theme.minTap, height: Theme.minTap)
                        .contentShape(Circle())
                }
                .accessibilityLabel(player.isPlaying ? "Pausa" : "Reproducir")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.body.weight(.bold))
                        .frame(width: Theme.minTap, height: Theme.minTap)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Siguiente")
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .lottaGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .offset(x: swipeOffset)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(swipe)
            .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
            .task(id: item.id) {
                lyrics = nil
                lyrics = await LyricsStore.shared.lyrics(for: item)
            }
        }
    }
}

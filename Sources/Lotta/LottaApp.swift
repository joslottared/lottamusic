import Combine
import SwiftUI

extension Color {
    static let lotta = Color(red: 0.98, green: 0.30, blue: 0.36)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var creds: ServerCredentials?

    let library = LibraryStore()
    let downloads = DownloadManager()
    let player = Player()
    let network = NetworkMonitor()

    private init() {
        creds = CredentialStore.load()
        ClientBox.shared.client = creds.map(JellyfinClient.init(creds:))
        library.downloads = downloads
        player.downloads = downloads
        player.isOnline = { [weak self] in self?.network.isOnline ?? true }
        downloads.start()
    }

    func login(server: String, username: String, password: String) async throws {
        guard let url = JellyfinClient.normalize(server) else { throw JellyfinError.invalidURL }
        let c = try await JellyfinClient.login(server: url, username: username, password: password)
        CredentialStore.save(c)
        ClientBox.shared.client = JellyfinClient(creds: c)
        creds = c
        downloads.start()
        await library.refresh()
    }

    func logout() {
        player.stop()
        downloads.deleteAll()
        library.reset()
        Task {
            await ArtworkCache.shared.clearAll()
            await LyricsStore.shared.clearAll()
        }
        CredentialStore.clear()
        ClientBox.shared.client = nil
        creds = nil
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppModel.shared.downloads.backgroundCompletion = completionHandler
    }
}

@main
struct LottaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.library)
                .environmentObject(model.downloads)
                .environmentObject(model.player)
                .environmentObject(model.network)
                .tint(.lotta)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.creds == nil {
                LoginView()
            } else {
                MainView()
            }
        }
        .animation(.default, value: model.creds == nil)
    }
}

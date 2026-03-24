import SwiftUI
import SwiftData
import GoogleSignIn

@main
struct AdditApp: App {
    @State private var authService = GoogleAuthService()
    @State private var driveService = GoogleDriveService()
    @State private var playerService = AudioPlayerService()
    @State private var cacheService = AudioCacheService()
    @State private var albumArtService = AlbumArtService()
    @State private var themeService = ThemeService()
    @State private var analyzerService = AudioAnalyzerService()

    var body: some Scene {
        WindowGroup {
            AccountContainerView()
                .environment(authService)
                .environment(driveService)
                .environment(playerService)
                .environment(cacheService)
                .environment(albumArtService)
                .environment(themeService)
                .environment(analyzerService)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    driveService.authService = authService
                    cacheService.driveService = driveService
                    albumArtService.driveService = driveService
                    playerService.cacheService = cacheService
                    playerService.albumArtService = albumArtService
                    analyzerService.configure(playerService: playerService)
                    await authService.restorePreviousSignIn()
                }
        }
    }
}

/// Wrapper view that creates a per-account ModelContainer and swaps it when accounts change
struct AccountContainerView: View {
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioCacheService.self) private var cacheService
    @Environment(AlbumArtService.self) private var albumArtService

    var body: some View {
        Group {
            if authService.isRestoringSession {
                // Wait for auth to resolve before creating any ModelContainer
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("addit")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let email = authService.userEmail {
                ContentView()
                    .modelContainer(Self.container(for: email))
                    .id(email)
                    .onAppear {
                        let accountId = AccountManager.storageIdentifier(for: email)
                        cacheService.activeAccountId = accountId
                        albumArtService.activeAccountId = accountId
                    }
                    .onChange(of: authService.userEmail) { _, newEmail in
                        if let newEmail {
                            let accountId = AccountManager.storageIdentifier(for: newEmail)
                            cacheService.activeAccountId = accountId
                            albumArtService.activeAccountId = accountId
                        }
                    }
            } else {
                // Not signed in — use a lightweight in-memory container
                ContentView()
                    .modelContainer(Self.signedOutContainer)
            }
        }
    }

    private static var containerCache: [String: ModelContainer] = [:]

    private static let signedOutContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Album.self, Track.self, configurations: config)
    }()

    static func container(for email: String) -> ModelContainer {
        if let cached = containerCache[email] {
            return cached
        }

        let storageId = AccountManager.storageIdentifier(for: email)
        let storeURL = URL.applicationSupportDirectory.appending(path: "\(storageId).store")

        // Clean up legacy default.store on first account-specific launch
        let defaultStore = URL.applicationSupportDirectory.appending(path: "default.store")
        if FileManager.default.fileExists(atPath: defaultStore.path) {
            try? FileManager.default.removeItem(at: defaultStore)
            try? FileManager.default.removeItem(at: defaultStore.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: defaultStore.appendingPathExtension("shm"))
        }

        let config = ModelConfiguration(url: storeURL)

        do {
            let container = try ModelContainer(for: Album.self, Track.self, configurations: config)
            containerCache[email] = container
            return container
        } catch {
            print("ModelContainer creation failed for \(email): \(error). Resetting store.")
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            do {
                let container = try ModelContainer(for: Album.self, Track.self, configurations: config)
                containerCache[email] = container
                return container
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }

    /// Remove stored data for a specific account
    static func removeStore(for email: String) {
        let storageId = AccountManager.storageIdentifier(for: email)
        let storeURL = URL.applicationSupportDirectory.appending(path: "\(storageId).store")
        containerCache.removeValue(forKey: email)
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
    }
}

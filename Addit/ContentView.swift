import SwiftUI

struct ContentView: View {
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @State private var showNowPlaying = false

    var body: some View {
        Group {
            if authService.isRestoringSession || authService.isSwitchingAccount {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("addit")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authService.isSignedIn {
                ZStack(alignment: .bottom) {
                    NavigationStack {
                        LibraryView()
                    }

                    if playerService.currentTrack != nil && !playerService.hideNowPlayingBar {
                        NowPlayingBar(showFullPlayer: $showNowPlaying)
                    }
                }
                .sheet(isPresented: $showNowPlaying) {
                    NowPlayingView()
                }
            } else {
                SignInView()
            }
        }
        .tint(themeService.accentColor)
        .preferredColorScheme(themeService.appearanceMode.colorScheme)
        .alert("Unable to play this audio format", isPresented: .init(
            get: { playerService.failedTrack != nil },
            set: { if !$0 { playerService.failedTrack = nil } }
        )) {
            Button("OK", role: .cancel) {
                playerService.failedTrack = nil
            }
        } message: {
            Text("This file uses an audio format that Addit doesn't support.")
        }
    }
}

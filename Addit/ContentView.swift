import SwiftUI

struct ContentView: View {
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Environment(ThemeService.self) private var themeService
    @State private var showNowPlaying = false

    var body: some View {
        Group {
            if authService.isRestoringSession {
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

                    if playerService.currentTrack != nil {
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
    }
}

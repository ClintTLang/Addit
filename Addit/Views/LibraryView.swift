import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GoogleAuthService.self) private var authService
    @Environment(AudioPlayerService.self) private var playerService
    @Query(sort: \Album.dateAdded, order: .reverse) private var albums: [Album]
    @State private var showAddAlbum = false
    @State private var showSettings = false
    @State private var selectedAlbum: Album?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ZStack {
            ScrollView {
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums Yet",
                        systemImage: "music.note.list",
                        description: Text("Tap + to add folders from Google Drive")
                    )
                    .padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            Button {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                    selectedAlbum = album
                                }
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from Library", role: .destructive) {
                                    modelContext.delete(album)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }

            if let selectedAlbum {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                            self.selectedAlbum = nil
                        }
                    }
                    .transition(.opacity)

                FloatingAlbumPanel(album: selectedAlbum) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        self.selectedAlbum = nil
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                    removal: .opacity
                ))
                .zIndex(1)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddAlbum = true } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    if let name = authService.userName {
                        Text(name)
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Text("Settings")
                    }
                    .tint(.secondary)
                    Button("Sign Out", role: .destructive) {
                        authService.signOut()
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showAddAlbum) {
            AddAlbumView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .safeAreaInset(edge: .bottom) {
            if playerService.currentTrack != nil {
                Color.clear.frame(height: 64)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: selectedAlbum != nil)
    }
}

struct FloatingAlbumPanel: View {
    let album: Album
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            NavigationStack {
                AlbumDetailView(album: album, embeddedInPanel: true)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close")
                        }
                    }
            }
            .frame(
                width: min(700, proxy.size.width - 24),
                height: min(760, proxy.size.height * 0.86)
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.8))
                }

            Text(album.name)
                .font(.subheadline.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            if let artistName = album.artistName {
                Text(artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

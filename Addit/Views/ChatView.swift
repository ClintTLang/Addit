import SwiftUI

struct ChatView: View {
    let album: Album
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(GoogleAuthService.self) private var authService
    @Environment(ThemeService.self) private var themeService
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [DriveComment] = []
    @State private var messageText = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var error: String?
    @State private var nextPageToken: String?
    @State private var hasLoadedAll = false

    private var chatFileId: String? {
        album.additDataFileId
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading && messages.isEmpty {
                    Spacer()
                    ProgressView("Loading messages...")
                    Spacer()
                } else if let error {
                    Spacer()
                    ContentUnavailableView {
                        Label("Couldn't Load Chat", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            self.error = nil
                            Task { await loadMessages() }
                        }
                    }
                    Spacer()
                } else {
                    messageList
                }

                Divider()
                composerBar
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await loadMessages()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !hasLoadedAll && !messages.isEmpty {
                        Button("Load earlier messages") {
                            Task { await loadMoreMessages() }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    }

                    ForEach(sortedMessages) { message in
                        let isMe = message.author.me
                        ChatBubble(message: message, isMe: isMe, accentColor: themeService.accentColor)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) {
                if let last = sortedMessages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = sortedMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var sortedMessages: [DriveComment] {
        messages.sorted { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
    }

    // MARK: - Composer

    private var composerBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                Task { await sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : themeService.accentColor)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Data

    private func loadMessages() async {
        guard let fileId = chatFileId else {
            error = "Chat is not available for this album yet. Open the album to sync first."
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await driveService.listComments(fileId: fileId, pageSize: 100)
            messages = response.comments
            nextPageToken = response.nextPageToken
            hasLoadedAll = response.nextPageToken == nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMoreMessages() async {
        guard let fileId = chatFileId, let token = nextPageToken else { return }
        do {
            let response = try await driveService.listComments(fileId: fileId, pageToken: token, pageSize: 100)
            messages.insert(contentsOf: response.comments, at: 0)
            nextPageToken = response.nextPageToken
            hasLoadedAll = response.nextPageToken == nil
        } catch {
            // Silently fail on pagination
        }
    }

    private func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let fileId = chatFileId else { return }

        messageText = ""
        isSending = true
        defer { isSending = false }

        do {
            let comment = try await driveService.createComment(fileId: fileId, content: text)
            messages.append(comment)
        } catch {
            // Restore the message on failure so user doesn't lose it
            messageText = text
        }
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: DriveComment
    let isMe: Bool
    let accentColor: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 48) }

            if !isMe {
                authorAvatar
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if !isMe {
                    Text(message.author.displayName)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }

                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? accentColor : Color(.systemGray5),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(isMe ? .white : .primary)

                if let date = message.createdDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !isMe { Spacer(minLength: 48) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var authorAvatar: some View {
        if let photoLink = message.author.photoLink, let url = URL(string: photoLink) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                initialsAvatar
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            initialsAvatar
        }
    }

    private var initialsAvatar: some View {
        Circle()
            .fill(Color(.systemGray4))
            .frame(width: 28, height: 28)
            .overlay {
                Text(String(message.author.displayName.prefix(1)).uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
    }
}

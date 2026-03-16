import SwiftUI

struct ChatView: View {
    let album: Album
    @Environment(GoogleDriveService.self) private var driveService
    @Environment(GoogleAuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [DriveComment] = []
    @State private var messageText = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var error: String?
    @State private var nextPageToken: String?
    @State private var hasLoadedAll = false
    @State private var timestampDragOffset: CGFloat = 0
    @State private var timestampGeneration = 0
    @State private var members: [DrivePermission] = []
    @State private var showSharingSheet = false

    private var chatFileId: String? {
        album.additDataFileId
    }

    private var showTimestamps: Bool {
        timestampDragOffset < -10
    }

    var body: some View {
        ZStack {
            if isLoading && messages.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Loading messages...")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error {
                VStack {
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
                }
            } else {
                messageList
            }

            // Fade from status bar black into content
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                Spacer()
            }
            .allowsHitTesting(false)

            VStack {
                HStack(alignment: .center) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .padding(10)
                            .glassEffect(.regular, in: Circle())
                    }

                    Spacer()

                    Button {
                        showSharingSheet = true
                    } label: {
                        chatHeader
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Balance the back button width
                    Color.clear
                        .frame(width: 38, height: 38)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)

                Spacer()

                composerBar
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showSharingSheet) {
            SharingSheet(album: album)
                .environment(driveService)
                .environment(authService)
        }
        .task {
            async let msgs: () = loadMessages()
            async let mbrs: () = loadMembers()
            _ = await (msgs, mbrs)
        }
    }

    // MARK: - Chat Header

    private var userMembers: [DrivePermission] {
        members.filter { $0.type == "user" }
    }

    private var chatHeader: some View {
        VStack(spacing: 2) {
            if !userMembers.isEmpty {
                HStack(spacing: -6) {
                    ForEach(userMembers.prefix(3)) { member in
                        memberAvatar(member)
                    }
                    if userMembers.count > 3 {
                        Text("and \(userMembers.count - 3) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                    }
                }
            }
            Text(album.name)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder
    private func memberAvatar(_ member: DrivePermission) -> some View {
        if let photoLink = member.photoLink,
           let url = URL(string: photoLink.hasPrefix("//") ? "https:\(photoLink)" : photoLink) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                memberInitials(member)
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5))
        } else {
            memberInitials(member)
        }
    }

    private func memberInitials(_ member: DrivePermission) -> some View {
        Circle()
            .fill(Color(.systemGray4))
            .frame(width: 24, height: 24)
            .overlay {
                Text(String((member.displayName ?? member.emailAddress ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5))
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

                    let sorted = sortedMessages
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, message in
                        let isMe = message.author.me
                        let previousAuthor = index > 0 ? sorted[index - 1].author.displayName : nil
                        let nextAuthor = index < sorted.count - 1 ? sorted[index + 1].author.displayName : nil
                        let showName = !isMe && message.author.displayName != previousAuthor
                        let showAvatar = !isMe && message.author.displayName != nextAuthor
                        ChatBubble(message: message, isMe: isMe, showName: showName, showAvatar: showAvatar, showTimestamp: showTimestamps)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 70)
                .padding(.bottom, 60)
                .offset(x: timestampDragOffset)
            }
            .clipped()
            .ignoresSafeArea(.keyboard)
            .scrollDismissesKeyboard(.interactively)
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onChanged { value in
                        let horizontal = value.translation.width
                        // Only activate on predominantly horizontal left swipes
                        guard horizontal < 0,
                              abs(horizontal) > abs(value.translation.height) else { return }
                        withAnimation(.interactiveSpring) {
                            timestampDragOffset = max(horizontal, -70)
                        }
                    }
                    .onEnded { _ in
                        timestampGeneration += 1
                        let gen = timestampGeneration
                        withAnimation(.spring(duration: 0.3)) {
                            timestampDragOffset = 0
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(0.3))
                            if timestampGeneration == gen {
                                withAnimation(.easeIn(duration: 0.2)) {
                                    timestampDragOffset = 0
                                }
                            }
                        }
                    }
            )
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

    private var hasText: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerBar: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)

            if hasText {
                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .disabled(isSending)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: hasText)
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

    private func loadMembers() async {
        do {
            members = try await driveService.listPermissions(fileId: album.googleFolderId)
        } catch {
            // Non-critical — header just won't show avatars
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
    let showName: Bool
    let showAvatar: Bool
    let showTimestamp: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 48) }

            if !isMe {
                if showAvatar {
                    authorAvatar
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if showName {
                    Text(message.author.displayName)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? Color(.systemBlue) : Color(.systemGray5),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(isMe ? .white : .primary)
            }

            if !isMe { Spacer(minLength: 48) }
        }
        .overlay(alignment: .trailing) {
            if let date = message.createdDate {
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .opacity(showTimestamp ? 1 : 0)
                    // Position just past the right edge of the bubble row
                    .offset(x: 55)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var authorAvatar: some View {
        if let photoLink = message.author.photoLink,
           let url = URL(string: photoLink.hasPrefix("//") ? "https:\(photoLink)" : photoLink) {
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

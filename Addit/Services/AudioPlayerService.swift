import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

enum RepeatMode {
    case off, all, one
}

@Observable
final class AudioPlayerService {
    var cacheService: AudioCacheService?
    var albumArtService: AlbumArtService?

    var queue: [Track] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffleOn: Bool = false
    var repeatMode: RepeatMode = .off
    var isLoading: Bool = false
    var isSeeking: Bool = false
    var hideNowPlayingBar: Bool = false
    var userQueue: [Track] = []

    var currentTrack: Track? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Exposed for AudioAnalyzerService to install taps
    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()
    @ObservationIgnored private var currentAudioFile: AVAudioFile?
    @ObservationIgnored private var seekFrameOffset: AVAudioFramePosition = 0
    @ObservationIgnored private var timeTimer: Timer?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// Incremented each time we load or seek; the completion handler checks this to ignore stale callbacks
    @ObservationIgnored private var scheduleGeneration: UInt64 = 0
    @ObservationIgnored private var isLoadingTrack = false

    init() {
        configureAudioSession()
        setupEngine()
        setupRemoteCommands()
    }

    // MARK: - Playback Controls

    func playAlbum(_ album: Album, startingAt index: Int = 0, shuffled: Bool = false) {
        userQueue.removeAll()
        let sorted = album.tracks.sorted { $0.trackNumber < $1.trackNumber }
        originalQueue = sorted

        if shuffled {
            var shuffledTracks = sorted
            if !shuffledTracks.isEmpty && index < shuffledTracks.count {
                let startTrack = shuffledTracks.remove(at: index)
                shuffledTracks.shuffle()
                shuffledTracks.insert(startTrack, at: 0)
            }
            queue = shuffledTracks
            currentIndex = 0
            isShuffleOn = true
        } else {
            queue = sorted
            currentIndex = index
            isShuffleOn = false
        }

        Task { await loadAndPlay() }
    }

    func playTrack(_ track: Track, inQueue tracks: [Track]) {
        userQueue.removeAll()
        originalQueue = tracks
        queue = tracks
        currentIndex = tracks.firstIndex(where: { $0.googleFileId == track.googleFileId }) ?? 0
        if isShuffleOn {
            applyShuffle()
        }
        Task { await loadAndPlay() }
    }

    func play() {
        do {
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
            isPlaying = true
            startTimeTracking()
            updateNowPlayingPlaybackInfo()
        } catch {
            print("Engine start error: \(error.localizedDescription)")
        }
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        stopTimeTracking()
        updateNowPlayingPlaybackInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !queue.isEmpty else { return }

        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        // Play from user queue first
        if !userQueue.isEmpty {
            let nextTrack = userQueue.removeFirst()
            queue.insert(nextTrack, at: currentIndex + 1)
            currentIndex += 1
            Task { await loadAndPlay() }
            return
        }

        if currentIndex < queue.count - 1 {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            pause()
            return
        }
        Task { await loadAndPlay() }
    }

    func previous() {
        guard !queue.isEmpty else { return }

        if currentTime > 3.0 {
            seek(to: 0)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        Task { await loadAndPlay() }
    }

    func seek(to time: TimeInterval) {
        guard let audioFile = currentAudioFile else { return }
        currentTime = time
        let sampleRate = audioFile.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = audioFile.length

        guard targetFrame < totalFrames else { return }

        // Invalidate any pending completion
        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        let wasPlaying = isPlaying
        playerNode.stop()

        seekFrameOffset = targetFrame
        let remainingFrames = AVAudioFrameCount(totalFrames - targetFrame)

        playerNode.scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: remainingFrames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.completionFired(generation: gen)
        }

        if wasPlaying {
            playerNode.play()
        }
        updateNowPlayingPlaybackInfo()
    }

    func beginSeeking() {
        isSeeking = true
    }

    func endSeeking(to time: TimeInterval) {
        seek(to: time)
        isSeeking = false
    }

    func toggleShuffle() {
        isShuffleOn.toggle()
        if isShuffleOn {
            applyShuffle()
        } else {
            let current = currentTrack
            queue = originalQueue
            if let current {
                currentIndex = queue.firstIndex(where: { $0.googleFileId == current.googleFileId }) ?? 0
            }
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Queue Management

    func addToQueue(_ track: Track) {
        userQueue.append(track)
    }

    func removeFromUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        userQueue.remove(at: index)
    }

    func moveUserQueueTrack(from source: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.prepare()
    }

    // MARK: - Private

    private func completionFired(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.scheduleGeneration, !self.isLoadingTrack else { return }
            self.handleTrackEnd()
        }
    }

    private func loadAndPlay() async {
        guard let track = currentTrack, let cacheService else { return }

        isLoadingTrack = true
        isLoading = true

        // Invalidate any pending completion from previous track
        scheduleGeneration &+= 1
        let gen = scheduleGeneration

        playerNode.stop()

        do {
            let fileURL = try await cacheService.cacheTrack(track)
            let audioFile = try AVAudioFile(forReading: fileURL)

            currentAudioFile = audioFile
            seekFrameOffset = 0

            // Reconnect with the file's format
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            currentTime = 0

            playerNode.scheduleSegment(audioFile, startingFrame: 0, frameCount: AVAudioFrameCount(audioFile.length), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.completionFired(generation: gen)
            }

            isLoading = false
            isLoadingTrack = false
            play()
            updateNowPlayingInfo()
            prefetchUpcoming()
        } catch {
            isLoading = false
            isLoadingTrack = false
            print("Failed to load track: \(error.localizedDescription)")
        }
    }

    private func prefetchUpcoming() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            guard let cacheService else { return }

            var tracksToPrefetch: [Track] = Array(userQueue.prefix(2))
            if tracksToPrefetch.count < 2 {
                let remaining = 2 - tracksToPrefetch.count
                let indices = upcomingIndices(count: remaining)
                tracksToPrefetch.append(contentsOf: indices.map { queue[$0] })
            }

            for track in tracksToPrefetch {
                guard !Task.isCancelled else { return }
                do {
                    _ = try await cacheService.cacheTrack(track)
                } catch {}
            }
        }
    }

    private func upcomingIndices(count: Int) -> [Int] {
        guard !queue.isEmpty else { return [] }
        var indices: [Int] = []
        for offset in 1...count {
            let next = currentIndex + offset
            if next < queue.count {
                indices.append(next)
            } else if repeatMode == .all {
                indices.append(next % queue.count)
            }
        }
        return indices
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error.localizedDescription)")
        }
    }

    // MARK: - Time Tracking

    private func startTimeTracking() {
        stopTimeTracking()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
        }
    }

    private func stopTimeTracking() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func updateCurrentTime() {
        guard !isSeeking,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let audioFile = currentAudioFile else { return }

        let sampleRate = audioFile.processingFormat.sampleRate
        let elapsedFrames = playerTime.sampleTime
        let time = Double(seekFrameOffset + elapsedFrames) / sampleRate
        if time >= 0 && time <= duration {
            currentTime = time
        }
    }

    private func handleTrackEnd() {
        if repeatMode == .one {
            seek(to: 0)
            play()
        } else {
            next()
        }
    }

    private func applyShuffle() {
        let current = currentTrack
        var remaining = queue
        if let idx = remaining.firstIndex(where: { $0.googleFileId == current?.googleFileId }) {
            remaining.remove(at: idx)
        }
        remaining.shuffle()
        if let current {
            remaining.insert(current, at: 0)
        }
        queue = remaining
        currentIndex = 0
    }

    // MARK: - Now Playing Info Center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.displayName ?? ""
        info[MPMediaItemPropertyArtist] = currentTrack?.album?.artistName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentTrack?.album?.name ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let coverFileId = currentTrack?.album?.coverFileId, let albumArtService {
            Task {
                if let image = await albumArtService.image(for: coverFileId) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updatedInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                }
            }
        }
    }

    private func updateNowPlayingPlaybackInfo() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

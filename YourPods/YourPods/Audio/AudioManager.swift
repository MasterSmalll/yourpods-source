import Foundation
import AVFoundation
import MediaPlayer
#if canImport(AppKit)
import AppKit
#endif
import os
import Combine

/// Central audio engine wrapping AVQueuePlayer for gapless background podcast playback.
/// Replaces Flutter's audio_handler.dart with native iOS APIs.
///
/// Queue model:
///   - `currentItem` = the episode playing right now (or paused)
///   - `queue` = ordered list of **upcoming** episodes (does NOT include currentItem)
///   - When currentItem finishes, the first item in `queue` is popped and becomes currentItem
@Observable
final class AudioManager {
    // MARK: - Public State
    
    var isPlaying: Bool = false
    var currentItem: QueueItem?
    var currentPosition: TimeInterval = 0
    var currentDuration: TimeInterval = 0
    var isBuffering: Bool = false
    var playbackRate: Float = 1.0
    var errorMessage: String?
    
    /// Canonical playback rates shared across CarPlay, phone UI, and remote commands.
    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    
    /// Upcoming episodes — does NOT include the currently playing item.
    /// Reorder this list to change what plays next.
    private(set) var queue: [QueueItem] = [] {
        didSet {
            if !isRestoringQueue { persistQueue() }
            onQueueChanged?()
        }
    }
    
    // MARK: - Private
    
    private let logger = Logger(subsystem: "com.yourpods", category: "AudioManager")
    private let player = AVQueuePlayer()
    private let urlResolver = URLResolver()
    
    private var timeObserver: Any?
    private var itemObservers: [NSKeyValueObservation] = []
    private var cancellables = Set<AnyCancellable>()
    
    // Recovery state
    private var recoveryAttempts = 0
    private var isRecovering = false
    private static let maxRecoveryAttempts = 5
    
    // Auto-advance guard
    private var isAdvancingQueue = false
    
    // Interruption handling (Siri, phone calls, etc.)
    private(set) var wasPlayingBeforeInterruption = false
    
    // Guard: prevent persistQueue() during restoreQueue()
    private var isRestoringQueue = false
    
    // Prevents false completion when swapping episodes
    private var isLoadingNewEpisode = false
    
    // Skip intro/outro
    var skipIntroSeconds: Int = 0
    var skipOutroSeconds: Int = 0
    
    /// When enabled, uses time-domain pitch algorithm for better quality
    /// and applies a minor speed boost during low-volume segments.
    var skipSilenceEnabled: Bool = false {
        didSet {
            player.currentItem?.audioTimePitchAlgorithm = skipSilenceEnabled
                ? .timeDomain
                : .spectral
            onSkipSilenceChanged?(skipSilenceEnabled)
        }
    }
    
    // Callback for when media item changes (used by PlayerManager for sync)
    var onItemChanged: ((QueueItem?) -> Void)?
    
    // Callback for when an episode completes
    var onEpisodeCompleted: ((QueueItem) -> Void)?
    
    // Callback for when the queue changes (used by CarPlay to refresh)
    var onQueueChanged: (() -> Void)?
    
    // Callback for when playback rate changes (used by CarPlay to refresh buttons)
    var onPlaybackRateChanged: ((Float) -> Void)?
    
    // Callback for when skip-silence is toggled (used by CarPlay to refresh buttons)
    var onSkipSilenceChanged: ((Bool) -> Void)?
    
    // MARK: - Persistence Keys
    
    private static let queueKey = "savedQueue"
    private static let currentItemKey = "savedCurrentItem"
    private static let currentPositionKey = "savedCurrentPosition"
    
    // MARK: - Init
    
    init() {
        setupAudioSession()
        setupRemoteCommands()
        setupPlayerObservers()
    }
    
    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        itemObservers.forEach { $0.invalidate() }
    }
    
    // MARK: - Audio Session
    
    private func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
            logger.info("Audio session configured for spoken audio playback")
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
        #endif
    }
    
    // MARK: - Remote Commands (Lock Screen, CarPlay, AirPods)
    
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.seekRelative(seconds: event.interval)
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.seekRelative(seconds: -event.interval)
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipToNext()
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipToPrevious()
            return .success
        }
        
        // Playback rate (CarPlay, external accessories)
        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = Self.availableRates.map { NSNumber(value: $0) }
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self.setPlaybackRate(event.playbackRate)
            return .success
        }
    }
    
    // MARK: - Player Observers
    
    private func setupPlayerObservers() {
        // Periodic time observer (every 0.5s)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentPosition = time.seconds
            self.updateNowPlayingProgress()
            
            // Skip outro detection
            if self.skipOutroSeconds > 0,
               self.currentDuration > 0,
               time.seconds >= self.currentDuration - Double(self.skipOutroSeconds) {
                self.logger.info("Skip outro triggered at \(time.seconds)s")
                self.skipToNext()
            }
        }
        
        // Observe current item changes
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.handleCurrentItemChanged(item)
            }
            .store(in: &cancellables)
        
        // Observe rate (playing/paused)
        player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.isPlaying = rate > 0
                self?.updateNowPlayingPlaybackState()
            }
            .store(in: &cancellables)
        
        // Observe when the player reaches the end of its queue
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      !self.isAdvancingQueue,
                      !self.isLoadingNewEpisode,
                      let playerItem = notification.object as? AVPlayerItem,
                      playerItem == self.player.currentItem else { return }
                self.handlePlaybackCompleted()
            }
            .store(in: &cancellables)
        
        // Observe audio session interruptions (Siri, phone calls, alarms)
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &cancellables)
        #endif
        
        // Observe playback errors
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self?.handlePlaybackError(error)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Playback Controls
    
    func play() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.warning("Failed to activate audio session: \(error.localizedDescription)")
        }
        #endif
        
        // Cold-start bootstrap: AVPlayer has no item loaded but we have a restored currentItem.
        // Load and play the episode from the saved position.
        if player.currentItem == nil, let restoredItem = currentItem {
            logger.info("Cold-start play: bootstrapping from restored item at \(self.currentPosition)s")
            Task { await self.playEpisode(restoredItem, initialPosition: self.currentPosition) }
            return
        }
        
        player.rate = playbackRate
        isPlaying = true
    }
    
    func pause() {
        player.pause()
        isPlaying = false
    }
    
    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }
    
    /// Resume the last-playing episode, loading it into AVPlayer if needed.
    /// Handles the cold-start case where restoreQueue() only restored metadata.
    func resumePlayback() async {
        if player.currentItem != nil {
            // Player already has content loaded — just resume
            play()
            return
        }
        
        // Cold start: currentItem was restored from UserDefaults but not loaded into AVPlayer
        guard let item = currentItem else {
            // Nothing to resume — try playing the first item in the queue
            if !queue.isEmpty {
                let first = queue.removeFirst()
                logger.info("resumePlayback: no current item, starting first queued: \(first.title)")
                await playEpisode(first)
            } else {
                logger.info("resumePlayback: nothing to resume — queue is empty")
            }
            return
        }
        
        let pos = UserDefaults.standard.double(forKey: Self.currentPositionKey)
        logger.info("resumePlayback: cold-starting '\(item.title)' at \(pos)s")
        await playEpisode(item, initialPosition: pos > 0 ? pos : nil)
    }
    
    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlayingProgress()
        }
    }
    
    func seekRelative(seconds: TimeInterval) {
        let newPosition = currentPosition + seconds
        seek(to: min(max(0, newPosition), currentDuration))
    }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
        updateNowPlayingPlaybackState()
        onPlaybackRateChanged?(rate)
    }
    
    func stop() {
        player.pause()
        player.removeAllItems()
        isPlaying = false
        currentItem = nil
        currentPosition = 0
        currentDuration = 0
        clearNowPlayingInfo()
        persistQueue()
    }
    
    // MARK: - Queue Management
    
    /// Play a specific episode, resolving its URL through the redirect chain.
    func playEpisode(_ item: QueueItem, initialPosition: TimeInterval? = nil, preserveCurrent: Bool = false) async {
        logger.info("Playing episode: \(item.title)")
        isBuffering = true
        errorMessage = nil
        
        // Preserve the currently playing item by moving it to the top of Up Next
        if preserveCurrent, let previous = currentItem, previous.id != item.id {
            logger.info("Preserving current item in queue: \(previous.title)")
            queue.insert(previous, at: 0)
        }
        
        // Resolve tracking redirects to the final CDN URL
        let resolvedUrl = await urlResolver.resolveUrl(item.audioUrl, headers: item.authHeaders)
        
        guard let url = URL(string: resolvedUrl) else {
            errorMessage = "Invalid audio URL"
            isBuffering = false
            return
        }
        
        // Create the AVPlayerItem with auth headers if needed
        let asset = AVURLAsset(url: url, options: item.authHeaders != nil ? [
            "AVURLAssetHTTPHeaderFieldsKey": item.authHeaders!
        ] : nil)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Set up item-level observers
        observePlayerItem(playerItem)
        
        isLoadingNewEpisode = true
        
        // Replace current queue with this item
        player.removeAllItems()
        player.insert(playerItem, after: nil)
        
        // Update state
        currentItem = item
        currentDuration = 0  // Reset — will be set by duration observer for new item
        recoveryAttempts = 0
        
        // Remove from upcoming queue if present (it's now the current item)
        queue.removeAll { $0.id == item.id }
        
        // Seek to initial position if provided
        if let pos = initialPosition, pos > 0 {
            let time = CMTime(seconds: pos, preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        
        // Skip intro if configured
        if skipIntroSeconds > 0, (initialPosition ?? 0) < Double(skipIntroSeconds) {
            let introTime = CMTime(seconds: Double(skipIntroSeconds), preferredTimescale: 600)
            await player.seek(to: introTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        
        // Begin playback
        play()
        isLoadingNewEpisode = false
        updateNowPlayingInfo(for: item)
        onItemChanged?(item)
        persistQueue()
    }
    
    /// Replace the entire upcoming queue.
    func loadQueue(_ items: [QueueItem], startPlaying: Bool = false, initialPosition: TimeInterval? = nil) async {
        queue = items
        
        if startPlaying, let first = queue.first {
            // Pop first from queue and play it
            await playEpisode(first, initialPosition: initialPosition)
        }
    }
    
    /// Add items to the end of the upcoming queue.
    func appendToQueue(_ items: [QueueItem]) {
        // Don't add duplicates
        let existingIds = Set(queue.map(\.id) + [currentItem?.id].compactMap { $0 })
        let newItems = items.filter { !existingIds.contains($0.id) }
        queue.append(contentsOf: newItems)
    }
    
    /// Insert items at the top of the upcoming queue (play next).
    func insertNext(_ items: [QueueItem]) {
        let existingIds = Set(queue.map(\.id) + [currentItem?.id].compactMap { $0 })
        let newItems = items.filter { !existingIds.contains($0.id) }
        queue.insert(contentsOf: newItems, at: 0)
    }
    
    /// Remove an item from the upcoming queue.
    func removeFromQueue(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }
    
    /// Reorder upcoming queue items (indices are relative to the queue array).
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    /// Skip to the next item in the upcoming queue.
    func skipToNext() {
        guard !queue.isEmpty else {
            logger.info("No next item in queue")
            stop()
            return
        }
        
        let next = queue.removeFirst()
        logger.info("Skipping to next: \(next.title)")
        Task { await playEpisode(next, preserveCurrent: true) }
    }
    
    /// Restart current episode (or no-op if nothing playing).
    func skipToPrevious() {
        if currentPosition > 3 {
            seek(to: 0)
        }
    }
    
    // MARK: - Playback Completion & Auto-Advance
    
    private func handlePlaybackCompleted() {
        guard !isAdvancingQueue, !isLoadingNewEpisode else { return }
        
        // Guard: spurious "end of track" — if we're nowhere near the actual end,
        // this is a stream failure disguised as completion (common in Simulator).
        // Treat it as an error and attempt recovery instead of advancing.
        if self.currentDuration > 30, (self.currentDuration - self.currentPosition) > 10 {
            self.logger.warning("Spurious completion at \(self.currentPosition)s / \(self.currentDuration)s — attempting recovery instead")
            self.handlePlaybackError(NSError(domain: "AudioManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Playback ended unexpectedly at \(Int(self.currentPosition))s of \(Int(self.currentDuration))s"
            ]))
            return
        }
        
        isAdvancingQueue = true
        
        guard let completed = currentItem else {
            isAdvancingQueue = false
            stop()
            return
        }
        
        logger.info("Episode completed: \(completed.title)")
        onEpisodeCompleted?(completed)
        
        // Pop the next item from the upcoming queue
        guard !queue.isEmpty else {
            logger.info("Queue finished — no more items")
            isAdvancingQueue = false
            stop()
            return
        }
        
        let next = queue.removeFirst()
        logger.info("Auto-advancing to: \(next.title)")
        
        Task {
            // Re-activate audio session (iOS may have deactivated it)
            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                logger.warning("Failed to re-activate audio session: \(error.localizedDescription)")
            }
            #endif
            
            await playEpisode(next)
            isAdvancingQueue = false
        }
    }
    
    // MARK: - Error Handling & Stream Recovery
    
    private func handlePlaybackError(_ error: Error) {
        logger.error("Playback error: \(error.localizedDescription)")
        
        guard !isRecovering, recoveryAttempts < Self.maxRecoveryAttempts else {
            logger.error("Recovery exhausted after \(self.recoveryAttempts) attempts")
            errorMessage = "Playback failed. Check your connection."
            player.pause()
            return
        }
        
        attemptStreamRecovery()
    }
    
    private func attemptStreamRecovery() {
        guard let item = currentItem else { return }
        
        isRecovering = true
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let position = currentPosition
        
        let backoff = min(pow(2.0, Double(attempt - 1)), 30.0)
        logger.info("Stream recovery attempt \(attempt)/\(Self.maxRecoveryAttempts) in \(backoff)s")
        
        Task {
            try? await Task.sleep(for: .seconds(backoff))
            
            // Invalidate cached URL to get a fresh CDN token
            await urlResolver.invalidate(item.audioUrl)
            
            await playEpisode(item, initialPosition: position)
            isRecovering = false
        }
    }
    
    // MARK: - AVPlayerItem Observers
    
    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        // Clear previous observers
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        
        // Observe buffer state
        let bufferObserver = playerItem.observe(\.isPlaybackBufferEmpty) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.isBuffering = item.isPlaybackBufferEmpty
            }
        }
        itemObservers.append(bufferObserver)
        
        let likelyObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.isPlaybackLikelyToKeepUp {
                    self?.isBuffering = false
                }
            }
        }
        itemObservers.append(likelyObserver)
        
        // Observe duration
        let durationObserver = playerItem.observe(\.duration) { [weak self] item, _ in
            guard item.duration != .indefinite else { return }
            DispatchQueue.main.async {
                self?.currentDuration = item.duration.seconds
            }
        }
        itemObservers.append(durationObserver)
        
        // Observe status for errors
        let statusObserver = playerItem.observe(\.status) { [weak self] item, _ in
            if item.status == .failed, let error = item.error {
                self?.handlePlaybackError(error)
            }
        }
        itemObservers.append(statusObserver)
    }
    
    // MARK: - Current Item Change
    
    private func handleCurrentItemChanged(_ item: AVPlayerItem?) {
        if item == nil && isPlaying && !isLoadingNewEpisode {
            // Player ran out of items (not a mid-swap transition)
            handlePlaybackCompleted()
        }
    }
    
    // MARK: - Queue Persistence
    
    /// Save queue + current item to UserDefaults.
    private func persistQueue() {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        
        if let data = try? encoder.encode(queue) {
            defaults.set(data, forKey: Self.queueKey)
        }
        // Sync positionSeconds from the live currentPosition before encoding.
        // Only update the copy for encoding — do NOT write back to `currentItem`
        // as that would trigger didSet and cause a recursive persist cycle.
        if var item = currentItem {
            item.positionSeconds = Int(currentPosition)
            if let data = try? encoder.encode(item) {
                defaults.set(data, forKey: Self.currentItemKey)
            }
        } else {
            defaults.removeObject(forKey: Self.currentItemKey)
        }
        defaults.set(currentPosition, forKey: Self.currentPositionKey)
    }
    
    /// Restore queue from UserDefaults (call on app launch).
    func restoreQueue() {
        isRestoringQueue = true
        defer { isRestoringQueue = false }
        
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        
        // Restore currentItem FIRST — if we set `queue` before restoring
        // currentItem, the didSet would trigger persistQueue() which would
        // see currentItem == nil and erase it from disk.
        if let data = defaults.data(forKey: Self.currentItemKey),
           let saved = try? decoder.decode(QueueItem.self, from: data) {
            currentItem = saved
            let pos = defaults.double(forKey: Self.currentPositionKey)
            currentPosition = pos
            if let dur = saved.durationSeconds { currentDuration = TimeInterval(dur) }
            logger.info("Restored current item: \(saved.title) at \(pos)s")
            // Note: we don't auto-play — just restore the state.
            // User taps play to resume.
            // Populate lock screen / CarPlay Now Playing info immediately so
            // artwork and title are visible before the user taps play.
            updateNowPlayingInfo(for: saved)
        }
        
        if let data = defaults.data(forKey: Self.queueKey),
           let saved = try? decoder.decode([QueueItem].self, from: data) {
            queue = saved
            logger.info("Restored queue: \(saved.count) items")
        }
    }
    
    /// Force-write queue state to disk. Call on background transitions.
    func persistQueueToDisk() {
        // Read the latest position from AVPlayer for maximum freshness
        let latestPosition = player.currentTime().seconds
        if latestPosition.isFinite && latestPosition > 0 {
            currentPosition = latestPosition
        }
        persistQueue()
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - Now Playing Info (Lock Screen / CarPlay)
    
    private func updateNowPlayingInfo(for item: QueueItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.podcastTitle,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Float(1.0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPosition,
            MPMediaItemPropertyPlaybackDuration: currentDuration,
        ]
        
        // Load artwork asynchronously
        if let artworkUrl = item.artworkUrl {
            Task {
                if let image = await loadImage(from: artworkUrl) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func updateNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
        info[MPMediaItemPropertyPlaybackDuration] = currentDuration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // MARK: - Image Loading (for Now Playing artwork)
    
    #if os(iOS)
    private func loadImage(from urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
    #else
    private func loadImage(from urlString: String) async -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
    #endif
    
    // MARK: - Testable Queue Logic
    
    /// Synchronous helper that mirrors the queue-manipulation portion of `playEpisode`.
    /// Used by unit tests to validate preserve/switch logic without AVPlayer side effects.
    func testablePreserveAndSwitch(to item: QueueItem, preserveCurrent: Bool) {
        if preserveCurrent, let previous = currentItem, previous.id != item.id {
            queue.insert(previous, at: 0)
        }
        currentItem = item
        queue.removeAll { $0.id == item.id }
    }
    
    /// Test helper: set position and duration without AVPlayer.
    func testableSetPlaybackState(position: TimeInterval, duration: TimeInterval) {
        currentPosition = position
        currentDuration = duration
    }
    
    /// Test helper: check whether the current state would be treated as a spurious completion.
    /// Mirrors the guard logic in `handlePlaybackCompleted()`.
    func testableIsSpuriousCompletion() -> Bool {
        return currentDuration > 30 && (currentDuration - currentPosition) > 10
    }
    
    /// Test helper: simulate an audio session interruption.
    /// - Parameters:
    ///   - began: true for interruption began, false for ended.
    ///   - shouldResume: when began is false, whether the system indicates playback should resume.
    /// - Returns: Whether playback would resume (only meaningful when began == false).
    @discardableResult
    func testableHandleInterruption(began: Bool, shouldResume: Bool = false) -> Bool {
        if began {
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                pause()
            }
            logger.info("Interruption began — wasPlaying: \(self.wasPlayingBeforeInterruption)")
            return false
        } else {
            let willResume = shouldResume && wasPlayingBeforeInterruption
            logger.info("Interruption ended — shouldResume: \(shouldResume), wasPlaying: \(self.wasPlayingBeforeInterruption), willResume: \(willResume)")
            if willResume {
                play()
            }
            wasPlayingBeforeInterruption = false
            return willResume
        }
    }
    
    // MARK: - Audio Session Interruption
    
    #if os(iOS)
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            logger.warning("Received interruption notification with missing/invalid type")
            return
        }
        
        switch type {
        case .began:
            testableHandleInterruption(began: true)
            
        case .ended:
            let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            
            // Small delay to let the audio session fully settle after Siri/phone call
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.testableHandleInterruption(began: false, shouldResume: shouldResume)
            }
            
        @unknown default:
            logger.warning("Unknown audio session interruption type: \(typeValue)")
        }
    }
    #endif
}

// MARK: - Queue Item

/// Lightweight value type representing an item in the playback queue.
/// Separate from the SwiftData Episode model to avoid threading issues with AVFoundation.
struct QueueItem: Identifiable, Equatable, Codable {
    let id: String          // Episode GUID
    let title: String
    let podcastTitle: String
    let audioUrl: String
    let artworkUrl: String?
    let durationSeconds: Int?
    var positionSeconds: Int = 0
    let podcastUrl: String
    let pubDate: Date?
    var chaptersUrl: String? = nil
    var transcriptUrl: String? = nil
    var episodeDescription: String? = nil
    
    /// Auth headers for protected feeds (not serialized)
    var authHeaders: [String: String]? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, title, podcastTitle, audioUrl, artworkUrl, durationSeconds, positionSeconds, podcastUrl, pubDate, chaptersUrl, transcriptUrl, episodeDescription
    }
    
    /// Convert from SwiftData Episode model
    static func from(episode: Episode, positionSeconds: Int = 0) -> QueueItem? {
        guard let audioUrl = episode.audioUrl else { return nil }
        return QueueItem(
            id: episode.guid,
            title: episode.title,
            podcastTitle: episode.podcastTitle ?? "",
            audioUrl: audioUrl,
            artworkUrl: episode.imageUrl ?? episode.podcast?.logoUrl,
            durationSeconds: episode.durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: episode.podcastUrl ?? "",
            pubDate: episode.pubDate,
            chaptersUrl: episode.chaptersUrl,
            transcriptUrl: episode.transcriptUrl,
            episodeDescription: episode.episodeDescription
        )
    }
}

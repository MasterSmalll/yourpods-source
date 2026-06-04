import Foundation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import os
import Combine

/// Central audio engine wrapping AVQueuePlayer for gapless background podcast playback.
/// AVAudioEngine-based playback engine with native iOS APIs.
///
/// Queue model:
///   - `currentItem` = the episode playing right now (or paused)
///   - `queue` = ordered list of **upcoming** episodes (does NOT include currentItem)
///   - When currentItem finishes, the first item in `queue` is popped and becomes currentItem
@Observable
@MainActor
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
            if !isRestoringQueue {
                queueDirty = true
                persistQueue()
            }
            onQueueChanged?()
            if !isSuppressingMembershipChange {
                onQueueMembershipChanged?()
            }
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
    /// Escalating backoff delays for stream recovery: 5s, 10s, 15s, 20s, 30s.
    /// Faster than exponential for early retries, with a 30s cap for persistent failures.
    static let recoveryBackoffSchedule: [TimeInterval] = [5, 10, 15, 20, 30]
    
    /// Network monitor for network-aware recovery decisions.
    /// When set, recovery skips retries when offline and auto-retries on connectivity restoration.
    /// Call `subscribeToConnectivityRestoration()` after setting this property.
    @ObservationIgnored var networkMonitor: (any NetworkMonitoring)?
    
    // Auto-advance guard
    var isAdvancingQueue = false
    
    /// True while a new episode is being loaded (URL resolution → seek → play)
    /// or while auto-advancing between episodes. External code (e.g., syncProgress)
    /// should avoid syncing progress during this window to prevent stale data leaks.
    var isInEpisodeTransition: Bool { isLoadingNewEpisode || isAdvancingQueue }
    
    // Interruption handling (Siri, phone calls, etc.)
    private(set) var wasPlayingBeforeInterruption = false
    
    // Guard: prevent persistQueue() during restoreQueue()
    private var isRestoringQueue = false
    
    /// Dirty flag: true when the queue has been mutated since the last persist.
    /// The 30-second persistence timer skips writes when this is false AND the
    /// player is idle, saving ~26 MB of disk writes over 22 hours.
    private var queueDirty = false
    
    // Timer for periodic progress persistence (safety net)
    private var persistenceTimer: Timer?
    
    // Prevents false completion when swapping episodes
    private var isLoadingNewEpisode = false
    
    // Skip intro/outro
    var skipIntroSeconds: Int = 0
    var skipOutroSeconds: Int = 0
    
    /// Callback to re-resolve per-podcast settings at play time.
    /// Returns (skipIntro, skipOutro, playbackSpeed, skipForward, skipBackward).
    /// Set by PlayerManager so AudioManager can query current settings
    /// without a direct SettingsManager dependency.
    /// STUB: not yet wired — tests should fail until Phase 2.
    @ObservationIgnored var settingsResolver: ((QueueItem) -> (skipIntro: Int, skipOutro: Int, speed: Float, skipForward: Int, skipBackward: Int))?
    
    // Remote command actions (AirPods double/triple-tap, lock screen controls)
    var nextTrackAction: RemoteCommandAction = .nextEpisode
    var previousTrackAction: RemoteCommandAction = .skipBack
    
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
    
    /// Callback for when queue membership or order changes (add/remove/reorder).
    /// Does NOT fire for position-only updates. Use this for server push triggers
    /// to avoid unnecessary network traffic during active playback.
    var onQueueMembershipChanged: (() -> Void)?
    
    // Callback for when playback rate changes (used by CarPlay to refresh buttons)
    var onPlaybackRateChanged: ((Float) -> Void)?
    
    // Callback for when skip-silence is toggled (used by CarPlay to refresh buttons)
    var onSkipSilenceChanged: ((Bool) -> Void)?
    
    /// Optional gate for auto-advance. Return false to stop playback
    /// instead of advancing to the next queued episode.
    /// Used by the sleep timer's "DriftOff Mode".
    var shouldAutoAdvanceToNextEpisode: (() -> Bool)?
    
    // MARK: - Persistence Keys
    
    private static let queueKey = "savedQueue"
    private static let currentItemKey = "savedCurrentItem"
    private static let currentPositionKey = "savedCurrentPosition"
    
    // MARK: - Init
    
    init() {
        setupAudioSession()
        setupRemoteCommands()
        setupPlayerObservers()
        startPersistenceTimer()
    }
    
    deinit {
        // deinit is nonisolated by Swift rules, but @MainActor class deinit
        // always runs on main. Use assumeIsolated to access stored properties.
        MainActor.assumeIsolated {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            itemObservers.forEach { $0.invalidate() }
            persistenceTimer?.invalidate()
        }
    }
    
    // MARK: - Audio Session
    
private let isRunningTests = NSClassFromString("XCTestCase") != nil

    private func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
            // Register as a remote-controllable media source so the system
            // recognizes our MPNowPlayingInfoCenter updates for CarPlay/lock screen
            // even before AVPlayer has a loaded item.
            if !isRunningTests {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
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
        
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: UserDefaults.standard.object(forKey: "skipForwardSeconds") as? Int ?? 30)]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.seekRelative(seconds: event.interval)
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: UserDefaults.standard.object(forKey: "skipBackwardSeconds") as? Int ?? 15)]
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
            self?.executeRemoteAction(self?.nextTrackAction ?? .nextEpisode)
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.executeRemoteAction(self?.previousTrackAction ?? .skipBack)
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
    
    /// Update the skip forward/backward intervals shown on Lock Screen, CarPlay, etc.
    /// Called when per-podcast settings change or when a new episode starts playing.
    func updateRemoteCommandIntervals(forward: Int, backward: Int) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
    }
    
    // MARK: - Player Observers
    
    private func setupPlayerObservers() {
        // Periodic time observer (every 0.5s)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentPosition = time.seconds
                self.updateNowPlayingProgress()
                
                // Skip outro detection — uses the resolver-updated instance variable.
                // QueueItem.skipOutroSeconds is Int (not Int?), so it defaults to 0
                // and the ?? fallback would never fire. The instance var is authoritative
                // because playEpisode() updates it from settingsResolver or QueueItem.
                // Guard: don't re-trigger if we're already advancing (prevents draining queue)
                let outroSeconds = self.skipOutroSeconds
                if outroSeconds > 0,
                   self.currentDuration > 0,
                   !self.isAdvancingQueue,
                   time.seconds >= self.currentDuration - Double(outroSeconds) {
                    self.logger.info("Skip outro triggered at \(time.seconds)s (skipOutro=\(outroSeconds)s)")
                    self.skipToNext()
                }
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
    
    // MARK: - Persistence Timer
    
    private func startPersistenceTimer() {
        persistenceTimer?.invalidate()
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.queueDirty || self.isPlaying else { return }
                self.persistQueue()
            }
        }
        // Fire during scrolling/tracking too — default mode pauses during UI interaction
        RunLoop.main.add(persistenceTimer!, forMode: .common)
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
            // Set Now Playing metadata SYNCHRONOUSLY before the async Task.
            // CPNowPlayingTemplate only renders metadata when the system recognizes
            // us as the "now playing" source. Without this, CarPlay pushes the template
            // before playEpisode runs and sees a blank music note.
            updateNowPlayingInfo(for: restoredItem)
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
            MainActor.assumeIsolated {
                self?.updateNowPlayingProgress()
            }
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
        // Guard: don't re-queue episodes that have been marked as played
        if preserveCurrent, let previous = currentItem, previous.id != item.id, !previous.isPlayed {
            logger.info("Preserving current item in queue: \(previous.title)")
            // Remove any existing instances first to prevent duplicates
            // (can occur from sync, restore, or rapid successive plays)
            queue.removeAll { $0.id == previous.id }
            queue.insert(previous, at: 0)
        }
        
        // ── Immediately populate Now Playing so CarPlay/lock screen shows
        // episode info while buffering, not a blank music note. ──
        currentItem = item
        updateNowPlayingInfo(for: item)
        
        // ── Resolve audio URL: prefer local download, fall back to remote streaming ──
        let playbackUrl: URL
        
        if let localFile = item.localFileUrl, FileManager.default.fileExists(atPath: localFile.path) {
            // Downloaded episode: play from disk (no network needed, instant start)
            logger.info("Using local download: \(localFile.lastPathComponent)")
            playbackUrl = localFile
        } else {
            // ── P3: Privacy Preserving Playback — strip tracking/DAI prefixes ──
            var streamUrl = item.audioUrl
            if item.privacyMode {
                let result = TrackingURLStripper.strip(item.audioUrl)
                if result.wasModified {
                    logger.info("P3: stripped [\(result.trackersRemoved.joined(separator: ", "))] → \(result.url)")
                }
                streamUrl = result.url
            }
            
            // When offline, skip URL resolution entirely (the HEAD request
            // would just timeout after 5s). Use the raw/stripped URL and let
            // AVPlayer's error handling trigger stream recovery.
            let resolvedUrl: String
            if let monitor = networkMonitor, !monitor.isConnected {
                resolvedUrl = streamUrl
                logger.info("Offline: skipping URL resolution, using raw URL")
            } else {
                resolvedUrl = await urlResolver.resolveUrl(streamUrl, headers: item.authHeaders)
            }
            guard let remoteUrl = URL(string: resolvedUrl) else {
                errorMessage = "Invalid audio URL"
                isBuffering = false
                return
            }
            playbackUrl = remoteUrl
        }
        
        // Create the AVPlayerItem with auth headers if needed (only for remote URLs)
        let isLocalFile = playbackUrl.isFileURL
        let asset = AVURLAsset(url: playbackUrl, options: (!isLocalFile && item.authHeaders != nil) ? [
            "AVURLAssetHTTPHeaderFieldsKey": item.authHeaders!
        ] : nil)
        let playerItem = AVPlayerItem(asset: asset)
        
        // For remote URLs, reduce the preferred buffer before playback starts.
        // The default can be very high on constrained networks, causing long stalls
        // before first audio. 10s is enough for spoken audio to begin playing.
        if !isLocalFile {
            playerItem.preferredForwardBufferDuration = 10
        }
        
        // Set up item-level observers
        observePlayerItem(playerItem)
        
        isLoadingNewEpisode = true
        
        // Replace current queue with this item
        player.removeAllItems()
        player.insert(playerItem, after: nil)
        
        // Update state (currentItem already set above for early metadata)
        currentDuration = 0  // Reset — will be set by duration observer for new item
        currentPosition = 0  // Reset — prevents stale position from leaking to sync
        recoveryAttempts = 0
        
        // Remove from upcoming queue if present (it's now the current item)
        queue.removeAll { $0.id == item.id }
        
        // Seek to initial position if provided, else fall back to the queue item's tracked position
        let targetPosition = initialPosition ?? Double(item.positionSeconds)
        if targetPosition > 0 {
            let time = CMTime(seconds: targetPosition, preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            currentPosition = targetPosition  // Reflect the seek immediately for sync accuracy
        }
        
        // ── Re-resolve per-podcast settings at play time ──
        // QueueItem values may be stale if settings changed after the episode
        // was queued, or if the item came from server sync / queue restore.
        // The resolver queries the current PodcastSettings + SettingsManager.
        if let resolver = settingsResolver {
            let resolved = resolver(item)
            skipIntroSeconds = resolved.skipIntro
            skipOutroSeconds = resolved.skipOutro
            playbackRate = resolved.speed
            updateRemoteCommandIntervals(forward: resolved.skipForward, backward: resolved.skipBackward)
        } else {
            // No resolver (e.g., unit tests, standalone AudioManager)
            // — fall back to QueueItem values as before
            skipIntroSeconds = item.skipIntroSeconds
            skipOutroSeconds = item.skipOutroSeconds
        }
        
        // Skip intro if configured — uses the now-updated instance var
        let effectiveSkipIntro = skipIntroSeconds
        if effectiveSkipIntro > 0, targetPosition < Double(effectiveSkipIntro) {
            let introTime = CMTime(seconds: Double(effectiveSkipIntro), preferredTimescale: 600)
            await player.seek(to: introTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentPosition = Double(effectiveSkipIntro)
        }
        
        // Apply per-episode playback speed unconditionally.
        // Must always set — even when 1.0 — so a slower podcast correctly
        // resets the rate after a faster one during auto-advance.
        // When resolver is present, playbackRate was already set above;
        // when absent, use the QueueItem value.
        if settingsResolver == nil {
            playbackRate = item.playbackSpeed
        }
        
        // Begin playback
        play()
        isLoadingNewEpisode = false
        // Refresh Now Playing with final position/duration after seek
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
    
    /// Replace the entire upcoming queue with the given items.
    /// Used by Pro sync pull to adopt the server's canonical queue state.
    func replaceQueue(_ items: [QueueItem]) {
        queue = items
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
    
    /// Remove all items from the upcoming queue. Does not affect the currently playing item.
    func clearQueue() {
        queue.removeAll()
    }
    
    /// Flag to suppress onQueueMembershipChanged during position-only updates.
    private var isSuppressingMembershipChange = false
    
    /// Update the position of a queue item by ID (used during sync merge).
    /// Does NOT fire onQueueMembershipChanged — position-only updates are not membership changes.
    func updateQueueItemPosition(id: String, positionSeconds: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        isSuppressingMembershipChange = true
        queue[index].positionSeconds = positionSeconds
        isSuppressingMembershipChange = false
    }
    
    /// Move an existing queue item to the top (play next).
    func moveToTop(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
        queue.insert(item, at: 0)
    }
    
    /// Reorder upcoming queue items (indices are relative to the queue array).
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    /// Skip to the next item in the upcoming queue.
    func skipToNext() {
        // Guard: prevent re-entry from periodic time observer firing
        // multiple times before async playEpisode completes
        guard !isAdvancingQueue else {
            logger.debug("skipToNext: already advancing, ignoring")
            return
        }
        guard !queue.isEmpty else {
            logger.info("No next item in queue")
            stop()
            return
        }
        
        isAdvancingQueue = true
        
        // Fire completion callback for the current item (skip-outro, manual skip)
        // so it gets marked as played and removed from the queue
        if let completed = currentItem {
            logger.notice("Skipping from: \(completed.title)")
            onEpisodeCompleted?(completed)
        }
        
        let next = queue.removeFirst()
        logger.notice("Skipping to next: \(next.title)")
        Task {
            // Request background execution time so iOS doesn't suspend us
            // before the next track starts playing
            #if os(iOS)
            let bgTaskId: UIBackgroundTaskIdentifier
            if !isRunningTests {
                bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "SkipToNext") {
                    self.logger.warning("Background task expired during skipToNext")
                }
            } else {
                bgTaskId = .invalid
            }
            #endif
            
            await playEpisode(next, preserveCurrent: false)
            isAdvancingQueue = false
            
            #if os(iOS)
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
            }
            #endif
        }
    }
    
    /// Restart current episode from the beginning.
    func skipToPrevious() {
        seek(to: 0)
    }
    
    /// Execute a configurable remote command action (AirPods, lock screen).
    func executeRemoteAction(_ action: RemoteCommandAction) {
        switch action {
        case .skipBack:
            // Uses the user's configured skip-back duration (default 15s)
            let interval = Double(UserDefaults.standard.object(forKey: "skipBackwardSeconds") as? Int ?? 15)
            seekRelative(seconds: -interval)
        case .skipForward:
            // Uses the user's configured skip-forward duration (default 30s)
            let interval = Double(UserDefaults.standard.object(forKey: "skipForwardSeconds") as? Int ?? 30)
            seekRelative(seconds: interval)
        case .previousEpisode:
            skipToPrevious()
        case .nextEpisode:
            skipToNext()
        }
    }
    
    // MARK: - Playback Completion & Auto-Advance
    
    private func handlePlaybackCompleted() {
        logger.info("handlePlaybackCompleted: pos=\(self.currentPosition)s dur=\(self.currentDuration)s loading=\(self.isLoadingNewEpisode) advancing=\(self.isAdvancingQueue) item=\(self.currentItem?.title ?? "nil")")
        guard !isAdvancingQueue, !isLoadingNewEpisode else { return }
        
        // Guard: reject completions where duration hasn't loaded yet.
        // This catches the KVO race where player.removeAllItems() inside playEpisode
        // fires a stale currentItem→nil callback AFTER isLoadingNewEpisode and
        // isAdvancingQueue have been reset. At that point currentDuration is 0 for
        // the new episode — a genuinely completed episode always has a known duration.
        guard currentDuration > 0 else {
            logger.debug("Ignoring completion with duration=0 (KVO race)")
            return
        }
        
        // Refresh position directly from AVPlayer — the periodic time observer
        // may be stale in the background, causing a real completion to look
        // spurious (currentPosition far from currentDuration).
        let actualPosition = player.currentTime().seconds
        if actualPosition.isFinite && actualPosition > 0 {
            currentPosition = actualPosition
        }
        
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
        
        // Check if external code (e.g., sleep timer "DriftOff Mode") vetoes auto-advance
        if let shouldAdvance = shouldAutoAdvanceToNextEpisode, !shouldAdvance() {
            logger.info("Auto-advance vetoed by shouldAutoAdvanceToNextEpisode — stopping")
            isAdvancingQueue = false
            stop()
            return
        }
        
        let next = queue.removeFirst()
        logger.info("Auto-advancing to: \(next.title)")
        
        Task {
            // Request background execution time so iOS doesn't suspend us
            // before the next track starts playing
            #if os(iOS)
            let bgTaskId: UIBackgroundTaskIdentifier
            if !isRunningTests {
                bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "AutoAdvance") {
                    self.logger.warning("Background task expired during auto-advance")
                }
            } else {
                bgTaskId = .invalid
            }
            #endif
            
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
            
            #if os(iOS)
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
            }
            #endif
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
        guard var item = currentItem else { return }
        
        isRecovering = true
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let position = currentPosition
        
        // Check for a local download before retrying network — if the episode
        // is downloaded, skip the backoff delay and play immediately from disk.
        if item.localFileUrl == nil, let resolver = localFileResolver,
           let localUrl = resolver(item.id) {
            item.localFileUrl = localUrl
            currentItem?.localFileUrl = localUrl
            logger.info("Stream recovery: found local download for \(item.title), using offline playback")
            Task {
                await playEpisode(item, initialPosition: position)
                isRecovering = false
            }
            return
        }
        
        // ── Network-aware gate: don't burn retries when offline ──
        // If we have a network monitor and it says we're disconnected,
        // skip the retry and wait for the connectivity callback instead.
        if let monitor = networkMonitor, !monitor.isConnected {
            logger.info("Stream recovery: offline — waiting for connectivity instead of retrying (attempt \(attempt))")
            errorMessage = "No connection. Will retry when network returns."
            // Keep episode metadata visible on CarPlay/lock screen during offline wait
            updateNowPlayingInfo(for: item)
            isRecovering = false
            // Don't increment — we'll get a fresh chance via onConnectivityRestored
            recoveryAttempts = max(0, recoveryAttempts - 1)
            return
        }
        
        // ── Escalating backoff: 5s, 10s, 15s, 20s, 30s ──
        let scheduleIndex = min(attempt - 1, Self.recoveryBackoffSchedule.count - 1)
        let backoff = Self.recoveryBackoffSchedule[scheduleIndex]
        logger.info("Stream recovery attempt \(attempt)/\(Self.maxRecoveryAttempts) in \(backoff)s")
        
        Task {
            try? await Task.sleep(for: .seconds(backoff))
            
            // Invalidate cached URL to get a fresh CDN token
            await urlResolver.invalidate(item.audioUrl)
            
            await playEpisode(item, initialPosition: position)
            isRecovering = false
        }
    }
    
    /// Subscribes to the network monitor's connectivity restoration callback.
    /// When connectivity returns after an outage, auto-resets recovery attempts
    /// and retries playback if the player is in an error state.
    /// Must be called after setting `networkMonitor`.
    func subscribeToConnectivityRestoration() {
        networkMonitor?.onConnectivityRestored = { [weak self] in
            guard let self else { return }
            
            // Only auto-retry if there's a pending error (recovery exhausted or offline message)
            guard self.errorMessage != nil, self.currentItem != nil else {
                self.logger.debug("Connectivity restored but no pending error — no action needed")
                return
            }
            
            self.logger.info("Connectivity restored — auto-retrying playback")
            self.errorMessage = nil
            self.recoveryAttempts = 0
            self.isRecovering = false
            self.attemptStreamRecovery()
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
                // Push rate=0 to CarPlay/lock screen so it doesn't show
                // a "playing" state while no audio is flowing
                self?.updateNowPlayingPlaybackState()
                // Refresh metadata so CarPlay Now Playing / Lock Screen shows
                // "Connecting…" or the normal subtitle when buffering state changes
                if let item = self?.currentItem {
                    self?.updateNowPlayingInfo(for: item)
                }
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
            DispatchQueue.main.async {
                if item.status == .failed, let error = item.error {
                    self?.handlePlaybackError(error)
                }
            }
        }
        itemObservers.append(statusObserver)
    }
    
    // MARK: - Current Item Change
    
    private func handleCurrentItemChanged(_ item: AVPlayerItem?) {
        if item == nil && isPlaying && !isLoadingNewEpisode && !isAdvancingQueue {
            // Player ran out of items (not a mid-swap transition)
            handlePlaybackCompleted()
        }
    }
    
    // MARK: - Queue Persistence
    
    /// Save queue + current item to UserDefaults.
    private func persistQueue() {
        queueDirty = false
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
        queueDirty = true  // Force the persist even if queue is clean
        persistQueue()
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - Queue Dirty Flag Test Helpers
    
    /// Test-only: check if queue is dirty.
    func testIsQueueDirty() -> Bool { queueDirty }
    
    /// Test-only: clear the dirty flag without persisting.
    func testClearQueueDirty() { queueDirty = false }
    
    /// Test-only: check whether the timer should persist (same logic as the timer body).
    func testShouldTimerPersist() -> Bool { queueDirty || isPlaying }
    
    // MARK: - Offline Rehydration
    
    /// Stored resolver for local file lookup — set by `rehydrateLocalFileUrls`
    /// and re-used by `attemptStreamRecovery` to check for local downloads.
    private var localFileResolver: ((String) -> URL?)?
    
    /// Re-attach `localFileUrl` to queue items after a cold start.
    ///
    /// `QueueItem.localFileUrl` is intentionally not serialized (device-local paths
    /// are meaningless across devices). After `restoreQueue()`, all items have
    /// `localFileUrl = nil`. This method re-populates them from DownloadManager.
    ///
    /// - Parameter resolver: Closure mapping episode GUID → local file URL (or nil).
    func rehydrateLocalFileUrls(using resolver: @escaping (String) -> URL?) {
        localFileResolver = resolver
        
        // Rehydrate currentItem
        if let item = currentItem, let localUrl = resolver(item.id) {
            self.currentItem?.localFileUrl = localUrl
            logger.info("Rehydrated local URL for current item: \(item.title)")
        }
        
        // Rehydrate queue items
        for i in self.queue.indices {
            if let localUrl = resolver(self.queue[i].id) {
                self.queue[i].localFileUrl = localUrl
                logger.info("Rehydrated local URL for queue item: \(self.queue[i].title)")
            }
        }
    }
    
    // MARK: - Now Playing Info (Lock Screen / CarPlay)
    
    private func updateNowPlayingInfo(for item: QueueItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: nowPlayingStatusSubtitle,
            MPMediaItemPropertyAlbumTitle: item.podcastTitle,
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
        // Show rate=0 when buffering so CarPlay doesn't display a "playing" state
        // while no audio is actually flowing (e.g., during initial connection or stall)
        info[MPNowPlayingInfoPropertyPlaybackRate] = (isPlaying && !isBuffering) ? playbackRate : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // MARK: - Image Loading (for Now Playing artwork)
    
    #if os(iOS)
    private func loadImage(from urlString: String) async -> UIImage? {
        let key = urlString as NSString
        // 1. Memory cache
        if let cached = ImageCacheStore.shared.cache.object(forKey: key) {
            return cached
        }
        // 2. Disk cache
        if let diskCached = ImageCacheStore.shared.loadFromDisk(key: urlString) {
            ImageCacheStore.shared.cache.setObject(diskCached, forKey: key)
            return diskCached
        }
        // 3. Network fetch
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            ImageCacheStore.shared.cache.setObject(image, forKey: key)
            ImageCacheStore.shared.saveToDisk(image: image, key: urlString)
            return image
        } catch {
            return nil
        }
    }
    #else
    private func loadImage(from urlString: String) async -> NSImage? {
        let key = urlString as NSString
        // 1. Memory cache
        if let cached = ImageCacheStore.shared.cache.object(forKey: key) {
            return cached
        }
        // 2. Disk cache
        if let diskCached = ImageCacheStore.shared.loadFromDisk(key: urlString) {
            ImageCacheStore.shared.cache.setObject(diskCached, forKey: key)
            return diskCached
        }
        // 3. Network fetch
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else { return nil }
            ImageCacheStore.shared.cache.setObject(image, forKey: key)
            ImageCacheStore.shared.saveToDisk(image: image, key: urlString)
            return image
        } catch {
            return nil
        }
    }
    #endif
    
    // MARK: - Testable Queue Logic
    
    /// Synchronous helper that mirrors the queue-manipulation portion of `playEpisode`.
    /// Used by unit tests to validate preserve/switch logic without AVPlayer side effects.
    func testablePreserveAndSwitch(to item: QueueItem, preserveCurrent: Bool) {
        if preserveCurrent, let previous = currentItem, previous.id != item.id, !previous.isPlayed {
            // Remove any existing instances first to prevent duplicates
            queue.removeAll { $0.id == previous.id }
            queue.insert(previous, at: 0)
        }
        currentItem = item
        currentPosition = 0   // Reset — mirrors playEpisode's reset
        currentDuration = 0   // Reset — mirrors playEpisode's reset
        queue.removeAll { $0.id == item.id }
    }
    
    /// Test helper: directly set queue contents for scenarios requiring abnormal states
    /// (e.g., simulating duplicates from sync or restore bugs).
    func testableSetQueue(_ items: [QueueItem]) {
        queue = items
    }
    
    /// Test helper: mirrors the position-resume logic from `playEpisode` without AVPlayer.
    /// Computes `targetPosition = initialPosition ?? item.positionSeconds`, applies it to
    /// `currentPosition`, and handles skipIntro — exactly matching the production path.
    /// Returns the computed targetPosition for assertion.
    @discardableResult
    func testablePlayEpisodePositionResume(_ item: QueueItem, initialPosition: TimeInterval? = nil) -> TimeInterval {
        // Mirror playEpisode: reset, then compute target
        currentItem = item
        currentPosition = 0
        currentDuration = 0
        queue.removeAll { $0.id == item.id }
        
        let targetPosition = initialPosition ?? Double(item.positionSeconds)
        if targetPosition > 0 {
            currentPosition = targetPosition
        }
        
        // Update instance-level skip/speed vars from the QueueItem (mirrors production playEpisode)
        skipIntroSeconds = item.skipIntroSeconds
        skipOutroSeconds = item.skipOutroSeconds
        playbackRate = item.playbackSpeed
        
        // Skip intro if configured
        let effectiveSkipIntro = item.skipIntroSeconds > 0 ? item.skipIntroSeconds : skipIntroSeconds
        if effectiveSkipIntro > 0, targetPosition < Double(effectiveSkipIntro) {
            currentPosition = Double(effectiveSkipIntro)
        }
        
        return targetPosition
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
    
    /// Test helper: check whether skip outro would trigger at the current position.
    /// Mirrors the exact detection logic from the periodic time observer.
    /// IMPORTANT: This MUST stay in sync with the real detection code in setupPlayerObservers().
    func testableShouldSkipOutro() -> Bool {
        let outroSeconds = self.skipOutroSeconds
        return outroSeconds > 0 &&
            self.currentDuration > 0 &&
            !self.isAdvancingQueue &&
            self.currentPosition >= self.currentDuration - Double(outroSeconds)
    }
    
    /// Test helper: set the episode transition state.
    /// Allows tests to simulate the mid-transition window where sync should be blocked.
    func testableSetTransitionState(_ inTransition: Bool) {
        isLoadingNewEpisode = inTransition
    }
    
    /// When set, `testableHandlePlaybackCompleted` uses this value instead of
    /// the stale `currentPosition` to simulate AVPlayer position refresh.
    /// Set to nil for the old behavior (stale position).
    var testableOverridePosition: TimeInterval? = nil
    
    /// Test helper: simulate the full handlePlaybackCompleted flow without AVPlayer.
    /// This mirrors the real auto-advance path: mark current as complete → pop next from queue
    /// → switch to it (resetting position/duration). Returns the completed item and the new current item.
    @discardableResult
    func testableHandlePlaybackCompleted() -> (completed: QueueItem?, next: QueueItem?) {
        guard !isAdvancingQueue, !isLoadingNewEpisode else { return (nil, nil) }
        
        // Duration guard (same as real handlePlaybackCompleted) — an episode
        // with duration 0 hasn't loaded yet and cannot have genuinely completed.
        guard currentDuration > 0 else { return (nil, nil) }
        
        // Position refresh (mirrors real code: player.currentTime().seconds)
        // In tests, use testableOverridePosition to simulate fresh AVPlayer position.
        if let override = testableOverridePosition {
            currentPosition = override
            testableOverridePosition = nil  // consume once
        }
        
        // Spurious completion guard (same as real handlePlaybackCompleted)
        if currentDuration > 30, (currentDuration - currentPosition) > 10 {
            return (nil, nil)
        }
        
        isAdvancingQueue = true
        
        let completed = currentItem
        if let completed {
            onEpisodeCompleted?(completed)
        }
        
        guard !queue.isEmpty else {
            currentItem = nil
            currentPosition = 0
            currentDuration = 0
            isPlaying = false
            isAdvancingQueue = false
            return (completed, nil)
        }
        
        // Check if external code vetoes auto-advance (e.g., sleep timer "DriftOff Mode")
        if let shouldAdvance = shouldAutoAdvanceToNextEpisode, !shouldAdvance() {
            currentItem = nil
            currentPosition = 0
            currentDuration = 0
            isPlaying = false
            isAdvancingQueue = false
            return (completed, nil)
        }
        
        let next = queue.removeFirst()
        
        // This mirrors what playEpisode does synchronously:
        currentItem = next
        currentPosition = 0   // Critical: reset before any sync can fire
        currentDuration = 0   // Critical: reset before any sync can fire
        isLoadingNewEpisode = true
        
        // Fire the onItemChanged callback (which triggers syncPlaybackState in production)
        onItemChanged?(next)
        
        isLoadingNewEpisode = false
        isAdvancingQueue = false
        
        return (completed, next)
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
    
    /// Test helper: expose `attemptStreamRecovery()` for testing offline recovery behavior.
    func testableAttemptStreamRecovery() {
        attemptStreamRecovery()
    }
    
    /// Test helper: set recovery state for testing now-playing subtitle behavior.
    func setRecoveringForTest(_ value: Bool) {
        isRecovering = value
    }
    
    /// Computed subtitle for the Now Playing screen's artist field.
    /// Shows buffering/recovery/error status alongside the podcast name,
    /// visible on CarPlay Now Playing, Lock Screen, and Dynamic Island.
    ///
    /// Priority: buffering > error > recovery > normal
    var nowPlayingStatusSubtitle: String {
        guard let item = currentItem else { return "" }
        let podcastName = item.podcastAuthor ?? item.podcastTitle
        
        // Buffering takes highest priority — user sees "Connecting…"
        if isBuffering {
            return "Connecting… — \(podcastName)"
        }
        
        // Error message (recovery exhausted or offline)
        if let error = errorMessage {
            return "\(error) — \(podcastName)"
        }
        
        // Active recovery (between retries)
        if isRecovering {
            return "Reconnecting… — \(podcastName)"
        }
        
        // Normal state
        return podcastName
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

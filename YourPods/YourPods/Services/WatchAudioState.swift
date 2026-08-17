import Foundation

/// Pure-logic state manager for watch audio playback, kept for testability.
///
/// Note: this does NOT reflect how production works — the watch target's
/// `WatchAudioManager` is the actual production implementation; it does NOT
/// wrap or delegate to this type. `WatchAudioState` hand-mirrors
/// `WatchAudioManager`'s state-transition logic in the iOS target so it can be
/// exercised from YourPodsTests (the watch target has no test bundle). Keep
/// the two in sync by hand when production behavior changes — see
/// `WatchAudioManagerBackgroundLifecycleTests`'s source-scan guard for one
/// example of catching drift.
///
/// Design: mirrors the `WatchAdvancePlanner` / `WatchWireFormat` pattern —
/// pure, testable logic lives in the iOS target; the watch target's actual
/// manager is hand-mirrored to match it for production behavior.
struct WatchAudioState {
    
    // MARK: - State
    
    struct EpisodeInfo: Equatable {
        let id: String
        let title: String
        let album: String
        let streamUrl: String?
        let localPath: String?
        let artUri: String?
        let duration: Int
        var position: Int
    }
    
    /// The currently-playing episode (nil = nothing playing).
    private(set) var currentEpisode: EpisodeInfo?
    
    /// Whether audio is actively playing.
    private(set) var isPlaying: Bool = false
    
    /// Current playback position in seconds.
    private(set) var progress: Double = 0
    
    /// Playback source for the current episode.
    private(set) var playbackSource: WatchPlaybackResolver.PlaybackSourceType = .none
    
    /// The ordered queue of upcoming episodes.
    private(set) var queue: [EpisodeInfo] = []
    
    /// Status text for display.
    private(set) var statusText: String = "No episode"
    
    // MARK: - Play
    
    /// Begin playing an episode. Returns the resolved URL info (or nil if no source).
    /// The caller (WatchAudioManager) uses the result to actually set up AVPlayer.
    @discardableResult
    mutating func play(episode: EpisodeInfo, documentsDirectory: URL) -> WatchPlaybackResolver.Resolution? {
        let resolution = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: episode.localPath,
            streamUrl: episode.streamUrl,
            position: episode.position,
            documentsDirectory: documentsDirectory
        )
        
        guard let resolution else {
            statusText = "No audio source"
            playbackSource = .none
            return nil
        }
        
        // Remove from queue if present (it's now the current item)
        queue.removeAll { $0.id == episode.id }
        
        currentEpisode = episode
        isPlaying = true
        progress = Double(episode.position)
        playbackSource = resolution.source
        statusText = resolution.source == .streaming ? "Streaming..." : "Playing"
        // Mirrors WatchAudioManager.startTimer()'s isInBackground gate: play()
        // reached via background auto-advance must NOT resurrect the timer —
        // it would run for the rest of the background session. The foreground
        // observer (handleWillEnterForeground) restarts it on resume.
        timerState = isInBackground ? .suspended : .active

        return resolution
    }
    
    // MARK: - Toggle Play/Pause
    
    mutating func togglePlayPause() {
        guard currentEpisode != nil else { return }
        isPlaying.toggle()
        statusText = isPlaying ? (playbackSource == .streaming ? "Streaming..." : "Playing") : "Paused"
    }
    
    // MARK: - Seek
    
    /// Seek by a relative number of seconds. Returns the new target position.
    @discardableResult
    mutating func seekRelative(by seconds: Double) -> Double {
        guard currentEpisode != nil else { return 0 }
        let newPosition = max(0, progress + seconds)
        progress = newPosition
        return newPosition
    }
    
    /// Seek to an absolute position. Returns the target position.
    @discardableResult
    mutating func seekTo(_ seconds: Double) -> Double {
        guard currentEpisode != nil else { return 0 }
        progress = max(0, seconds)
        return progress
    }
    
    // MARK: - Update Progress (from timer)
    
    mutating func updateProgress(_ position: Double) {
        progress = position
    }
    
    // MARK: - Stop
    
    mutating func stop() {
        currentEpisode = nil
        isPlaying = false
        progress = 0
        playbackSource = .none
        statusText = "No episode"
        
        // Reset freeze-fix tracking state
        remoteCommandsConfigured = false
        lastFetchedArtworkUrl = nil
        lastPublishedProgress = nil
        lastNowPlayingUpdate = nil
        
        // CAROUSEL FIX: Suspend timer on stop — no playback = no timer needed
        timerState = .suspended
    }
    
    // MARK: - Auto-Advance
    
    /// Called when the current episode finishes. Pops the next episode from the queue.
    /// Returns the next episode to play, or nil if the queue is empty.
    mutating func handleEpisodeCompleted() -> EpisodeInfo? {
        guard !queue.isEmpty else {
            stop()
            return nil
        }
        
        let next = queue.removeFirst()
        return next
    }
    
    // MARK: - Queue Management
    
    mutating func loadQueue(_ episodes: [EpisodeInfo]) {
        queue = episodes
    }
    
    // MARK: - Remote Command Setup Tracking (Freeze Fix #1)
    
    /// Whether remote commands have been set up at least once.
    /// The WatchAudioManager checks this to avoid leaking addTarget closures.
    private(set) var remoteCommandsConfigured: Bool = false
    
    /// Mark that remote commands have been configured. Called once after first play.
    mutating func markRemoteCommandsConfigured() {
        remoteCommandsConfigured = true
    }
    
    // MARK: - Progress Publish Throttle (Freeze Fix #2)
    
    /// Track the last published progress value.
    private var lastPublishedProgress: Double?
    
    /// Whether the new progress value is different enough (≥1s) to publish.
    /// First call always returns true; subsequent calls require ≥1s change.
    func shouldPublishProgress(newProgress: Double) -> Bool {
        guard let last = lastPublishedProgress else { return true }
        return abs(newProgress - last) >= 1.0
    }
    
    /// Record that progress was published at the current value.
    mutating func recordPublishedProgress() {
        lastPublishedProgress = progress
    }
    
    // MARK: - Now Playing Info Throttle (Freeze Fix #3)
    
    /// Track when MPNowPlayingInfoCenter was last updated.
    private var lastNowPlayingUpdate: Date?
    
    /// Minimum interval between MPNowPlayingInfoCenter updates (seconds).
    private static let nowPlayingThrottleInterval: TimeInterval = 5.0
    
    /// Whether enough time has passed (~5s) to update MPNowPlayingInfoCenter.
    func shouldUpdateNowPlaying() -> Bool {
        guard let last = lastNowPlayingUpdate else { return true }
        return Date().timeIntervalSince(last) >= Self.nowPlayingThrottleInterval
    }
    
    /// Record that now-playing info was updated.
    mutating func recordNowPlayingUpdate() {
        lastNowPlayingUpdate = Date()
    }
    
    /// Test helper: override the last update timestamp.
    mutating func overrideLastNowPlayingUpdate(_ date: Date) {
        lastNowPlayingUpdate = date
    }
    
    // MARK: - Artwork Cache (Freeze Fix #4)
    
    /// Track the last-fetched artwork URL to avoid redundant network requests.
    private var lastFetchedArtworkUrl: String?
    
    /// Whether artwork should be fetched for the given URL.
    /// Returns false if the URL matches the last-fetched URL (same podcast artwork).
    func shouldFetchArtwork(url: String) -> Bool {
        return url != lastFetchedArtworkUrl
    }
    
    /// Record that artwork was fetched for the given URL.
    mutating func recordArtworkFetched(url: String) {
        lastFetchedArtworkUrl = url
    }
    
    // MARK: - Background Lifecycle (CAROUSEL Watchdog Fix)
    
    /// Timer suspension state — tracks whether the progress timer should be active.
    enum TimerLifecycleState: Equatable {
        case active
        case suspended
    }
    
    /// Current timer lifecycle state.
    /// Starts as `.suspended` — transitioned to `.active` only when play() is called.
    /// CAROUSEL FIX: Was `.active` — caused background wakes without playback to
    /// believe a timer should be running. Timer fires accumulated during suspension
    /// and burst on resume → watchdog kill → relaunch penalty.
    private(set) var timerState: TimerLifecycleState = .suspended

    /// Mirrors WatchAudioManager.isInBackground — set by the background/foreground
    /// lifecycle handlers below. play() consults this so a background auto-advance
    /// doesn't restart the timer (see play()).
    private(set) var isInBackground: Bool = false
    
    /// Whether the audio session should be deactivated (i.e., nothing is playing).
    /// True when no episode is loaded — the caller should call
    /// `AVAudioSession.sharedInstance().setActive(false)` to let watchOS suspend cleanly.
    var shouldDeactivateAudioSession: Bool {
        return currentEpisode == nil
    }
    
    /// Called when the app transitions to the background.
    /// CAROUSEL FIX: Suspends the progress timer to prevent main-thread work pileup.
    /// When the app is suspended, timer fires accumulate. On resume, they all fire
    /// in a burst — overwhelming the main thread and triggering a watchdog kill.
    mutating func handleDidEnterBackground() {
        isInBackground = true
        timerState = .suspended
    }

    /// Called when the app returns to the foreground.
    /// Resumes the progress timer ONLY if playback is active.
    /// If nothing is playing, the timer stays suspended — no UI to update.
    mutating func handleWillEnterForeground() {
        isInBackground = false
        if isPlaying {
            timerState = .active
        }
    }
}

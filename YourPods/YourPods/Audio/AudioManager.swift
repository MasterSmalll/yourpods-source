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

/// What the current Now Playing artwork represents.
///
/// Replaces a boolean `isPlaceholder`, which could not express three states:
/// chapter art is not the episode's own art, so the old
/// `loadedUrl != episodeArtworkUrl` test classified it as an upgradeable
/// placeholder and let the next artwork update clobber it.
enum NowPlayingArtworkKind: Equatable {
    case placeholder   // podcast logo or branded fallback — upgradeable
    case episode       // the episode's own art
    case chapter       // art for the chapter currently playing — highest priority
}

/// Central audio engine wrapping AVQueuePlayer for gapless background podcast playback.
/// Manages all audio playback using native iOS APIs.
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

    /// Wall-clock instant this device's playback state last *changed* (play, pause,
    /// seek, load, stop). Used as the client event time for sync:
    /// the server honors the device whose change is newest, so a stale offline
    /// device cannot clobber newer cross-device state. Persisted across launches.
    private(set) var playbackEventTime: Date = .distantPast

    /// The event time to send with a playback push. While actively playing, the
    /// device is the live source of truth, so it reports `now`; while paused/idle it
    /// reports the frozen last-change time so it loses to any newer remote change.
    var playbackEventTimeForSync: Date {
        isPlaying ? now() : playbackEventTime
    }

    /// Stamp `playbackEventTime` to the current clock. Called from every local
    /// playback-state transition (play, pause, seek, load, stop).
    private func stampPlaybackEvent() {
        playbackEventTime = now()
    }
    
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

    /// Set by `startPlayerAtCurrentRate()` when a non-1.0 playback rate was
    /// requested but the new AVPlayerItem wasn't `.readyToPlay` yet. Setting
    /// `player.rate` directly on an unready item is silently dropped by
    /// AVQueuePlayer (the auto-advance "silent stop" bug). The `\.status`
    /// observer applies this on `.readyToPlay`, then clears it. Cleared on
    /// `pause()`/`stop()` so a deferred rate can't kick playback after the
    /// user paused or a new load began.
    private var pendingPlaybackRate: Float?

    /// Monotonic token identifying the most recent now-playing metadata update.
    /// Each async artwork load captures the token at start and only applies its
    /// result if it is still the newest — drops stale older-episode images that
    /// would otherwise win the race and leave the wrong artwork on the lock
    /// screen / Dynamic Island.
    private var nowPlayingLoadToken = 0

    /// Episode id whose artwork is currently applied to MPNowPlayingInfoCenter.
    /// Lets us skip redundant image loads and drop the previous episode's
    /// artwork the moment the episode changes.
    private var currentArtworkItemId: String?

    /// What kind of artwork is currently applied to MPNowPlayingInfoCenter —
    /// a placeholder should still be replaced by a later, higher-priority
    /// update (episode or chapter art).
    private(set) var currentArtworkKind: NowPlayingArtworkKind = .placeholder

    /// Chapter index whose artwork is currently displayed, or nil when no
    /// chapter art is showing. Episode-scoped: cleared wherever artwork
    /// state resets (episode change, stop). NOT used as a staleness ratchet
    /// (see `applyChapterArtwork`) — a lower index legitimately arrives on a
    /// backward seek and must still be honored.
    private(set) var currentArtworkChapterIndex: Int?

    // Skip intro/outro
    var skipIntroSeconds: Int = 0
    var skipOutroSeconds: Int = 0
    
    /// Callback to re-resolve per-podcast settings at play time.
    /// Returns (skipIntro, skipOutro, playbackSpeed, skipForward, skipBackward).
    /// Set by PlayerManager so AudioManager can query current settings
    /// without a direct SettingsManager dependency.
    /// STUB: not yet wired — tests should fail until it is.
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

    /// Fired with the episode being **left**, immediately before `currentItem` is replaced.
    ///
    /// `onItemChanged` names the episode arriving; nothing named the one departing, so the
    /// only record of it was a snapshot `PlayerManager` had taken when that episode
    /// *started* — its resume position, not where the listener actually got to. The push
    /// that clears its `nowPlaying` therefore asserted a stale position with a fresh event
    /// time, which the server merges as a rewind.
    ///
    /// This is the one moment the outgoing episode and its live position both still exist.
    var onItemWillChange: ((QueueItem) -> Void)?

    /// Callback for every genuine position tick (used by `ChapterCoordinator`
    /// to detect chapter boundary crossings — see `ChapterCoordinator.attach(to:)`).
    /// Fired from the SAME periodic time observer that assigns `currentPosition`
    /// below (`:readyToPlay`-gated, ~0.5s cadence) — deliberately not a
    /// `didSet` on `currentPosition` itself, which also fires from `playEpisode`'s
    /// synchronous seed assignment before the player item is ready, i.e. before
    /// `onItemChanged` has had a chance to load the NEW item's chapters.
    var onPositionChanged: ((TimeInterval) -> Void)?

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

    /// Donates playback intents to the system so episodes appear in
    /// Control Center media suggestions. Nil in tests by default.
    @ObservationIgnored var mediaIntentDonor: MediaIntentDonating?

    /// Telemetry callback for playback errors.
    /// Parameters: (episodeUrl, episodeGuid, podcastUrl, errorDescription, recoveryAttempt)
    var onPlaybackError: ((String?, String?, String?, String, Int) -> Void)?
    
    // MARK: - Persistence Keys
    
    private static let queueKey = "savedQueue"
    private static let currentItemKey = "savedCurrentItem"
    private static let currentPositionKey = "savedCurrentPosition"
    private static let playbackEventTimeKey = "savedPlaybackEventTime"

    // MARK: - Init

    /// Clock used to stamp `playbackEventTime`. Injectable so tests can drive
    /// event-time ordering deterministically.
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        self.playbackEventTime = now()
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
            // AirPlay audio already routes because AVQueuePlayer defaults
            // allowsExternalPlayback to true; set it explicitly so the intent
            // survives future refactors.
            player.allowsExternalPlayback = true
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
                // Ignore the player clock until the item can actually play.
                // During load — and forever, when offline loading fails — the
                // player reports 0, which would clobber the seeded resume
                // position playEpisode wrote for CarPlay/lock screen.
                guard self.player.currentItem?.status == .readyToPlay else { return }
                self.currentPosition = time.seconds
                self.updateNowPlayingProgress()
                self.onPositionChanged?(time.seconds)

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

        // Observe output route changes (pause when the current route disappears,
        // e.g. headphones pulled or a Bluetooth/AirPlay device dropped).
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification)
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
        stampPlaybackEvent()   // Local playback-state change
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
        
        startPlayerAtCurrentRate()
        isPlaying = true
    }

    /// Start playback without the early-rate-drop bug.
    ///
    /// Setting `player.rate` directly on an item that is not yet `.readyToPlay`
    /// is silently dropped by AVQueuePlayer — the root cause of the auto-advance
    /// "silent stop" (and the "pause→play restarts it" symptom). Instead call
    /// `player.play()`, which AVQueuePlayer honors even before the item is ready
    /// (it defers via `automaticallyWaitsToMinimizeStalling` and starts once
    /// buffered). A non-1.0 per-episode rate is applied now if the item is
    /// already ready, otherwise deferred to the `\.status` observer via
    /// `pendingPlaybackRate`.
    private func startPlayerAtCurrentRate() {
        player.play()
        guard playbackRate != 1.0 else {
            pendingPlaybackRate = nil
            return
        }
        if player.currentItem?.status == .readyToPlay {
            player.rate = playbackRate
            pendingPlaybackRate = nil
        } else {
            pendingPlaybackRate = playbackRate
        }
    }

    func pause() {
        stampPlaybackEvent()   // Local playback-state change
        pendingPlaybackRate = nil   // don't let a deferred rate kick after pause
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Called by the item `\.status` observer when the current item reaches
    /// `.readyToPlay`. Applies a deferred non-1.0 rate (which couldn't be set
    /// while the item was unready) and, as a safety net, re-kicks a stalled
    /// engine that was asked to play but is sitting at rate 0.
    private func handleItemReadyToPlay() {
        if let pending = pendingPlaybackRate {
            player.rate = pending
            pendingPlaybackRate = nil
        } else if isPlaying && player.rate == 0 {
            // We intended to play (isPlaying) but the engine never started —
            // re-kick it now that the item is ready. Guards the silent stop.
            player.play()
        }
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
        stampPlaybackEvent()   // Local playback-state change
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

    /// Adopt a playback position that originated on **another device**
    /// (the sync contract, apply side). Differs from `seek(to:)` in two
    /// load-bearing ways:
    ///
    /// 1. **It writes `currentPosition` explicitly.** `AVPlayer.seek` is a no-op when
    ///    no `AVPlayerItem` is loaded — an episode restored into the mini player but
    ///    never played this launch — and the periodic time observer then never fires.
    ///    `currentPosition` is what the UI renders *and* what the outbound playback
    ///    push reads, so an adopt that only seeks is invisible: the device keeps
    ///    displaying and re-asserting the stale local position. That was the whole of
    ///    one real failure: web at 36:07, iOS stuck at 13:48 re-pushing it seven times.
    ///
    /// 2. **It does not stamp a fresh local event time.** A remote adopt is not a local
    ///    playback event. Claiming `now` would make this device outrank the one that
    ///    actually produced the position, and the contract is explicit that a client which
    ///    re-pushes with a fresh event time "silently destroys the newer one". Passing
    ///    the server's event time keeps the ordering honest; `nil` leaves it untouched.
    func adoptRemotePosition(_ seconds: TimeInterval, eventTime: Date?) {
        let target = max(0, seconds)
        currentPosition = target
        currentItem?.positionSeconds = Int(target)
        if let eventTime { playbackEventTime = eventTime }

        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateNowPlayingProgress()
            }
        }
    }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        // If a rate is still deferred (item loading), keep it in sync so the
        // .readyToPlay handler applies the latest speed, not a stale one.
        if pendingPlaybackRate != nil {
            pendingPlaybackRate = rate
        }
        if isPlaying {
            player.rate = rate
        }
        updateNowPlayingPlaybackState()
        onPlaybackRateChanged?(rate)
    }
    
    func stop() {
        stampPlaybackEvent()   // Local playback-state change
        pendingPlaybackRate = nil
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
    func playEpisode(_ item: QueueItem, initialPosition: TimeInterval? = nil, preserveCurrent: Bool = false, autoPlay: Bool = true) async {
        logger.info("Playing episode: \(item.title)")

        // Hand over the episode being left while its live position still exists. Every
        // path into a new episode comes through here, so this is the one place that can
        // see both sides of the switch.
        if let outgoing = currentItem, outgoing.id != item.id {
            onItemWillChange?(outgoing)
        }
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

        // ── Re-resolve per-podcast settings BEFORE the first Now Playing write.
        // The resolver is a synchronous query, so hoisting it above the player
        // work is safe, and it lets the seeded position below fold in skip-intro.
        // QueueItem values may be stale if settings changed after the episode
        // was queued, or if the item came from server sync / queue restore.
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
            playbackRate = item.playbackSpeed
        }

        // ── Compute the seek target now: saved position folded with skip-intro.
        // Known before the player is touched, so CarPlay/lock screen can show
        // the true resume position immediately instead of the previous
        // episode's position (or 0).
        var targetPosition = initialPosition ?? Double(item.positionSeconds)
        if skipIntroSeconds > 0, targetPosition < Double(skipIntroSeconds) {
            targetPosition = Double(skipIntroSeconds)
        }

        // ── Immediately populate Now Playing so CarPlay/lock screen shows
        // episode info while buffering, not a blank music note. Seed elapsed/
        // duration from the queue item: offline the AVAsset never loads, so
        // the player can never supply them. The duration KVO overwrites the
        // feed value with the authoritative one once the asset loads. ──
        currentItem = item
        currentPosition = targetPosition
        currentDuration = TimeInterval(item.durationSeconds ?? 0)
        stampPlaybackEvent()   // Loading a new episode is a state change
        updateNowPlayingInfo(for: item)

        #if os(iOS)
        // Claim the now-playing slot BEFORE any await, but ONLY when we intend
        // to play (autoPlay). CPNowPlayingTemplate only renders our metadata
        // once the system recognizes us as the now-playing source, which needs
        // an active audio session; play() also activates it, but that runs
        // after the seek await — too late if loading stalls offline.
        //
        // The autoPlay:false path is the cross-device now-playing handoff
        // (PlayerManager.reconcileNowPlaying): it loads the server's episode
        // PAUSED and must NOT grab the audio session or start audio (doing so
        // reintroduces the play()→pause() flicker + FigFilePlayer err=-12864 on
        // the not-yet-ready item). It stays paused until the user hits play,
        // and play() claims the session then. So gate this claim on autoPlay.
        if autoPlay {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                logger.info("⟦NOWPLAYING⟧ claimed session: \(item.title) @ \(targetPosition)s / \(self.currentDuration)s")
            } catch {
                logger.warning("⟦NOWPLAYING⟧ session activation failed: \(error.localizedDescription)")
            }
        }
        #endif
        mediaIntentDonor?.donatePlayback(for: item)

        // ── Resolve audio URL: prefer local download, fall back to remote streaming ──
        let playbackUrl: URL

        // Local-first must be robust. `item.localFileUrl` is only a point-in-time
        // snapshot captured when the item was enqueued/restored; it's frequently
        // nil even when the episode IS downloaded (queued before the download
        // finished, injected by sync, or downloaded after the one-shot launch
        // rehydration). So when the snapshot is missing/stale, do a LIVE lookup
        // against the download store (the same resolver stream recovery uses).
        // Streaming a file that's already on disk just stalls AVPlayer when
        // offline — the "won't auto-advance in airplane mode" bug.
        var localFile = item.localFileUrl
        if localFile == nil || !FileManager.default.fileExists(atPath: localFile!.path),
           let resolved = localFileResolver?(item.id),
           FileManager.default.fileExists(atPath: resolved.path) {
            localFile = resolved
        }

        if let localFile, FileManager.default.fileExists(atPath: localFile.path) {
            // Downloaded episode: play from disk (no network needed, instant start)
            logger.info("Using local download: \(localFile.lastPathComponent)")
            playbackUrl = localFile
            // Back-fill the resolved path so persistence + recovery stay consistent.
            currentItem?.localFileUrl = localFile
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

        // NOTE: currentPosition/currentDuration were seeded above from the
        // queue item — do NOT reset them to 0 here; offline they are the only
        // values CarPlay/lock screen will ever get. (Stale-previous-episode
        // leakage is prevented by the seeding, and the time observer ignores
        // the player clock until the item is readyToPlay.)
        recoveryAttempts = 0

        // Remove from upcoming queue if present (it's now the current item)
        queue.removeAll { $0.id == item.id }

        // Seek to the precomputed target (saved position folded with skip-intro).
        if targetPosition > 0 {
            let time = CMTime(seconds: targetPosition, preferredTimescale: 600)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // Begin playback — unless the caller wants a paused load (e.g. the
        // cross-device now-playing handoff, which loads the server's episode at
        // its position but must NOT start audio or grab the audio session).
        // Skipping play() here avoids the old play()→immediate-pause() flicker
        // and its FigFilePlayer error on the not-yet-ready item.
        if autoPlay {
            play()
        }
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
    /// - Parameter autoPlay: When `false`, the next episode loads paused — no audio
    ///   session claim, no play() (see playEpisode's autoPlay contract). Used by
    ///   mark-played-while-paused so a queue advance never starts audio the user
    ///   didn't ask for. Defaults to `true`: existing skip semantics for remote
    ///   commands, skip-outro, Siri, and the watch.
    /// Advance to the next queued episode.
    ///
    /// - Parameter completingCurrent: whether leaving this episode counts as **finishing**
    ///   it. `handleEpisodeCompleted` marks the episode played locally and pushes
    ///   `position: totalDuration` — a claim that propagates to every other device — so
    ///   this must be `false` wherever the user merely moved on: the `.nextEpisode` remote
    ///   command (headphones, car) and the player's own next button.
    ///
    ///   Defaults to `true` because the callers that reach here without saying otherwise —
    ///   skip-outro and auto-advance — genuinely did finish the episode. The two manual
    ///   sites pass `false` explicitly, which is the safer direction for a default to be
    ///   wrong in: a new call site that forgets keeps today's behaviour rather than
    ///   silently dropping a real completion.
    func skipToNext(autoPlay: Bool = true, completingCurrent: Bool = true) {
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
        
        // Fire completion callback for the current item (skip-outro, auto-advance) so it
        // gets marked as played. A manual skip passes completingCurrent: false — the user
        // moved on, they did not finish it, and saying otherwise pushes a full-duration
        // position to every other device.
        if let completed = currentItem {
            if completingCurrent {
                logger.notice("Skipping from: \(completed.title)")
                onEpisodeCompleted?(completed)
            } else {
                logger.notice("Skipping from (not a completion): \(completed.title)")
            }
        }
        
        let next = queue.removeFirst()
        logger.notice("Skipping to next: \(next.title)")
        Task {
            // Request background execution time so iOS doesn't suspend us
            // before the next track starts playing
            #if os(iOS)
            var bgTaskId: UIBackgroundTaskIdentifier = .invalid
            if !isRunningTests {
                bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "SkipToNext") {
                    // An expired assertion MUST be ended — leaving it active
                    // gets the app terminated for background-task abuse.
                    self.logger.warning("Background task expired during skipToNext — releasing assertion")
                    if bgTaskId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskId)
                        bgTaskId = .invalid
                    }
                }
            }
            #endif

            await playEpisode(next, preserveCurrent: false, autoPlay: autoPlay)
            isAdvancingQueue = false

            #if os(iOS)
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
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
            // Headphones, a car button, the lock screen. Nothing here says "I finished
            // this" — only "play the next one".
            skipToNext(completingCurrent: false)
        }
    }
    
    // MARK: - Playback Completion & Auto-Advance
    
    private func handlePlaybackCompleted() {
        logger.info("handlePlaybackCompleted: pos=\(self.currentPosition)s dur=\(self.currentDuration)s loading=\(self.isLoadingNewEpisode) advancing=\(self.isAdvancingQueue) item=\(self.currentItem?.title ?? "nil")")
        guard !isAdvancingQueue, !isLoadingNewEpisode else { return }
        
        // Secondary sanity guard: a genuinely completed episode always has a
        // known duration, so reject duration==0 completions. NOTE: the primary
        // defense against the stale currentItem→nil KVO from a swap now lives in
        // handleCurrentItemChanged (it keys on the LIVE player.currentItem);
        // this guard no longer relies on currentDuration being 0 during load
        // (playEpisode seeds it nonzero up front).
        guard currentDuration > 0 else {
            logger.debug("Ignoring completion with duration=0")
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
            var bgTaskId: UIBackgroundTaskIdentifier = .invalid
            if !isRunningTests {
                bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "AutoAdvance") {
                    // An expired assertion MUST be ended — leaving it active
                    // gets the app terminated for background-task abuse.
                    self.logger.warning("Background task expired during auto-advance — releasing assertion")
                    if bgTaskId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskId)
                        bgTaskId = .invalid
                    }
                }
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
                bgTaskId = .invalid
            }
            #endif
        }
    }
    
    // MARK: - Error Handling & Stream Recovery
    
    private func handlePlaybackError(_ error: Error) {
        logger.error("Playback error: \(error.localizedDescription)")

        // Report to telemetry (fire-and-forget)
        onPlaybackError?(
            currentItem?.audioUrl,
            currentItem?.id,
            currentItem?.podcastUrl,
            error.localizedDescription,
            recoveryAttempts
        )
        
        guard !isRecovering, recoveryAttempts < Self.maxRecoveryAttempts else {
            logger.error("Recovery exhausted after \(self.recoveryAttempts) attempts")
            enterPlaybackFailedState()
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
            // Clear the buffering flag: nothing is connecting while offline,
            // and buffering outranks errorMessage in nowPlayingStatusSubtitle —
            // a stuck flag would pin "Connecting…" on CarPlay instead of the
            // offline message below.
            isBuffering = false
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

    /// Terminal failure: recovery exhausted. Stops the engine (hard rule: cap
    /// retries, then stop) and surfaces the failure on CarPlay/lock screen.
    /// Clears isBuffering — buffering outranks the error in
    /// nowPlayingStatusSubtitle, so a stuck flag would show "Connecting…"
    /// forever while nothing is connecting. Internal for unit testing.
    func enterPlaybackFailedState() {
        isBuffering = false
        errorMessage = "Playback failed. Check your connection."
        player.pause()
        updateNowPlayingPlaybackState()
        if let item = currentItem { updateNowPlayingInfo(for: item) }
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
            guard let self else { return }
            DispatchQueue.main.async {
                // A failed/offline item always reports an empty buffer — don't
                // let that re-pin "Connecting…" over an offline/error message.
                self.isBuffering = item.isPlaybackBufferEmpty && self.errorMessage == nil
                // Push rate=0 to CarPlay/lock screen so it doesn't show
                // a "playing" state while no audio is flowing
                self.updateNowPlayingPlaybackState()
                // Refresh ONLY the subtitle ("Connecting…" / normal) on buffer
                // changes — calling the full updateNowPlayingInfo here would spawn
                // a fresh artwork load on every buffer toggle (the load storm that
                // let stale images win the race).
                if var live = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    live[MPMediaItemPropertyArtist] = self.nowPlayingStatusSubtitle
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = live
                }
            }
        }
        itemObservers.append(bufferObserver)
        
        let likelyObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if item.isPlaybackLikelyToKeepUp {
                    self.isBuffering = false
                }
            }
        }
        itemObservers.append(likelyObserver)
        
        // Observe duration
        let durationObserver = playerItem.observe(\.duration) { [weak self] item, _ in
            guard let self, item.duration != .indefinite else { return }
            DispatchQueue.main.async {
                self.currentDuration = item.duration.seconds
            }
        }
        itemObservers.append(durationObserver)
        
        // Observe status: apply a deferred rate / re-kick on ready, recover on failure.
        let statusObserver = playerItem.observe(\.status) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // Ignore status changes for an item that's no longer current —
                // rapid auto-advance can leave a stale item briefly observed.
                guard item == self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    self.handleItemReadyToPlay()
                case .failed:
                    if let error = item.error { self.handlePlaybackError(error) }
                default:
                    break
                }
            }
        }
        itemObservers.append(statusObserver)
    }
    
    // MARK: - Current Item Change
    
    /// Decide whether a currentItem change signals genuine queue exhaustion vs.
    /// a mid-swap transient. During a play()/skip swap, `player.removeAllItems()`
    /// emits a transient `currentItem → nil` that Combine delivers on the main
    /// queue AFTER the swap and AFTER `isLoadingNewEpisode` resets; by then the
    /// LIVE `player.currentItem` is the newly-inserted item, so requiring the
    /// LIVE item to be nil rejects the stale transient while still firing on a
    /// real end-of-queue (where the live item is genuinely nil). This is the
    /// primary defense against a spurious start-of-episode completion now that
    /// `playEpisode` seeds `currentDuration` nonzero before the swap.
    static func isQueueExhaustion(liveCurrentItemIsNil: Bool, isPlaying: Bool, isLoadingNewEpisode: Bool, isAdvancingQueue: Bool) -> Bool {
        liveCurrentItemIsNil && isPlaying && !isLoadingNewEpisode && !isAdvancingQueue
    }

    private func handleCurrentItemChanged(_ item: AVPlayerItem?) {
        // Decide on the LIVE player.currentItem, not the stale published `item`
        // (see isQueueExhaustion). `item` is intentionally unused.
        _ = item
        if Self.isQueueExhaustion(
            liveCurrentItemIsNil: player.currentItem == nil,
            isPlaying: isPlaying,
            isLoadingNewEpisode: isLoadingNewEpisode,
            isAdvancingQueue: isAdvancingQueue
        ) {
            handlePlaybackCompleted()
        }
    }
    
    // MARK: - Queue Persistence
    
    /// Save queue + current item to UserDefaults.
    private func persistQueue() {
        WriteInstrumentation.shared.recordDefaultsWrite(source: "queue")
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
        // Persist the client event time so a force-quit offline
        // device reports its stale last-change time (not "now") on relaunch.
        defaults.set(playbackEventTime, forKey: Self.playbackEventTimeKey)
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
            // Restore the persisted event time. A restored item is
            // paused (user must tap play), so absent a stored time we default to
            // `.distantPast` — conservative: it loses to any newer server state.
            playbackEventTime = (defaults.object(forKey: Self.playbackEventTimeKey) as? Date) ?? .distantPast
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

    /// The playback rate to publish to Now Playing (CarPlay / lock screen).
    /// Real rate only when actually playing, not buffering, and with no
    /// error/offline message showing. `isPlaying` alone is not enough: it stays
    /// true through a paused-by-failure stall (which may never emit a rate=0 KVO),
    /// so the buffering/error flags are what force the screen to read paused —
    /// otherwise CarPlay shows a creeping "playing" progress bar under
    /// "No connection". Pure + static so the rule is unit-tested directly, without
    /// the MPNowPlayingInfoCenter round trip (whose NSNumber bridging makes the
    /// stored numeric type unreliable to read back).
    static func nowPlayingRate(isPlaying: Bool, isBuffering: Bool, errorMessage: String?, playbackRate: Float) -> Float {
        (isPlaying && !isBuffering && errorMessage == nil) ? playbackRate : 0.0
    }

    private func updateNowPlayingInfo(for item: QueueItem) {
        // Bump the load token so any in-flight artwork load from a previous call
        // (or a previous episode) is dropped when it completes.
        nowPlayingLoadToken &+= 1
        let token = nowPlayingLoadToken
        let itemId = item.id

        // Merge text + timing into the LIVE dict so we never clobber position/
        // rate written by updateNowPlayingProgress / updateNowPlayingPlaybackState.
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = nowPlayingStatusSubtitle
        info[MPMediaItemPropertyAlbumTitle] = item.podcastTitle
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Float(1.0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = Self.nowPlayingRate(isPlaying: isPlaying, isBuffering: isBuffering, errorMessage: errorMessage, playbackRate: playbackRate)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
        info[MPMediaItemPropertyPlaybackDuration] = currentDuration

        // On episode change, drop the previous episode's artwork so the lock
        // screen / Dynamic Island doesn't keep showing the old image while the
        // new one loads. The displayed chapter is episode-scoped state too —
        // a new episode must not inherit the outgoing one's chapter index.
        if currentArtworkItemId != itemId {
            info[MPMediaItemPropertyArtwork] = nil
            currentArtworkChapterIndex = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Skip the load if this episode's REAL artwork is already applied
        // (a placeholder should still be upgraded when a later update runs).
        if currentArtworkItemId == itemId, currentArtworkKind != .placeholder,
           info[MPMediaItemPropertyArtwork] != nil { return }

        let candidates = Self.artworkCandidates(for: item)

        // Seed the best already-cached artwork SYNCHRONOUSLY so the Now Playing
        // tile is never empty while the real image downloads. On a weak (not
        // absent) signal the async fetch below can hang for the request timeout;
        // without a seed CarPlay shows the system grey note the whole time. If
        // the episode's OWN art is already cached we're done — skip the fetch. A
        // logo/placeholder seed stays classified .placeholder so the async loop
        // can upgrade it to the episode art once that downloads.
        if let seed = Self.synchronousArtworkSeed(candidates: candidates,
                                                   cachedImageProvider: Self.cachedImageSynchronously) {
            let kind = Self.artworkKind(loadedUrl: seed.url, episodeArtworkUrl: item.artworkUrl)
            applyNowPlayingArtwork(seed.image, forItemId: itemId, token: token,
                                   kind: kind)
            if kind != .placeholder { return }   // episode's own art already applied — skip the fetch
        } else {
            #if os(iOS)
            applyNowPlayingArtwork(Self.nowPlayingPlaceholderArtwork,
                                   forItemId: itemId, token: token, kind: .placeholder)
            #endif
        }

        Task { [weak self] in
            guard let self else { return }
            for urlString in candidates {
                if let image = await self.loadImage(from: urlString) {
                    self.applyNowPlayingArtwork(image, forItemId: itemId, token: token,
                                                kind: Self.artworkKind(loadedUrl: urlString, episodeArtworkUrl: item.artworkUrl))
                    return
                }
            }
            // No candidate loadable (offline with a cold cache, or no URLs at
            // all): the synchronous seed above already applied a placeholder;
            // re-apply defensively in case the cached seed was evicted mid-load.
            #if os(iOS)
            self.applyNowPlayingArtwork(Self.nowPlayingPlaceholderArtwork,
                                        forItemId: itemId, token: token,
                                        kind: .placeholder)
            #endif
        }
    }

    /// Apply a loaded artwork image to the live now-playing dict, but only if
    /// the load is still current (newest token + same item). Centralizes the
    /// staleness guard so the async race is exercised by tests.
    ///
    /// `kind` has no default: this repo has a documented bug class where a
    /// defaulted parameter silently satisfies a call site with the wrong
    /// value (see SyncClient witness signatures) — every caller must state
    /// what it's applying rather than fall back to a guessed classification.
    private func applyNowPlayingArtwork(_ image: PlatformImage, forItemId itemId: String, token: Int, kind: NowPlayingArtworkKind) {
        // Drop the result if a newer update has happened or the item changed —
        // this is what stops a slow previous-episode load from winning the race.
        guard token == nowPlayingLoadToken, currentItem?.id == itemId else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        // Merge into the live dict so we keep title/timing the progress observer
        // may have written since the load started.
        var live = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        live[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = live
        currentArtworkItemId = itemId
        currentArtworkKind = kind
        // os.Logger's `.auto` privacy defaults Bool interpolations to public but
        // String interpolations to private — the old `placeholder=\(isPlaceholder)`
        // (a Bool) logged in the clear; a naive `\(String(describing: kind))` would
        // render `kind=<private>` on device/release builds, silently degrading the
        // one marker sim-verify reads to diagnose artwork-flash regressions.
        logger.debug("⟦NOWPLAYING⟧ artwork applied for \(itemId) kind=\(String(describing: kind), privacy: .public)")
    }

    /// Monotonic counter identifying each chapter-artwork RESOLUTION attempt.
    /// Captured before `ChapterArtworkStore.image(forKey:)` runs, checked
    /// after it returns — the same bump-before/check-after shape
    /// `nowPlayingLoadToken` uses to protect `applyNowPlayingArtwork`'s
    /// async episode-art fetch.
    ///
    /// PRECONDITION, honestly stated: `image(forKey:)` has no `await` today,
    /// so nothing can bump this counter between the bump and the check —
    /// this guard cannot currently reject anything. It exists so that IF
    /// that lookup becomes async (its sibling `ChapterArtworkStore.store()`
    /// already documents needing to run off-main-thread for the identical
    /// reason), a call whose resolution is outlived by a newer one starts
    /// being dropped automatically, with no further change needed here. It
    /// does NOT protect against a caller wrapping the CALL to
    /// `applyChapterArtwork` itself in async indirection (e.g. a detached
    /// Task around a slow extraction) — that delay happens before this
    /// counter is ever touched, so it must be guarded at the call site
    /// instead (don't invoke this for a chapter that's no longer current).
    private var chapterArtworkGeneration = 0

    /// Show artwork for the chapter now playing, or revert to episode art
    /// when the chapter has none.
    ///
    /// Driven directly by `ChapterCoordinator.onChapterChanged`.
    /// Deliberately NOT keyed off chapter titles: a title-equality heuristic
    /// couples lock-screen chapter artwork to the "Publish Chapter Titles"
    /// setting, so disabling titles silently disables chapter artwork too.
    ///
    /// `forItemId` must identify the episode the CHAPTER ITSELF belongs to —
    /// the episode whose chapter list produced `key` — and it must be derived
    /// from state the caller owns about that chapter (in production,
    /// `ChapterCoordinator.loadedItemId`), never re-read from a live
    /// "who is playing right now" source.
    ///
    /// That distinction is the whole guard, not a stylistic preference. A
    /// caller that passes `currentItem?.id` makes this check a TAUTOLOGY:
    /// the comparison below re-reads the very same property, both reads land
    /// in one synchronous MainActor turn with no suspension between them, and
    /// the guard can then never reject anything. This branch has already been
    /// dead once for exactly that reason — see
    /// `ChapterCoordinator.attach(to:)`'s `chapterBoundaryHook` for the
    /// `playEpisode` window (`currentItem` advances to B while the outgoing
    /// episode's clock still drives position ticks against A's chapters) that
    /// slipped through while it was.
    ///
    /// Passed an id the caller genuinely owns, this rejects a call carrying a
    /// PREVIOUS episode's key after the user has switched episodes: without
    /// it, that call would resolve the old episode's image, bump
    /// `nowPlayingLoadToken` (killing the new episode's own in-flight
    /// artwork fetch), and apply the wrong episode's chapter art to the new
    /// episode's Now Playing entry. Unlike `chapterArtworkGeneration` above,
    /// this check is live today — a plain equality comparison needs no
    /// `await` to work — and
    /// `ChapterPlaybackWiringTests
    /// .test_boundaryCrossing_afterCurrentItemAdvanced_doesNotPaintStaleChapterArtOntoTheNewEpisode`
    /// pins it through the real production wiring rather than by hand-passing
    /// a `forItemId` shape production cannot emit.
    ///
    /// Staleness by chapter index is deliberately NOT checked. An
    /// index-magnitude ratchet (`displayed > chapterIndex → drop`) looks like
    /// it would guard against a slow, late-arriving image from an earlier
    /// chapter — but it cannot distinguish that from a user legitimately
    /// scrubbing backward, which ALSO presents as a lower index:
    /// `ChapterCoordinator.updatePosition` recomputes the current chapter
    /// fresh from position on every call, so a backward seek's
    /// `chapterIndex` is exactly as "current" as a forward one. Rejecting on
    /// magnitude would leave a backward seek permanently stuck showing the
    /// highest chapter's art ever reached, for the rest of the episode.
    func applyChapterArtwork(key: String?, chapterIndex: Int?, forItemId itemId: String?) {
        guard let itemId, currentItem?.id == itemId else {
            // No target item was given, or it no longer matches who's
            // playing (a delayed call for an episode we've since switched
            // away from) — reject before doing any work. Only clear the
            // chapter index when there's truly no current item; a
            // mismatched-but-real current item has its OWN chapter state
            // that this stale call must not touch.
            if currentItem == nil {
                currentArtworkChapterIndex = nil
            }
            logger.debug("⟦NOWPLAYING⟧ dropped cross-episode chapter artwork for \(itemId ?? "nil") current=\(self.currentItem?.id ?? "nil")")
            return
        }

        guard let key, let chapterIndex else {
            // No art for this chapter — fall back to the episode's own artwork.
            currentArtworkChapterIndex = nil
            if currentArtworkKind == .chapter, let item = currentItem {
                // updateNowPlayingInfo's artwork upgrade guard skips the
                // reload whenever currentArtworkKind != .placeholder AND
                // artwork is already present — exactly the state chapter art
                // leaves us in. Reset the kind first, or this "restore" is a
                // silent no-op and the chapter image stays stuck on screen.
                currentArtworkKind = .placeholder
                updateNowPlayingInfo(for: item)
            }
            return
        }

        chapterArtworkGeneration &+= 1
        let generation = chapterArtworkGeneration

        guard let image = ChapterArtworkStore.image(forKey: key) else {
            // Evicted from cache — leave existing artwork alone rather than
            // blanking it; the key is re-derivable, so this just costs a
            // future re-extract, not a permanent loss.
            logger.debug("⟦NOWPLAYING⟧ chapter artwork unresolvable key=\(key)")
            return
        }

        guard generation == chapterArtworkGeneration, currentItem?.id == itemId else {
            logger.debug("⟦NOWPLAYING⟧ dropped stale chapter artwork resolution idx=\(chapterIndex)")
            return
        }

        currentArtworkChapterIndex = chapterIndex
        nowPlayingLoadToken &+= 1
        applyNowPlayingArtwork(image, forItemId: itemId, token: nowPlayingLoadToken, kind: .chapter)
    }

    /// Ordered artwork URL candidates for Now Playing: episode art first, then
    /// the podcast logo. Deduped, nils dropped. Internal for unit testing.
    static func artworkCandidates(for item: QueueItem) -> [String] {
        var seen = Set<String>()
        return [item.artworkUrl, item.fallbackArtworkUrl]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    /// First candidate URL whose image is already cached (resolved synchronously
    /// by `cachedImageProvider`), returned with the image — or nil when none is
    /// cached (the caller then shows the branded placeholder). Pure + injectable
    /// so the seed choice is unit-tested without MPNowPlayingInfoCenter or disk
    /// I/O. Candidate order is the caller's (episode art before podcast logo).
    static func synchronousArtworkSeed(
        candidates: [String],
        cachedImageProvider: (String) -> PlatformImage?
    ) -> (image: PlatformImage, url: String)? {
        for urlString in candidates {
            if let image = cachedImageProvider(urlString) {
                return (image, urlString)
            }
        }
        return nil
    }

    /// Classify a loaded artwork image. Chapter art is identified by the
    /// `chapterart:` cache-key namespace (`ChapterArtworkStore.cacheKey`)
    /// rather than a URL — it never equals `episodeArtworkUrl`, so that check
    /// must run first or chapter art would fall through and be misclassified
    /// as an upgradeable placeholder. Otherwise, only the episode's OWN art is
    /// "real"; the podcast-logo fallback (or a nil episode-art URL) stays a
    /// placeholder so a later update can still upgrade to the episode art
    /// once it downloads.
    static func artworkKind(loadedUrl: String, episodeArtworkUrl: String?) -> NowPlayingArtworkKind {
        if loadedUrl.hasPrefix("chapterart:") { return .chapter }
        return loadedUrl == episodeArtworkUrl ? .episode : .placeholder
    }

    /// Synchronous cache probe (memory NSCache, then disk) used to seed Now
    /// Playing artwork immediately, before the async network fetch runs.
    static func cachedImageSynchronously(_ urlString: String) -> PlatformImage? {
        let key = urlString as NSString
        if let mem = ImageCacheStore.shared.cache.object(forKey: key) { return mem }
        return ImageCacheStore.shared.loadFromDisk(key: urlString)
    }

    /// Bounded request timeout (seconds) for Now Playing artwork fetches: a weak
    /// (not absent) signal must not hang the fetch for the OS default ~60s while
    /// it holds the artwork load token. The synchronous seed covers the visual
    /// gap; this just bounds the straggler.
    static let artworkFetchTimeout: TimeInterval = 8

    /// URLRequest for an artwork fetch, bounded by `artworkFetchTimeout`.
    static func artworkRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = artworkFetchTimeout
        return request
    }

    #if os(iOS)
    /// Generated placeholder for the Now Playing screen (mic icon on a tinted
    /// square) — mirrors CarPlayService's list placeholder at full-screen size,
    /// so CarPlay never shows the system's generic grey music note.
    static let nowPlayingPlaceholderArtwork: UIImage = {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.secondarySystemBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 240, weight: .medium)
            if let icon = UIImage(systemName: "mic.fill", withConfiguration: iconConfig) {
                let origin = CGPoint(x: (size.width - icon.size.width) / 2,
                                     y: (size.height - icon.size.height) / 2)
                icon.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
                    .draw(at: origin)
            }
        }
    }()
    #endif
    
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = Self.nowPlayingRate(isPlaying: isPlaying, isBuffering: isBuffering, errorMessage: errorMessage, playbackRate: playbackRate)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func clearNowPlayingInfo() {
        nowPlayingLoadToken &+= 1   // drop any in-flight artwork load
        currentArtworkItemId = nil
        currentArtworkChapterIndex = nil
        // No artwork is applied once cleared, so the reset state is .placeholder
        // (upgradeable) rather than .episode — matches the stored property's
        // own default. Unobservable today: currentArtworkItemId is also nil
        // here, so the compound guard in updateNowPlayingInfo (which requires
        // currentArtworkItemId == itemId) never reaches this value regardless.
        currentArtworkKind = .placeholder
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
            let (data, _) = try await URLSession.shared.data(for: Self.artworkRequest(for: url))
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
            let (data, _) = try await URLSession.shared.data(for: Self.artworkRequest(for: url))
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

    /// Test seam: read/set the deferred playback rate (see `pendingPlaybackRate`).
    var testablePendingPlaybackRate: Float? {
        get { pendingPlaybackRate }
        set { pendingPlaybackRate = newValue }
    }

    /// Test seam: run the `.readyToPlay` handler (applies any deferred rate).
    func testableHandleItemReadyToPlay() {
        handleItemReadyToPlay()
    }

    /// Test seam: drive the real now-playing metadata update.
    func testableUpdateNowPlayingInfo(for item: QueueItem) {
        updateNowPlayingInfo(for: item)
    }

    /// Test seam: the current now-playing load token (captured by artwork loads).
    var testableNowPlayingLoadToken: Int { nowPlayingLoadToken }

    /// Test seam: the episode id whose artwork is currently applied.
    var testableCurrentArtworkItemId: String? { currentArtworkItemId }

    /// Test seam: run the real artwork-apply path (with its staleness guard) as
    /// if an async image load had just completed. Defaults to `.episode` to
    /// reproduce the pre-refactor default (`isPlaceholder: Bool = false`,
    /// i.e. "real art") for existing callers that don't care which kind.
    func testableApplyNowPlayingArtwork(_ image: PlatformImage, forItemId itemId: String, token: Int, kind: NowPlayingArtworkKind = .episode) {
        applyNowPlayingArtwork(image, forItemId: itemId, token: token, kind: kind)
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

        if let outgoing = currentItem, outgoing.id != next.id {
            onItemWillChange?(outgoing)
        }

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

    // MARK: - Audio route changes (pause-on-unplug)

#if os(iOS)
    /// Pure decision: should an output-route change pause playback?
    ///
    /// `.oldDeviceUnavailable` is the only reason iOS fires when a route genuinely
    /// disappears (headphones pulled, Bluetooth/AirPlay device dropped). A legitimate
    /// output switch (headphones → AirPlay, one BT device → another) fires a different
    /// reason, so this returns `false` for every reason except `.oldDeviceUnavailable`
    /// and legitimate switches never pause.
    ///
    /// Guarded `#if os(iOS)`: `AVAudioSession.RouteChangeReason` is unavailable on macOS,
    /// and this file compiles into the `YourPodsMac` target (same pattern as every other
    /// `AVAudioSession` use in this file).
    static func routeChangeShouldPause(reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .oldDeviceUnavailable
    }

    /// Testable core for route-change handling: pause only when the output route
    /// disappeared *while playing*. Never auto-resumes (matches Apple HIG / Apple Music /
    /// Overcast / Pocket Casts) — no `wasPlaying` capture, no resume path.
    /// - Returns: whether it paused.
    @discardableResult
    func testableHandleRouteChange(reason: AVAudioSession.RouteChangeReason) -> Bool {
        guard AudioManager.routeChangeShouldPause(reason: reason), isPlaying else {
            return false
        }
        logger.info("Output route disappeared (reason: \(reason.rawValue)) — pausing")
        pause()
        return true
    }
#endif

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

    /// Parses an `AVAudioSession.routeChangeNotification` and delegates to the
    /// testable core. Mirrors `handleAudioSessionInterruption(_:)`; already inside
    /// this file's `#if os(iOS)` region.
    private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        testableHandleRouteChange(reason: reason)
    }
    #endif
}

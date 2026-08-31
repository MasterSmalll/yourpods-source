import Foundation
import AVFoundation
import MediaPlayer
import WatchKit
import os
import CoreMedia

/// Hands-free bookmark captured from the watch while a podcast is playing.
struct CapturedMoment: Codable, Identifiable {
    let id: UUID
    let episodeId: String
    let podcastTitle: String
    let episodeTitle: String
    let timestampSec: Double
    let capturedAt: Date
}

/// Persistent audio manager for the watch app.
/// Owns the AVPlayer and survives view lifecycle — the key fix for background playback.
/// Injected at the app root via @StateObject / .environmentObject().
class WatchAudioManager: NSObject, ObservableObject {
    
    // MARK: - Singleton
    /// Singleton — survives SwiftUI App struct recreation during background wakes.
    /// Without this, watchOS creates new managers on background wake while
    /// WCSession.delegate still points to the old instance → split-brain freeze.
    static let shared = WatchAudioManager()
    
    // MARK: - Published State
    
    @Published private(set) var currentEpisode: WatchEpisode?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var playbackSource: PlaybackSource = .none
    @Published private(set) var statusText: String = "No episode"
    @Published private(set) var hasSetupAudio = false
    @Published private(set) var capturedMoments: [CapturedMoment] = []

    /// Watch-local speed override. nil = follow the phone's synced speed.
    @Published private(set) var speedOverride: Double? =
        UserDefaults.standard.object(forKey: "watchSpeedOverride") as? Double

    /// Active sleep timer, if any. nil = no timer running.
    @Published private(set) var sleepTimer: WatchSleepTimerModel? = nil

    // MARK: - Dependencies
    
    /// Set by YourPodsWatchApp after both managers are initialized.
    weak var sessionManager: WatchSessionManager?
    
    // MARK: - Private
    
    private var player: AVPlayer?
    private var timer: Timer?
    private var lastSyncTime = Date()
    private var bufferStallStart: Date?
    private let maxBufferStallSeconds: TimeInterval = 30
    private var remoteCommandsConfigured = false
    private var lastPublishedProgress: Double?
    private var lastNowPlayingUpdate: Date?
    private var cachedArtworkUrl: String?
    private var artworkFetchTask: Task<Void, Never>?
    private var endOfTrackObserver: Any?
    private static let capturedMomentsKey = "watch_captured_moments_v1"
    private static let capturedMomentsLimit = 200

    /// Observers for background/foreground lifecycle notifications.
    private var backgroundObserver: Any?
    private var foregroundObserver: Any?

    /// Set by the lifecycle observers. play()/auto-advance in the background
    /// must NOT start the 1Hz UI timer — it would run for the rest of the
    /// session, burning battery with the screen off.
    private var isInBackground = false

    private let logger = Logger(subsystem: "com.yourpods", category: "WatchAudio")

    /// Check if battery is too low for streaming
    private var isBatteryTooLow: Bool {
        let device = WKInterfaceDevice.current()
        return device.batteryLevel >= 0 && device.batteryLevel < 0.10
    }

    override init() {
        super.init()
        capturedMoments = Self.loadCapturedMoments()
        // Enable once — the computed property above is a pure read. Re-enabling
        // on every check was redundant (and each call briefly wakes the battery
        // sensor on watchOS).
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        setupLifecycleObservers()
    }

    private static func loadCapturedMoments() -> [CapturedMoment] {
        guard let data = UserDefaults.standard.data(forKey: capturedMomentsKey),
              let decoded = try? JSONDecoder().decode([CapturedMoment].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistCapturedMoments() {
        guard let data = try? JSONEncoder().encode(capturedMoments) else {
            logger.error("Failed to encode captured podcast moments")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.capturedMomentsKey)
    }

    /// Capture the current podcast/episode and exact playback position without
    /// seeking or interrupting playback. Used by AirPods previous-track gesture.
    @discardableResult
    func captureCurrentMoment() -> Bool {
        guard let episode = currentEpisode, let player else { return false }

        let timestamp = CMTimeGetSeconds(player.currentTime())
        guard timestamp.isFinite, timestamp >= 0 else { return false }

        let moment = CapturedMoment(
            id: UUID(),
            episodeId: episode.id,
            podcastTitle: episode.podcastTitle ?? episode.album,
            episodeTitle: episode.title,
            timestampSec: timestamp,
            capturedAt: Date()
        )

        capturedMoments.append(moment)
        if capturedMoments.count > Self.capturedMomentsLimit {
            capturedMoments.removeFirst(capturedMoments.count - Self.capturedMomentsLimit)
        }
        persistCapturedMoments()

        // Immediate confirmation while running; playback is untouched.
        WKInterfaceDevice.current().play(.success)
        logger.info("Captured podcast moment at \(Int(timestamp))s in \(episode.title)")
        return true
    }
    
    deinit {
        timer?.invalidate()
        artworkFetchTask?.cancel()
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let bg = backgroundObserver { NotificationCenter.default.removeObserver(bg) }
        if let fg = foregroundObserver { NotificationCenter.default.removeObserver(fg) }
    }
    
    // MARK: - Lifecycle Observers (CAROUSEL Watchdog Fix)
    
    /// Observe background/foreground transitions to manage the progress timer.
    ///
    /// CAROUSEL FIX: When the app is suspended, timer fires accumulate.
    /// On resume, they all fire in a burst — overwhelming the main thread
    /// and triggering a watchdog kill. By suspending the timer on background
    /// entry and resuming on foreground, we eliminate the burst.
    private func setupLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: WKApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isInBackground = true
            self.logger.debug("App entering background — suspending progress timer")
            self.stopTimer()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: WKApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isInBackground = false
            if self.isPlaying {
                self.logger.debug("App returning to foreground — resuming progress timer")
                self.startTimer()
                self.updateProgress()  // Sync progress immediately on resume
            }
        }
    }
    
    // MARK: - Speed

    /// Resolved playback speed: watch-local override wins, else the phone-synced speed.
    var currentEffectiveSpeed: Double {
        WatchSpeedPolicy.effectiveSpeed(override: speedOverride,
                                        phoneSpeed: sessionManager?.playbackSpeed ?? 1.0)
    }

    func setSpeedOverride(_ speed: Double?) {
        speedOverride = speed
        if let speed { UserDefaults.standard.set(speed, forKey: "watchSpeedOverride") }
        else { UserDefaults.standard.removeObject(forKey: "watchSpeedOverride") }
        if isPlaying { player?.rate = Float(currentEffectiveSpeed) }
    }

    // MARK: - Sleep Timer

    func setSleepTimer(_ timer: WatchSleepTimerModel?) {
        sleepTimer = timer
        logger.info("Sleep timer set: \(String(describing: timer))")
    }

    // MARK: - Play

    func play(episode: WatchEpisode) {
        statusText = "Setting up..."
        var urlToPlay: URL?
        
        // 1. Try Local File
        if let localPath = episode.localPath {
            let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = docURL.appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                playbackSource = .local
                urlToPlay = fileURL
            }
        }
        
        // 2. Fallback to Stream
        if urlToPlay == nil {
            if let streamUrl = episode.streamUrl, let remote = URL(string: streamUrl) {
                if isBatteryTooLow {
                    playbackSource = .none
                    statusText = "Battery too low to stream"
                    return
                }
                playbackSource = .streaming
                urlToPlay = remote
            } else {
                playbackSource = .none
                statusText = "No audio source"
                return
            }
        }
        
        guard let url = urlToPlay else { return }

        // Stop existing playback
        stopTimer()
        player?.pause()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                // watchOS requires async activation for .longFormAudio: it selects
                // (or prompts for) the mandatory Bluetooth route. Synchronous
                // setActive(true) just throws when no route is connected.
                _ = try await session.activate(options: [])
                self.beginPlayback(of: episode, at: url)
            } catch {
                self.playbackSource = .none
                self.statusText = "Connect Bluetooth headphones and try again"
                self.logger.error("Audio session activation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Player construction after the audio session is active. Main actor.
    private func beginPlayback(of episode: WatchEpisode, at url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.rate = Float(currentEffectiveSpeed)
        player?.play()
        currentEpisode = episode
        isPlaying = true
        hasSetupAudio = true
        startTimer()
        setupEndOfTrackObserver()

        if episode.position > 0 {
            let targetTime = CMTime(seconds: Double(episode.position), preferredTimescale: 1)
            player?.seek(to: targetTime)
            progress = Double(episode.position)
        }

        statusText = playbackSource == .streaming ? "Streaming..." : "Playing"
        updateNowPlayingInfo()
        setupRemoteCommands()
        logger.info("Playback started: \(episode.title) (\(self.playbackSource == .local ? "local" : "streaming"))")

        WatchComplicationRefresher.update { data in
            data.nowPlayingTitle = episode.title
            data.nowPlayingPodcast = episode.album
            data.isPlaying = true
        }
    }

    // MARK: - Toggle Play/Pause

    func togglePlayPause() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing {
            pausePlayback()
        } else {
            p.rate = Float(currentEffectiveSpeed)
            p.play()
            isPlaying = true
            statusText = playbackSource == .streaming ? "Streaming..." : "Playing"
            updateNowPlayingPlaybackState()

            WatchComplicationRefresher.update { data in
                data.isPlaying = self.isPlaying
            }
        }
    }

    /// Pause playback — timeControlStatus-INDEPENDENT (unconditional: pauses
    /// whatever is currently loaded; never branches on `AVPlayer.timeControlStatus`).
    /// Extracted from `togglePlayPause()`'s pause branch (parity — same player
    /// pause, isPlaying flip, durable position push, now-playing + complication
    /// update) so `timerFired()`'s sleep-timer expiry can call it directly
    /// instead of routing through `togglePlayPause()`.
    ///
    /// W34: `togglePlayPause()`'s branch condition (`p.timeControlStatus == .playing`)
    /// is FALSE during a buffer stall even though `isPlaying` is still true —
    /// the old code took the "else" (resume) branch when the sleep timer expired
    /// mid-stall, silently defeating the timer instead of pausing. Calling this
    /// helper directly (guarded by `isPlaying`, not `timeControlStatus`) fixes
    /// that without touching `togglePlayPause()`'s own branch condition, so
    /// behavior for manual taps is unchanged.
    private func pausePlayback() {
        guard let p = player else { return }
        p.pause()
        isPlaying = false
        statusText = "Paused"
        // Durably push the final position to the phone so resume works after a pause.
        let secs = CMTimeGetSeconds(p.currentTime())
        if let episode = currentEpisode, secs.isFinite, secs > 0 {
            sessionManager?.sendProgress(episodeId: episode.id, position: Int(secs))
        }
        updateNowPlayingPlaybackState()

        WatchComplicationRefresher.update { data in
            data.isPlaying = self.isPlaying
        }
    }

    // MARK: - Seek
    
    func seek(by seconds: Double) {
        guard let p = player else { return }
        let current = p.currentTime()
        let newTime = CMTimeAdd(current, CMTimeMakeWithSeconds(seconds, preferredTimescale: 1))
        p.seek(to: newTime)
        updateProgress()
    }
    
    func seek(to seconds: Double) {
        guard let p = player else { return }
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 1)
        p.seek(to: targetTime)
        updateProgress()
    }
    
    // MARK: - Stop
    
    func stop() {
        // Capture and push the final position BEFORE teardown, while currentTime() is still valid.
        if let p = player, let episode = currentEpisode {
            let secs = CMTimeGetSeconds(p.currentTime())
            if secs.isFinite, secs > 0 {
                sessionManager?.sendProgress(episodeId: episode.id, position: Int(secs))
            }
        }
        player?.pause()
        player = nil
        stopTimer()
        currentEpisode = nil
        isPlaying = false
        hasSetupAudio = false
        progress = 0
        playbackSource = .none
        statusText = "No episode"
        clearNowPlayingInfo()
        
        // Reset freeze-fix tracking state
        remoteCommandsConfigured = false
        lastPublishedProgress = nil
        lastNowPlayingUpdate = nil
        cachedArtworkUrl = nil
        bufferStallStart = nil
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfTrackObserver = nil
        }

        WatchComplicationRefresher.update { data in
            data.nowPlayingTitle = nil
            data.nowPlayingPodcast = nil
            data.isPlaying = false
        }

        // CAROUSEL FIX: Deactivate audio session when nothing is playing.
        // An active audio session without playback keeps watchOS from suspending
        // the app → eventual watchdog kill.
        deactivateAudioSession()
    }

    /// Deactivate the AVAudioSession when nothing is playing.
    /// This lets watchOS fully suspend the app and prevents watchdog enforcement.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            logger.debug("Audio session deactivated")
        } catch {
            // Log but don't crash — deactivation failure is non-fatal
            logger.debug("Audio session deactivation failed (non-fatal): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Progress Timer
    
    private func startTimer() {
        stopTimer()
        guard !isInBackground else {
            logger.debug("Skipping timer start — app is in background")
            return   // foreground observer restarts it
        }
        // Freeze Fix #2: Reduced from 0.5s → 1.0s to cut CPU/UI pressure in half
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerFired()
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func timerFired() {
        if let sleepTimer, sleepTimer.isExpired(at: Date()) {
            logger.info("Sleep timer expired — pausing")
            self.sleepTimer = nil
            // W34: call pausePlayback() directly, NOT togglePlayPause() — during
            // a buffer stall, timeControlStatus != .playing even though isPlaying
            // is true, so togglePlayPause()'s branch would RESUME instead of
            // pause here. pausePlayback() is timeControlStatus-independent.
            if isPlaying { pausePlayback() }   // pauses + pushes position durably
            return
        }

        guard let p = player, let episode = currentEpisode else { return }
        
        let rawProgress = CMTimeGetSeconds(p.currentTime())
        
        // Freeze Fix #2: Only publish @Published progress when it changes ≥1s
        // This prevents redundant SwiftUI view re-renders across the entire app
        let shouldPublish: Bool
        if let lastPub = lastPublishedProgress {
            shouldPublish = abs(rawProgress - lastPub) >= 1.0
        } else {
            shouldPublish = true
        }
        
        if shouldPublish {
            progress = rawProgress
            lastPublishedProgress = rawProgress
        }
        
        // Periodic Progress Sync to Phone
        let syncInterval = sessionManager?.positionSyncInterval ?? 30.0
        if Date().timeIntervalSince(lastSyncTime) >= syncInterval {
            sessionManager?.sendProgress(episodeId: episode.id, position: Int(rawProgress))
            lastSyncTime = Date()
            
            // Update local WatchEpisode position for persistence
            if let sm = sessionManager,
               let index = sm.episodes.firstIndex(where: { $0.id == episode.id }) {
                sm.episodes[index].position = Int(rawProgress)
            }
        }
        
        // Status update
        if let error = p.currentItem?.error {
            logger.error("Player item failed: \(error.localizedDescription)")
            let message = "Error: \(error.localizedDescription)"
            bufferStallStart = nil
            stop()                    // releases player, timer, audio session
            statusText = message      // stop() resets statusText — restore the error for the UI
            return
        } else if p.status == .failed {
            logger.error("Player failed")
            bufferStallStart = nil
            stop()
            statusText = "Playback failed"
            return
        } else if p.timeControlStatus == .playing {
            bufferStallStart = nil
            if shouldPublish {
                let mins = Int(rawProgress) / 60
                let secs = Int(rawProgress) % 60
                let newStatus = playbackSource == .streaming
                ? "Streaming \(mins):\(String(format: "%02d", secs))"
                : "Playing \(mins):\(String(format: "%02d", secs))"
                // CAROUSEL FIX: Only publish when string actually changes.
                // Avoids redundant @Published writes that invalidate every
                // observing SwiftUI view each second.
                if newStatus != statusText {
                    statusText = newStatus
                }
            }
        } else if p.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            // Buffer stall detection
            if bufferStallStart == nil {
                bufferStallStart = Date()
            } else if let start = bufferStallStart,
                      Date().timeIntervalSince(start) > maxBufferStallSeconds {
                p.pause()
                isPlaying = false
                statusText = "Stopped: buffering too long"
                bufferStallStart = nil
                logger.warning("Buffer stall timeout — stopping playback")
                return
            }
            statusText = "Buffering..."
        }
        
        // Freeze Fix #3: Throttle now-playing info updates to ~5s intervals
        if let lastUpdate = lastNowPlayingUpdate,
           Date().timeIntervalSince(lastUpdate) < 5.0 {
            // Skip this update cycle
        } else {
            updateNowPlayingProgress()
            lastNowPlayingUpdate = Date()
        }
    }
    
    private func updateProgress() {
        if let p = player {
            progress = CMTimeGetSeconds(p.currentTime())
        }
    }
    
    // MARK: - Auto-Advance (End of Track)
    
    private func setupEndOfTrackObserver() {
        // Remove previous observer
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        endOfTrackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handleTrackEnd(reason: .finished)
        }
    }

    /// Whether a track ended because it played to completion, or because the
    /// user skipped it. Only `.finished` counts as a real completion — it's
    /// the only case that marks the episode played on the phone.
    enum TrackEndReason { case finished, skipped }

    private func handleTrackEnd(reason: TrackEndReason) {
        guard let ended = currentEpisode else {
            logger.debug("Track end with no current episode — stopping")
            stop()
            return
        }
        logger.info("Track end (\(reason == .finished ? "finished" : "skipped")): \(ended.title)")

        // Snapshot the queue BEFORE any mutation — markAsPlayed removes the
        // episode locally, which would break next-episode selection.
        let queueIds = sessionManager?.episodes.map(\.id) ?? []
        let nextId = WatchAdvancePlanner.next(after: ended.id, inQueue: queueIds)
        let nextEpisode = nextId.flatMap { id in sessionManager?.episodes.first(where: { $0.id == id }) }

        switch reason {
        case .finished:
            // Real completion: durable final position + real mark-played on the phone.
            sessionManager?.sendProgress(episodeId: ended.id, position: ended.duration)
            sessionManager?.markAsPlayed(for: ended.id)
        case .skipped:
            // A skip is NOT a finish — push the actual position only.
            if let p = player {
                let secs = CMTimeGetSeconds(p.currentTime())
                if secs.isFinite, secs > 0 {
                    sessionManager?.sendProgress(episodeId: ended.id, position: Int(secs))
                }
            }
        }

        // Sleep timer: "end of episode" stops here instead of advancing, and a
        // duration timer that lapsed while backgrounded (the 1Hz timer is
        // foreground-only) stops playback at the next track boundary.
        if sleepTimer?.stopsAtTrackEnd == true || (sleepTimer?.isExpired(at: Date()) ?? false) {
            sleepTimer = nil
            logger.info("Sleep timer — stopping at track end")
            stop()
            return
        }

        if let nextEpisode {
            logger.info("Auto-advancing to: \(nextEpisode.title)")
            play(episode: nextEpisode)
        } else {
            logger.info("No next episode — stopping playback")
            stop()
        }
    }
    
    // MARK: - MPNowPlayingInfoCenter (Watch Lock Screen / Dock)
    
    private func updateNowPlayingInfo() {
        guard let episode = currentEpisode else { return }
        
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.album,
            MPMediaItemPropertyAlbumTitle: episode.album,
            MPNowPlayingInfoPropertyPlaybackRate: player?.rate ?? 1.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Float(1.0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPMediaItemPropertyPlaybackDuration: TimeInterval(episode.duration),
        ]
        
        // Freeze Fix #4: Only fetch artwork if URL changed (cache by URL)
        // CAROUSEL FIX: Cancel previous artwork fetch to prevent unbounded
        // concurrent network Tasks when artwork URL changes rapidly.
        if let artUri = episode.artUri, artUri != cachedArtworkUrl, let url = URL(string: artUri) {
            cachedArtworkUrl = artUri
            artworkFetchTask?.cancel()
            artworkFetchTask = Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled else { return }
                    // 256px is ample for the watch now-playing artwork slot; bounded
                    // decode avoids the widget-OOM crash class on a 3000px cover.
                    if let cg = WatchArtworkDownsampler.downsample(data: data, maxPixelSize: 256) {
                        let image = UIImage(cgImage: cg)
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        info[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    } else {
                        logger.debug("Artwork downsample returned nil for \(url.absoluteString)")
                    }
                } catch {
                    if !Task.isCancelled {
                        logger.debug("Failed to load artwork: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingUpdate = Date()
    }
    
    private func updateNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? (player?.rate ?? 1.0) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? (player?.rate ?? 1.0) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // MARK: - MPRemoteCommandCenter (AirPods, Watch Controls)
    
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Freeze Fix #1: Guard against accumulating targets on every play().
        // removeTarget(nil) clears ALL existing closures before re-adding.
        // Without this, each play() call leaks closures that are never freed,
        // linearly increasing memory usage until watchOS kills the app.
        if remoteCommandsConfigured {
            return  // Already set up — skip to avoid re-registration entirely
        }
        
        // Clear any stale targets from a previous session
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        // Skip-interval parity: synced from the iPhone's settings via
        // sessionManager. NOTE accepted limitation — preferredIntervals is only
        // read here, gated by remoteCommandsConfigured above, so a mid-session
        // interval change from the iPhone applies to the remote command targets
        // on next launch, not live. The seek(by:) calls always read the current
        // sessionManager value, so in-app buttons stay live.
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: sessionManager?.skipBackwardSeconds ?? 15)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -Double(self?.sessionManager?.skipBackwardSeconds ?? 15))
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: sessionManager?.skipForwardSeconds ?? 30)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: Double(self?.sessionManager?.skipForwardSeconds ?? 30))
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleTrackEnd(reason: .skipped)
            return .success
        }

        // AirPods triple-press is Previous Track by default. Repurpose it as a
        // hands-free podcast marker. We intentionally do not seek or change track.
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard self?.captureCurrentMoment() == true else {
                return .commandFailed
            }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: posEvent.positionTime)
            return .success
        }
        
        remoteCommandsConfigured = true
    }
}

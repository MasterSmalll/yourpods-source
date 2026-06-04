import Foundation
import AVFoundation
import MediaPlayer
import WatchKit
import os
import CoreMedia

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
    
    /// CAROUSEL FIX: Extended runtime session for background audio playback.
    /// Without this, watchOS suspends the app ~30s after entering background,
    /// even with the `audio` background mode. The extended session signals to
    /// the system that the app has ongoing audio work.
    private var extendedSession: WKExtendedRuntimeSession?
    
    /// Observers for background/foreground lifecycle notifications.
    private var backgroundObserver: Any?
    private var foregroundObserver: Any?
    
    private let logger = Logger(subsystem: "com.yourpods", category: "WatchAudio")
    
    /// Check if battery is too low for streaming
    private var isBatteryTooLow: Bool {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        return device.batteryLevel >= 0 && device.batteryLevel < 0.10
    }
    
    override init() {
        super.init()
        setupLifecycleObservers()
    }
    
    deinit {
        timer?.invalidate()
        artworkFetchTask?.cancel()
        extendedSession?.invalidate()
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
            self.logger.debug("App entering background — suspending progress timer")
            self.stopTimer()
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: WKApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isPlaying {
                self.logger.debug("App returning to foreground — resuming progress timer")
                self.startTimer()
                self.updateProgress()  // Sync progress immediately on resume
            }
        }
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
        extendedSession?.invalidate()
        player?.pause()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playback,
                    mode: .default,
                    policy: .longFormAudio
                )
                try AVAudioSession.sharedInstance().setActive(true)
                
                DispatchQueue.main.async {
                    let item = AVPlayerItem(url: url)
                    self.player = AVPlayer(playerItem: item)
                    let speed = self.sessionManager?.playbackSpeed ?? 1.0
                    self.player?.rate = Float(speed)
                    self.player?.play()
                    self.currentEpisode = episode
                    self.isPlaying = true
                    self.hasSetupAudio = true
                    self.startTimer()
                    self.setupEndOfTrackObserver()
                    
                    // CAROUSEL FIX: Start extended runtime session for background audio
                    self.startExtendedSession()
                    
                    // Resume from synced position
                    if episode.position > 0 {
                        let targetTime = CMTime(seconds: Double(episode.position), preferredTimescale: 1)
                        self.player?.seek(to: targetTime)
                        self.progress = Double(episode.position)
                    }
                    
                    if self.playbackSource == .streaming {
                        self.statusText = "Streaming..."
                    } else {
                        self.statusText = "Playing"
                    }
                    
                    self.updateNowPlayingInfo()
                    self.setupRemoteCommands()
                    
                    self.logger.info("Playback started: \(episode.title) (\(self.playbackSource == .local ? "local" : "streaming"))")
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusText = "Error: \(error.localizedDescription)"
                    self.logger.error("Audio session setup failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Toggle Play/Pause
    
    func togglePlayPause() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing {
            p.pause()
            isPlaying = false
            statusText = "Paused"
        } else {
            let speed = sessionManager?.playbackSpeed ?? 1.0
            p.rate = Float(speed)
            p.play()
            isPlaying = true
            statusText = playbackSource == .streaming ? "Streaming..." : "Playing"
        }
        updateNowPlayingPlaybackState()
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
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        
        if let observer = endOfTrackObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfTrackObserver = nil
        }
        
        // CAROUSEL FIX: Invalidate extended session and deactivate audio session.
        // An active audio session without playback keeps watchOS from suspending
        // the app → eventual watchdog kill.
        endExtendedSession()
        deactivateAudioSession()
    }
    
    // MARK: - Extended Runtime Session (CAROUSEL Watchdog Fix)
    
    /// Start a WKExtendedRuntimeSession for background audio playback.
    /// Without this, watchOS may suspend the app after ~30s in background
    /// even with the `audio` background mode declared in Info.plist.
    ///
    /// NOTE: Extended runtime sessions require a delegate and may not be fully
    /// supported in the watchOS simulator. Failure is non-fatal — the app falls
    /// back to the `audio` background mode alone.
    private func startExtendedSession() {
        guard extendedSession == nil || extendedSession?.state == .invalid else {
            logger.debug("Extended session already active — skipping")
            return
        }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        logger.info("Extended runtime session started for background audio")
    }
    
    /// Invalidate the extended runtime session when playback stops.
    private func endExtendedSession() {
        guard let session = extendedSession, session.state != .invalid else { return }
        session.invalidate()
        extendedSession = nil
        logger.info("Extended runtime session invalidated")
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
            statusText = "Error: \(error.localizedDescription)"
            bufferStallStart = nil
        } else if p.status == .failed {
            statusText = "Failed"
            bufferStallStart = nil
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
            self?.handleEpisodeCompleted()
        }
    }
    
    private func handleEpisodeCompleted() {
        guard let completed = currentEpisode else {
            stop()
            return
        }
        
        logger.info("Episode completed: \(completed.title)")
        
        // Sync final position
        sessionManager?.sendProgress(episodeId: completed.id, position: completed.duration)
        
        // Find next episode in queue
        guard let sm = sessionManager, !sm.episodes.isEmpty else {
            logger.info("Queue empty — stopping playback")
            stop()
            return
        }
        
        // Find the current episode's index in the queue and get the next one
        if let currentIndex = sm.episodes.firstIndex(where: { $0.id == completed.id }),
           currentIndex + 1 < sm.episodes.count {
            let next = sm.episodes[currentIndex + 1]
            logger.info("Auto-advancing to: \(next.title)")
            play(episode: next)
        } else if let first = sm.episodes.first, first.id != completed.id {
            // If completed episode isn't in queue (edge case), play first
            logger.info("Auto-advancing to first in queue: \(first.title)")
            play(episode: first)
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
                    if let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        info[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
        
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -15)
            return .success
        }
        
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: 30)
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleEpisodeCompleted()
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

// MARK: - WKExtendedRuntimeSessionDelegate

extension WatchAudioManager: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        logger.info("Extended runtime session did start")
    }
    
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // watchOS is about to end our extended session — log but don't interfere
        logger.warning("Extended runtime session will expire")
    }
    
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: (any Error)?) {
        if let error {
            logger.error("Extended runtime session invalidated: \(error.localizedDescription)")
        } else {
            logger.debug("Extended runtime session invalidated (reason: \(reason.rawValue))")
        }
        // Clear reference so a new session can be started on next play
        extendedSession = nil
    }
}

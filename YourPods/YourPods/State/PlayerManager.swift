import Foundation
import os

/// Bridges UI interactions with the AudioManager and handles sync logic.
/// Native port of player_provider.dart.
@Observable
@MainActor
final class PlayerManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "PlayerManager")
    
    let audioManager: AudioManager
    var podcastManager: PodcastManager?
    var settingsManager: SettingsManager?
    
    // Current playback state (sourced from AudioManager)
    var currentEpisodeGuid: String? { audioManager.currentItem?.id }
    var isPlaying: Bool { audioManager.isPlaying }
    var currentPosition: TimeInterval { audioManager.currentPosition }
    var currentDuration: TimeInterval { audioManager.currentDuration }
    var isBuffering: Bool { audioManager.isBuffering }
    
    /// Upcoming queue — does NOT include the currently playing item.
    var queue: [QueueItem] { audioManager.queue }
    
    var errorMessage: String? { audioManager.errorMessage }
    
    /// Unresolved sync conflicts waiting for user resolution (populated when strategy = .ask)
    var pendingConflicts: [SyncConflict] = []
    
    // Sync state
    private var lastSyncTime = Date.distantPast
    private var lastLocalSaveTime = Date.distantPast
    private var gpodderClient: GPodderClient?
    private var deviceId = "swift-client"
    
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        
        // Restore persisted queue from last session
        audioManager.restoreQueue()
        
        // Play-then-sync: when a new episode starts, fire background sync
        audioManager.onItemChanged = { [weak self] item in
            guard let self, let item else { return }
            self.handleItemChanged(item)
        }
        
        audioManager.onEpisodeCompleted = { [weak self] item in
            self?.handleEpisodeCompleted(item)
        }
    }
    
    func setGPodderClient(_ client: GPodderClient?, deviceId: String) {
        self.gpodderClient = client
        self.deviceId = deviceId
        
        // Initial sync on login
        Task {
            await syncPlaybackState()
        }
    }
    
    // MARK: - Playback Controls (forwarded to AudioManager)
    
    func play() { audioManager.play() }
    func pause() {
        audioManager.pause()
        forceSyncProgress()
    }
    func togglePlayPause() { audioManager.togglePlayPause() }
    func seek(to seconds: TimeInterval) { audioManager.seek(to: seconds) }
    func seekRelative(seconds: TimeInterval) { audioManager.seekRelative(seconds: seconds) }
    func skipToNext() { audioManager.skipToNext() }
    func skipToPrevious() { audioManager.skipToPrevious() }
    
    func setPlaybackRate(_ rate: Float) {
        audioManager.setPlaybackRate(rate)
        settingsManager?.playbackSpeed = Double(rate)
    }
    
    // MARK: - Queue Operations
    
    func addToQueue(_ episode: Episode, playNext: Bool = false) {
        guard let item = QueueItem.from(episode: episode) else { return }
        if playNext {
            audioManager.insertNext([item])
        } else {
            audioManager.appendToQueue([item])
        }
        // Mark interacted so episode is removed from Recently Updated
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
    }
    
    func removeFromQueue(_ item: QueueItem) {
        audioManager.removeFromQueue(item)
    }
    
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        audioManager.moveQueueItems(from: source, to: destination)
    }
    
    func playEpisode(_ episode: Episode, position: TimeInterval? = nil) {
        guard let item = QueueItem.from(episode: episode) else { return }
        
        // Mark interacted so episode is removed from Recently Updated
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
        
        // Apply per-podcast settings
        if let podcast = episode.podcast {
            let settings = podcast.effectiveSettings
            audioManager.skipIntroSeconds = settings.skipIntroSeconds ?? settingsManager?.skipIntroSeconds ?? 0
            audioManager.skipOutroSeconds = settings.skipOutroSeconds ?? settingsManager?.skipOutroSeconds ?? 0
            
            let speed = settings.playbackSpeed ?? settingsManager?.playbackSpeed ?? 1.0
            audioManager.setPlaybackRate(Float(speed))
        }
        
        Task {
            await audioManager.playEpisode(item, initialPosition: position, preserveCurrent: true)
        }
    }
    
    // MARK: - Play-Then-Sync
    
    private func handleItemChanged(_ item: QueueItem) {
        logger.info("Episode changed to: \(item.title). Triggering background sync...")
        
        // Fire sync in background — don't block playback
        Task {
            await syncPlaybackState()
        }
    }
    
    /// Sync playback state with the server. If the server has a later position, seek forward.
    func syncPlaybackState() async {
        guard let podcastManager else { return }
        
        do {
            let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
            let conflicts = try await podcastManager.syncEpisodeActions(strategy: strategy)
            
            // Surface unresolved conflicts for user resolution
            if !conflicts.isEmpty && strategy == .ask {
                pendingConflicts = conflicts
            }
            
            // If the current episode has a server position ahead of ours, seek to it
            if let currentGuid = currentEpisodeGuid {
                let isConflicted = conflicts.contains { $0.episodeGuid == currentGuid }
                if !isConflicted, let action = podcastManager.getLatestAction(for: currentGuid),
                   let serverPos = action.position {
                    let localPos = Int(currentPosition)
                    if serverPos > localPos + 5 {
                        logger.info("Server position ahead (\(localPos) → \(serverPos)), seeking...")
                        audioManager.seek(to: TimeInterval(serverPos))
                    }
                }
            }
        } catch {
            logger.error("Background sync failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Episode Completion
    
    private func handleEpisodeCompleted(_ item: QueueItem) {
        guard let podcastManager else { return }
        
        // Mark as played on server
        let action = EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: item.durationSeconds ?? Int(currentDuration),
            started: 0,
            total: item.durationSeconds ?? Int(currentDuration),
            device: deviceId
        )
        
        Task {
            await podcastManager.sendEpisodeAction(action)
        }
        
        // Mark as interacted locally
        podcastManager.markEpisodeAsInteracted(item.podcastUrl, item.id)
    }
    
    // MARK: - Progress Tracking
    
    /// P0: Update local model with current playback position.
    /// Called frequently (every ~5s) to keep Episode.listenedSeconds and
    /// QueueItem.positionSeconds accurate for UI, queue restore, and watch sync.
    func updateLocalProgress() {
        guard let podcastManager, let item = audioManager.currentItem else { return }
        let pos = Int(currentPosition)
        guard pos > 0 else { return }
        
        // Throttle local writes to every 5 seconds
        let now = Date()
        guard now.timeIntervalSince(lastLocalSaveTime) >= 5 else { return }
        lastLocalSaveTime = now
        
        // Update QueueItem.positionSeconds on the current item
        if var updated = audioManager.currentItem, updated.positionSeconds != pos {
            updated.positionSeconds = pos
            audioManager.currentItem = updated
        }
        
        // Update SwiftData Episode.listenedSeconds
        podcastManager.updateEpisodeProgress(
            podcastUrl: item.podcastUrl,
            episodeGuid: item.id,
            position: pos
        )
    }
    
    /// P1: Sync playback position to server at the user-configured interval (10–60s, default 30s).
    /// Also updates local model via updateLocalProgress().
    func syncProgress() {
        guard let podcastManager, let item = audioManager.currentItem else { return }
        
        // Always update local state first
        updateLocalProgress()
        
        // Server sync at configured interval
        let now = Date()
        let interval = settingsManager?.syncInterval ?? 30
        guard now.timeIntervalSince(lastSyncTime) >= TimeInterval(interval) else { return }
        lastSyncTime = now
        
        let action = EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: Int(currentPosition),
            started: 0,
            total: item.durationSeconds ?? Int(currentDuration),
            device: deviceId
        )
        
        Task {
            await podcastManager.sendEpisodeAction(action)
        }
    }
    
    /// Force-save current position to local model and server, bypassing all throttles.
    /// Call on pause and app backgrounding to ensure no position data is lost.
    func forceSyncProgress() {
        guard let item = audioManager.currentItem else { return }
        let pos = Int(currentPosition)
        guard pos > 0 else { return }
        
        // Force-update QueueItem.positionSeconds immediately (no throttle)
        if var updated = audioManager.currentItem, updated.positionSeconds != pos {
            updated.positionSeconds = pos
            audioManager.currentItem = updated
        }
        
        // Force-update SwiftData Episode.listenedSeconds (no throttle)
        podcastManager?.updateEpisodeProgress(
            podcastUrl: item.podcastUrl,
            episodeGuid: item.id,
            position: pos
        )
        lastLocalSaveTime = Date()
        
        // Persist queue to disk immediately
        audioManager.persistQueueToDisk()
        
        // Force server sync (no throttle)
        guard let podcastManager else { return }
        lastSyncTime = Date()
        
        let action = EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: pos,
            started: 0,
            total: item.durationSeconds ?? Int(currentDuration),
            device: deviceId
        )
        
        Task {
            await podcastManager.sendEpisodeAction(action)
        }
    }
    
    // MARK: - Play Latest Episode (Siri / Watch)
    
    /// Finds a podcast by name and plays its most recent episode.
    func playLatest(podcastName: String) {
        guard let podcastManager else { return }
        
        let match = podcastManager.subscriptions.first {
            $0.title.localizedCaseInsensitiveContains(podcastName)
        }
        
        guard let podcast = match else {
            logger.warning("playLatest: no podcast matching '\(podcastName)'")
            return
        }
        
        let sorted = podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        guard let latest = sorted.first else {
            logger.warning("playLatest: no episodes for '\(podcast.title)'")
            return
        }
        
        logger.info("playLatest: playing '\(latest.title)' from '\(podcast.title)'")
        playEpisode(latest)
    }
    
    // MARK: - Update Progress (Watch sync)
    
    /// Applies a position update from the watch for a specific episode.
    func updateProgress(episodeId: String, position: Int) {
        guard let item = audioManager.currentItem, item.id == episodeId else { return }
        
        // Only seek forward (watch may be behind)
        if position > Int(currentPosition) + 5 {
            audioManager.seek(to: TimeInterval(position))
        }
    }
    
    // MARK: - Formatting Helpers
    
    /// Formats seconds as `m:ss` or `h:mm:ss` for time-position display.
    nonisolated static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }
    
    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 {
            return "\(s / 3600)h \((s % 3600) / 60)m"
        } else if s >= 60 {
            return "\(s / 60)m"
        }
        return "\(s)s"
    }
    
    nonisolated static func formatProgress(position: TimeInterval, duration: TimeInterval, showPercent: Bool = true) -> String {
        guard duration > 0 else { return "0%" }
        let pct = Int((position / duration * 100).clamped(to: 0...100))
        return showPercent ? "\(pct)% listened" : "\(100 - pct)% left"
    }
}

// MARK: - Comparable clamped extension
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}


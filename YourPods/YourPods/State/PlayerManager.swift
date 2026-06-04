import Foundation
import os

/// Bridges UI interactions with the AudioManager and handles sync logic.
/// Playback state manager — coordinates AudioManager, sync, and UI updates.
@Observable
@MainActor
final class PlayerManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "PlayerManager")
    
    let audioManager: AudioManager
    var podcastManager: PodcastManager?
    var settingsManager: SettingsManager?
    var downloadManager: DownloadManager?
    
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
    
    /// Unresolved URL rewrite conflicts from server's `update_urls` response.
    var pendingUrlRewrites: [URLRewriteConflict] = []
    
    // Sync state
    private var lastSyncTime = Date.distantPast
    private var lastLocalSaveTime = Date.distantPast
    private var syncClient: (any SyncClient)?
    private(set) var deviceId = "swift-client"
    
    /// True while `syncQueueWithServer()` is running. Used to suppress
    /// `pushQueueToProServerDebounced()` and prevent racing pushes.
    private(set) var isSyncingQueue = false

    // ── YourPods Pro: Stats buffer & segment tracking ────────────────────
    /// Accumulates listening/skip events for async batch upload via Pro API.
    /// `PodcastManager.refreshAndSync` flushes this via `pushStatsEvents`.
    let statsBuffer = StatsEventBuffer()

    /// Tracks the current continuous listening segment.
    /// Opened on play/seek, closed on pause/skip/episode-end.
    private var segmentStartPosition: Double?
    private var segmentStartWallTime: Date?
    
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        
        // Restore persisted queue from last session
        audioManager.restoreQueue()
        
        // Play-then-sync: when a new episode starts, fire background sync
        audioManager.onItemChanged = { [weak self] item in
            guard let self, let item else { return }
            self.closeAndRecordSegment()
            self.handleItemChanged(item)
            self.beginSegment()
        }
        
        audioManager.onEpisodeCompleted = { [weak self] item in
            self?.closeAndRecordSegment()
            self?.handleEpisodeCompleted(item)
        }
        
        // Wire settings resolver so AudioManager can re-resolve per-podcast
        // settings at play time (skip intro/outro, speed, skip forward/backward).
        // This ensures stale QueueItem values from enqueue time are replaced
        // with live settings, fixing the bug where setting changes after
        // enqueueing (or from sync) were ignored.
        audioManager.settingsResolver = { [weak self] item in
            guard let self else { return (skipIntro: 0, skipOutro: 0, speed: 1.0, skipForward: 30, skipBackward: 15) }
            let podcast = self.podcastManager?.subscriptions.first { $0.url == item.podcastUrl }
            let podSettings = podcast?.effectiveSettings
            return (
                skipIntro: podSettings?.skipIntroSeconds ?? self.settingsManager?.skipIntroSeconds ?? 0,
                skipOutro: podSettings?.skipOutroSeconds ?? self.settingsManager?.skipOutroSeconds ?? 0,
                speed: Float(podSettings?.playbackSpeed ?? self.settingsManager?.playbackSpeed ?? 1.0),
                skipForward: self.settingsManager?.skipForwardSeconds ?? 30,
                skipBackward: self.settingsManager?.skipBackwardSeconds ?? 15
            )
        }
        
        // Wire auto-flush handler so the buffer can trigger uploads
        // when the 50-event limit or 30s periodic timer fires.
        // This is safe for all account types — flushStatsIfAuthenticated()
        // guards on syncClient as? YourPodsProClient.
        Task { [weak self] in
            guard let self else { return }
            await self.statsBuffer.setFlushHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.flushStatsIfAuthenticated()
                }
            }
        }
    }
    
    func setSyncClient(_ client: (any SyncClient)?, deviceId: String) {
        self.syncClient = client
        self.deviceId = deviceId
        
        // Clear queue sync state on logout so a re-login
        // correctly detects "first sync" on this profile
        if client == nil {
            UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
            UserDefaults.standard.removeObject(forKey: Self.proQueueSyncServerGuidsKey)
        }
        
        // Initial sync on login
        Task {
            await syncPlaybackState()
            // If no episode is loaded, try to restore the now-playing episode from another device
            await restoreNowPlayingFromProServer()
        }
    }
    
    // MARK: - Playback Controls (forwarded to AudioManager)
    
    func play() {
        audioManager.play()
        beginSegment()
        Task { await statsBuffer.startPeriodicFlush() }
    }
    func pause() {
        closeAndRecordSegment()
        audioManager.pause()
        forceSyncProgress()
        Task { await statsBuffer.stopPeriodicFlush() }
        // Tell the Pro server we're still on this episode (paused)
        syncNowPlayingToProServer(nowPlaying: true)
        flushStatsIfAuthenticated()
    }
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    func seek(to seconds: TimeInterval) {
        closeAndRecordSegment()
        audioManager.seek(to: seconds)
        beginSegment()
    }
    func seekRelative(seconds: TimeInterval) {
        closeAndRecordSegment()
        audioManager.seekRelative(seconds: seconds)
        beginSegment()
    }
    func skipToNext() {
        closeAndRecordSegment()
        if let item = audioManager.currentItem {
            let from = currentPosition
            let event = ProStatsEvent(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                eventType: .skipManual,
                fromPosSec: from,
                toPosSec: 0,
                durationSec: 0,
                contentSec: 0,
                speed: Double(audioManager.playbackRate),
                deviceId: deviceId
            )
            Task { await statsBuffer.record(event) }
        }
        audioManager.skipToNext()
    }
    func skipToPrevious() {
        closeAndRecordSegment()
        if let item = audioManager.currentItem {
            let from = currentPosition
            let event = ProStatsEvent(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                eventType: .skipManual,
                fromPosSec: from,
                toPosSec: 0,
                durationSec: 0,
                contentSec: 0,
                speed: Double(audioManager.playbackRate),
                deviceId: deviceId
            )
            Task { await statsBuffer.record(event) }
        }
        audioManager.skipToPrevious()
    }
    
    func setPlaybackRate(_ rate: Float) {
        audioManager.setPlaybackRate(rate)
        settingsManager?.playbackSpeed = Double(rate)
    }
    
    // MARK: - Queue Operations
    
    func addToQueue(_ episode: Episode, playNext: Bool = false) {
        guard var item = QueueItem.from(episode: episode) else { return }
        // Apply global fallbacks for skip/speed if per-podcast isn't set
        item = applyEffectiveSettings(item, episode: episode)
        // Attach local file URL if this episode has been downloaded
        item.localFileUrl = downloadManager?.localUrl(for: episode.guid)
        if playNext {
            audioManager.insertNext([item])
        } else {
            audioManager.appendToQueue([item])
        }
        // Mark interacted so episode is removed from Recently Updated
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
    }
    
    /// Batch add episodes to the queue, preserving their order.
    /// When `playNext` is true, uses a single `insertNext` call so episodes
    /// appear at the top in the correct order (not reversed).
    func addToQueue(_ episodes: [Episode], playNext: Bool = false) {
        let items = episodes.compactMap { ep -> QueueItem? in
            guard var item = QueueItem.from(episode: ep) else { return nil }
            item = applyEffectiveSettings(item, episode: ep)
            // Attach local file URL if this episode has been downloaded
            item.localFileUrl = downloadManager?.localUrl(for: ep.guid)
            return item
        }
        guard !items.isEmpty else { return }
        if playNext {
            audioManager.insertNext(items)
        } else {
            audioManager.appendToQueue(items)
        }
        for item in items {
            podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
        }
    }
    
    func removeFromQueue(_ item: QueueItem) {
        audioManager.removeFromQueue(item)
        
        // Notify Pro server of the deletion (tombstone) to prevent re-addition.
        // No-op for gPodder / Vault via the protocol default extension.
        if let syncClient {
            let episodeUrl = item.audioUrl
            Task {
                do {
                    guard await syncClient.supportsQueueSync else { return }
                    try await syncClient.deleteQueueItem(episodeUrl: episodeUrl)
                    logger.info("Deleted queue item on server: \(item.title)")
                } catch {
                    logger.error("Failed to delete queue item on server: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Mark the currently-playing episode as played: stop playback, remove from queue, and mark played.
    /// Advances to the next queued episode if available, otherwise stops.
    ///
    /// - Parameter fromSync: When `true`, uses `markEpisodePlayedLocally` (no outbound `EpisodeAction`)
    ///   to prevent redundant server echoes during reconciliation. Default `false` sends the action normally.
    func markCurrentEpisodeAsPlayed(fromSync: Bool = false) {
        guard let item = audioManager.currentItem else { return }
        
        // Set isPlayed flag on the QueueItem BEFORE stopping, so that if
        // playEpisode(preserveCurrent:) is called during cleanup, the
        // played episode won't be re-inserted into the queue.
        var playedItem = item
        playedItem.isPlayed = true
        audioManager.currentItem = playedItem
        
        if fromSync {
            // Sync-initiated: mark played locally only (no outbound EpisodeAction).
            // The server already told us this episode is complete — don't echo it back.
            podcastManager?.markEpisodePlayedLocally(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
        } else {
            // User-initiated: mark as played in PodcastManager (SwiftData + gPodder sync)
            podcastManager?.markEpisodeAsPlayed(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
        }
        
        // Stop current playback — the episode is done
        audioManager.stop()
    }
    
    /// Remove the currently-playing episode from the queue without marking it as played.
    /// Saves progress, stops playback, and clears the current item.
    /// Unlike `markCurrentEpisodeAsPlayed()`, this preserves the episode's unplayed status.
    func removeCurrentEpisodeFromQueue() {
        guard audioManager.currentItem != nil else { return }
        
        // Save current progress before stopping so no position data is lost
        forceSyncProgress()
        
        // Stop current playback — clears currentItem, position, and now-playing info
        audioManager.stop()
    }
    
    /// Mark an Up Next queued episode as played: remove from queue (with server tombstone) and mark played.
    func markQueuedEpisodeAsPlayed(_ item: QueueItem) {
        removeFromQueue(item)  // Uses self.removeFromQueue which sends server tombstone
        podcastManager?.markEpisodeAsPlayed(
            podcastUrl: item.podcastUrl,
            episodeGuid: item.id
        )
    }
    
    /// Clear everything from the queue: stop playback, remove the currently playing
    /// item, and remove all upcoming episodes. Optionally marks episodes as played
    /// based on the user's queue removal preference. Sends server tombstones for
    /// Pro sync users.
    func clearAllQueue() {
        // Capture all items BEFORE clearing so we can send tombstones and mark played
        var allItems: [QueueItem] = audioManager.queue
        if let current = audioManager.currentItem {
            allItems.append(current)
        }
        
        // Respect the user's queue removal preference
        let shouldMarkPlayed = settingsManager?.queueRemovalAction == .removeAndMarkPlayed
        if shouldMarkPlayed {
            for item in allItems {
                podcastManager?.markEpisodeAsPlayed(
                    podcastUrl: item.podcastUrl,
                    episodeGuid: item.id
                )
            }
        }
        
        // Clear everything: upcoming queue + stop playback (clears currentItem,
        // position, duration, and now-playing info)
        audioManager.clearQueue()
        audioManager.stop()
        
        // Send server tombstones for Pro sync users
        if let syncClient {
            for item in allItems {
                let episodeUrl = item.audioUrl
                Task {
                    do {
                        guard await syncClient.supportsQueueSync else { return }
                        try await syncClient.deleteQueueItem(episodeUrl: episodeUrl)
                        logger.info("Deleted queue item on server (clear all): \(item.title)")
                    } catch {
                        logger.error("Failed to delete queue item on server: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        audioManager.moveQueueItems(from: source, to: destination)
    }
    
    func playEpisode(_ episode: Episode, position: TimeInterval? = nil) {
        guard var item = QueueItem.from(episode: episode) else { return }
        
        // Mark interacted so episode is removed from Recently Updated
        podcastManager?.markEpisodeAsInteracted(item.podcastUrl, item.id)
        
        // Apply per-podcast settings with global fallbacks
        item = applyEffectiveSettings(item, episode: episode)
        
        // Attach local file URL if this episode has been downloaded
        item.localFileUrl = downloadManager?.localUrl(for: episode.guid)
        
        // Also set instance-level settings for backward compatibility
        if let podcast = episode.podcast {
            let settings = podcast.effectiveSettings
            audioManager.skipIntroSeconds = settings.skipIntroSeconds ?? settingsManager?.skipIntroSeconds ?? 0
            audioManager.skipOutroSeconds = settings.skipOutroSeconds ?? settingsManager?.skipOutroSeconds ?? 0
            
            let speed = settings.playbackSpeed ?? settingsManager?.playbackSpeed ?? 1.0
            audioManager.setPlaybackRate(Float(speed))
        }
        
        // Apply headphone/remote command actions from settings
        audioManager.nextTrackAction = settingsManager?.nextTrackAction ?? .nextEpisode
        audioManager.previousTrackAction = settingsManager?.previousTrackAction ?? .skipBack
        
        Task {
            await audioManager.playEpisode(item, initialPosition: position, preserveCurrent: true)
        }
    }
    
    /// Resolve effective skip/speed settings for a QueueItem, applying global fallbacks.
    private func applyEffectiveSettings(_ item: QueueItem, episode: Episode) -> QueueItem {
        var result = item
        let podSettings = episode.podcast?.effectiveSettings
        result.skipIntroSeconds = podSettings?.skipIntroSeconds ?? settingsManager?.skipIntroSeconds ?? 0
        result.skipOutroSeconds = podSettings?.skipOutroSeconds ?? settingsManager?.skipOutroSeconds ?? 0
        result.playbackSpeed = Float(podSettings?.playbackSpeed ?? settingsManager?.playbackSpeed ?? 1.0)
        // P3: per-podcast privacyMode overrides global p3Enabled
        result.privacyMode = podSettings?.privacyMode ?? settingsManager?.p3Enabled ?? false
        return result
    }
    
    // MARK: - Play-Then-Sync
    
    private func handleItemChanged(_ item: QueueItem) {
        logger.info("Episode changed to: \(item.title). Triggering background sync...")
        
        // Fire sync in background — don't block playback
        Task {
            await syncPlaybackState()
        }
        
        // Bug 2 fix: Clear previous episode's nowPlaying before setting new one.
        // This prevents the server from showing stale "now playing" state for
        // the episode the user just left (especially when they skip at 50%).
        let previous = _previousItem
        syncNowPlayingToProServer(nowPlaying: true, clearingPrevious: previous)
        
        // Track this item as the "previous" for the next switch
        _previousItem = item
    }
    
    /// Sync playback state with the server. If the server has a later position, seek forward.
    func syncPlaybackState() async {
        guard let podcastManager else { return }
        
        do {
            let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
            // P1-1: Use incremental sync (force: false) on track changes.
            // Only pulls actions since the last sync timestamp, not the entire history.
            // Full pulls (force: true) are reserved for manual refresh and orchestrators.
            let conflicts = try await podcastManager.syncEpisodeActions(force: false, strategy: strategy)
            
            // Surface unresolved conflicts for user resolution
            if !conflicts.isEmpty && strategy == .ask {
                pendingConflicts = conflicts
            }
            
            // If the current episode has a server position ahead of ours, seek to it.
            // Only auto-seek when strategy is .serverWins — for .deviceWins/.ask,
            // the device position is authoritative and should not be overridden.
            if strategy == .serverWins, let currentGuid = currentEpisodeGuid {
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
        
        // Capture duration BEFORE any transition resets it (playEpisode resets currentDuration to 0)
        let totalDuration = item.durationSeconds ?? Int(audioManager.currentDuration)
        
        // Mark as played on server
        let action = EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: totalDuration,
            started: 0,
            total: totalDuration,
            device: deviceId
        )
        
        Task {
            await podcastManager.sendEpisodeAction(action)
        }
        
        // Mark as played locally — must happen synchronously before
        // handleItemChanged triggers sync, so the conflict detector sees
        // isPlayed = true and skips the episode.
        // Note: we do NOT call markEpisodeAsPlayed() because that sends
        // a duplicate EpisodeAction to the server. We only need the local flag.
        podcastManager.markEpisodePlayedLocally(podcastUrl: item.podcastUrl, episodeGuid: item.id)
        
        // Flush progress to disk — episode just completed, position must be persisted
        // before auto-advance loads the next episode and potentially resets state.
        podcastManager.flushProgressToDisk()
        
        // Tell the Pro server this episode is finished.
        // Bug 1 fix: Use syncCompletedEpisodeToProServer which takes the completed
        // item explicitly, instead of syncNowPlayingToProServer which reads
        // audioManager.currentItem (already changed by auto-advance).
        syncCompletedEpisodeToProServer(item)
        
        // Flush stats immediately on episode completion
        flushStatsIfAuthenticated()
    }

    // MARK: - Segment-Based Stats Tracking

    /// Opens a new listening segment at the current playback position.
    /// Call at the START of continuous playback: play(), seek(), episode change.
    private func beginSegment() {
        guard audioManager.currentItem != nil else { return }
        segmentStartPosition = currentPosition
        segmentStartWallTime = Date()
    }

    /// Closes the current segment and records it as a listen event in the stats buffer.
    /// Call at the END of continuous playback: pause(), seek(), skip, episode end.
    ///
    /// The recorded event captures:
    /// - `fromPosSec` / `toPosSec` — content position range
    /// - `contentSec` — absolute content distance covered (toPos - fromPos)
    /// - `durationSec` — wall-clock time elapsed
    /// - `speed` — playback rate at close time
    ///
    /// Sub-threshold events (< 1s content OR < 0.5s wall-clock) are silently
    /// dropped by `StatsEventBuffer.recordIfMeetsThreshold`.
    private func closeAndRecordSegment() {
        guard let item = audioManager.currentItem,
              let startPos = segmentStartPosition,
              let startWall = segmentStartWallTime else {
            return
        }

        let endPos = currentPosition
        let contentSec = abs(endPos - startPos)
        let durationSec = Date().timeIntervalSince(startWall)

        // Clear segment state immediately
        segmentStartPosition = nil
        segmentStartWallTime = nil

        let event = ProStatsEvent(
            podcastUrl: item.podcastUrl,
            episodeUrl: item.audioUrl,
            episodeGuid: item.id,
            eventType: .listen,
            fromPosSec: startPos,
            toPosSec: endPos,
            durationSec: durationSec,
            contentSec: contentSec,
            speed: Double(audioManager.playbackRate),
            deviceId: deviceId
        )
        Task { await statsBuffer.recordIfMeetsThreshold(event) }
    }

    

    // MARK: - Progress Tracking

    /// P0: Update local model with current playback position.
    /// Called frequently (every ~5s) to keep Episode.listenedSeconds and
    /// QueueItem.positionSeconds accurate for UI, queue restore, and watch sync.
    func updateLocalProgress() {
        // Guard: don't sync stale position data during episode transitions
        guard !audioManager.isInEpisodeTransition else { return }
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
        // Guard: don't sync stale position data during episode transitions
        guard !audioManager.isInEpisodeTransition else { return }
        guard let podcastManager, let item = audioManager.currentItem else { return }
        
        // Always update local state first
        updateLocalProgress()
        
        // Server sync at configured interval
        let now = Date()
        let interval = settingsManager?.syncInterval ?? 60
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
    
    /// Force-save current position to local model, bypassing all throttles.
    /// Call on pause and app backgrounding to ensure no position data is lost.
    ///
    /// **0xDEAD10CC fix:** This method intentionally does NOT push to the server.
    /// The previous fire-and-forget `Task { sendEpisodeAction() }` outlived the
    /// background task assertion in the app's background handler, allowing a
    /// `modelContext.save()` to hold a SQLite file lock during suspension.
    /// The episode action is queued in the `actionMap` and flushed to disk by
    /// `forcePersistActionMap()` (called immediately after this method).
    /// Server push happens on next foreground sync.
    func forceSyncProgress() {
        guard let item = audioManager.currentItem else { return }
        let pos = Int(currentPosition)
        guard pos > 0 else { return }
        
        // Cancel any pending seek debounce — we're about to flush the position
        // immediately, so the stale debounce task would be a duplicate.
        seekSyncTask?.cancel()
        seekSyncTask = nil
        
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
        // Flush dirty progress to disk immediately — bypasses the 60s throttle.
        // This is a critical save point: the app may be killed after backgrounding.
        podcastManager?.flushProgressToDisk()
        lastLocalSaveTime = Date()
        
        // Persist queue to disk immediately
        audioManager.persistQueueToDisk()
        
        // Queue the episode action for deferred server push (no Task spawned).
        // The actionMap is persisted by forcePersistActionMap() in the background
        // handler and pushed on the next foreground sync cycle.
        podcastManager?.queueEpisodeAction(EpisodeAction(
            podcast: item.podcastUrl,
            episode: item.audioUrl,
            guid: item.id,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: pos,
            started: 0,
            total: item.durationSeconds ?? Int(currentDuration),
            device: deviceId
        ))
    }
    
    // MARK: - Seek Sync (P0-3)
    
    private static let seekSyncDebounceInterval: TimeInterval = 1.5
    private var seekSyncTask: Task<Void, Never>?
    
    /// Seek and schedule a debounced server sync.
    /// Debounce (1.5s) prevents spam during scrubbing — only the final position syncs.
    func seekAndSync(to positionSeconds: Int) {
        let position = TimeInterval(positionSeconds)
        audioManager.seek(to: position)
        
        // Cancel any pending debounce — restart timer from the latest seek
        seekSyncTask?.cancel()
        seekSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.seekSyncDebounceInterval))
            guard !Task.isCancelled, let self else { return }
            
            guard let item = self.audioManager.currentItem,
                  let podcastManager = self.podcastManager else { return }
            
            let action = EpisodeAction(
                podcast: item.podcastUrl,
                episode: item.audioUrl,
                guid: item.id,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: positionSeconds,
                started: 0,
                total: item.durationSeconds ?? Int(self.currentDuration),
                device: self.deviceId
            )
            
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
    
    // MARK: - Pro Queue Sync
    
    /// Full bidirectional queue sync: pull → merge → push → adopt.
    /// This is the correct cross-device sync flow.
    /// Returns any position conflicts for the `.ask` strategy.
    /// No-op for gPodder clients or Vault mode.
    @discardableResult
    func syncQueueWithServer() async -> [SyncConflict] {
        guard let syncClient, await syncClient.supportsQueueSync else { return [] }
        
        // Cancel any in-flight debounced push — we're about to do a full sync.
        // This prevents racing pushes where the debounced push and the sync's
        // Step 3 PUSH both call syncQueue() concurrently.
        queuePushTask?.cancel()
        queuePushTask = nil
        isSyncingQueue = true
        defer { isSyncingQueue = false }
        
        let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
        var conflicts: [SyncConflict] = []
        
        // Track in-flight additions — items added to the queue during async
        // suspension points (network calls) that aren't in the server response.
        var inFlightAdds: [QueueItem] = []
        
        do {
            // Step 1: PULL — get the server's current queue
            let serverItems = try await syncClient.getQueue()
            logger.info("Queue sync: pulled \(serverItems.count) items from server")
            for (i, si) in serverItems.enumerated() {
                logger.info("  PULL[\(i)]: \(si.title ?? "nil") guid=\(si.episodeGuid ?? "nil") url=\(si.episodeUrl.prefix(60))")
            }
            
            // Step 2: MERGE — local items first, append server-new items
            let currentId = audioManager.currentItem?.id
            let localItems = audioManager.queue
            
            // Bug 3 fix: Fresh device detection.
            // If local queue is empty AND no currentItem, this is a new device.
            // Adopt the server queue wholesale — don't merge or push back.
            // This prevents auto-queued episodes (from processNewEpisodes) from
            // flooding the server with 1,400+ items.
            let isFreshDevice = localItems.isEmpty && currentId == nil
            if isFreshDevice && !serverItems.isEmpty {
                let sorted = serverItems.sorted { $0.sortOrder < $1.sortOrder }
                logger.info("Queue sync: fresh device detected — adopting \(sorted.count) items from server")
                
                // sortOrder 0 = the now-playing episode on the other device
                if let nowPlayingSync = sorted.first {
                    let nowPlayingItem = buildQueueItemFromSyncItem(nowPlayingSync)
                    audioManager.currentItem = nowPlayingItem
                    logger.info("Queue sync: restored currentItem from server: \(nowPlayingItem.title)")
                }
                
                // Remaining items (sortOrder > 0) become the queue
                let remaining = Array(sorted.dropFirst())
                let queueItems = remaining.map { buildQueueItemFromSyncItem($0) }
                audioManager.replaceQueue(queueItems)
                logger.info("Queue sync: fresh device adopted \(queueItems.count) queue items")
                
                return conflicts
            }
            
            // Build a map of server items by guid for position lookup
            var serverPositionMap: [String: Double] = [:]
            var serverMetadataMap: [String: QueueSyncItem] = [:]
            for item in serverItems {
                let guid = item.episodeGuid ?? item.episodeUrl
                if let pos = item.positionSec {
                    serverPositionMap[guid] = pos
                }
                serverMetadataMap[guid] = item
            }
            
            // Build a set of local episode identifiers for dedup
            var localIds = Set<String>()
            for item in localItems {
                localIds.insert(item.id)
            }
            if let currentId {
                localIds.insert(currentId)
            }
            
            // Step 1.5: GUID-aware pruning
            // Only prune items that were in the PREVIOUS sync's server response
            // but are now absent — they were removed/completed on another device.
            // Items the server has never seen (locally added since last sync)
            // are preserved until the push in Step 3 uploads them.
            //
            // Bug fix: The old logic pruned ALL items not on the current server
            // response, which killed locally-added items before their push landed.
            let serverGuids = Set(serverItems.map { $0.episodeGuid ?? $0.episodeUrl })
            let hasCompletedQueueSync = UserDefaults.standard.bool(forKey: "proQueueSyncCompleted")
            let previousServerGuids = Set(UserDefaults.standard.stringArray(forKey: Self.proQueueSyncServerGuidsKey) ?? [])
            
            var prunedLocalItems = localItems
            if hasCompletedQueueSync && !isFreshDevice && !previousServerGuids.isEmpty {
                // "Stale" = was on the server last time, but is NOT on the server now.
                // These were removed/completed on another device.
                let removedFromServer = previousServerGuids.subtracting(serverGuids)
                let staleItems = localItems.filter { removedFromServer.contains($0.id) }
                if !staleItems.isEmpty {
                    prunedLocalItems = localItems.filter { !removedFromServer.contains($0.id) }
                    logger.info("Queue sync: pruned \(staleItems.count) stale local items (removed from server since last sync)")
                    audioManager.replaceQueue(prunedLocalItems)
                    
                    // Update localIds after pruning
                    localIds = Set(prunedLocalItems.map(\.id))
                    if let currentId {
                        localIds.insert(currentId)
                    }
                }
            }
            
            // Step 2a: Reconcile positions for SHARED items (exist in both local and server)
            // Track conflicted items' server positions for the push step
            var conflictedServerPositions: [String: Double] = [:]
            var reconciledQueue: [QueueItem] = []
            for item in prunedLocalItems {
                let serverPos = serverPositionMap[item.id]
                let localPos = item.positionSeconds
                
                var resolvedPosition = localPos
                
                if let serverPosition = serverPos {
                    let serverPosInt = Int(serverPosition)
                    
                    switch strategy {
                    case .serverWins:
                        // Always adopt server position
                        resolvedPosition = serverPosInt
                    case .deviceWins:
                        // Keep local position (already set)
                        break
                    case .ask:
                        // If both have non-zero positions that differ, generate a conflict
                        if localPos > 0 && serverPosInt > 0 && abs(localPos - serverPosInt) > 10 {
                            let serverItem = serverMetadataMap[item.id]
                            conflicts.append(SyncConflict(
                                episodeGuid: item.id,
                                episodeTitle: item.title,
                                podcastTitle: item.podcastTitle,
                                podcastUrl: item.podcastUrl,
                                artworkUrl: item.artworkUrl,
                                audioUrl: item.audioUrl,
                                localPosition: localPos,
                                serverPosition: serverPosInt,
                                serverTimestamp: 0,
                                totalDuration: item.durationSeconds ?? serverItem?.durationSec.map { Int($0) },
                                occurrenceCount: 1
                            ))
                            // Track server position so the push preserves it
                            conflictedServerPositions[item.id] = serverPosition
                            // Keep local position for now — conflict wizard will resolve
                        } else if localPos == 0 {
                            // Never played locally — silently adopt server
                            resolvedPosition = serverPosInt
                        }
                        // If server is 0, keep local
                    }
                }
                
                // Create updated item with reconciled position
                if resolvedPosition != localPos {
                    reconciledQueue.append(QueueItem(
                        id: item.id,
                        title: item.title,
                        podcastTitle: item.podcastTitle,
                        audioUrl: item.audioUrl,
                        artworkUrl: item.artworkUrl,
                        durationSeconds: item.durationSeconds,
                        positionSeconds: resolvedPosition,
                        podcastUrl: item.podcastUrl,
                        pubDate: item.pubDate,
                        podcastAuthor: item.podcastAuthor,
                        episodeDescription: item.episodeDescription
                    ))
                } else {
                    reconciledQueue.append(item)
                }
            }
            
            // Reconcile order: The server's order is the canonical source of truth for items that exist on both.
            var serverSortMap: [String: Int] = [:]
            for (index, item) in serverItems.enumerated() {
                let guid = item.episodeGuid ?? item.episodeUrl
                serverSortMap[guid] = index
            }
            
            reconciledQueue.sort { a, b in
                let aOrder = serverSortMap[a.id] ?? Int.max
                let bOrder = serverSortMap[b.id] ?? Int.max
                if aOrder == bOrder {
                    // Fall back to existing local order if both were added offline and lack a server sortOrder
                    let aLocal = prunedLocalItems.firstIndex(where: { $0.id == a.id }) ?? Int.max
                    let bLocal = prunedLocalItems.firstIndex(where: { $0.id == b.id }) ?? Int.max
                    return aLocal < bLocal
                }
                return aOrder < bOrder
            }
            
            // Replace local queue with reconciled positions
            audioManager.replaceQueue(reconciledQueue)
            logger.info("Queue sync: reconciledQueue has \(reconciledQueue.count) items")
            for (i, ri) in reconciledQueue.enumerated() {
                logger.info("  RECONCILED[\(i)]: \(ri.title) id=\(ri.id.prefix(40))")
            }
            
            // Step 2b: Find server items NOT already in local queue and append
            let newFromServer = serverItems
                .filter { item in
                    let guid = item.episodeGuid ?? item.episodeUrl
                    return !localIds.contains(guid) && guid != currentId
                }
                .sorted { $0.sortOrder < $1.sortOrder }
            
            // Build a lookup of local episodes for metadata enrichment
            let localEpisodes = buildLocalEpisodeLookup(for: newFromServer)
            
            // Convert server-new items to QueueItems and append to local queue
            // Filter out episodes that are marked as played locally — they were
            // removed from the queue on this device and should not be re-added.
            let newQueueItems: [QueueItem] = newFromServer.compactMap { syncItem in
                let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
                
                // Skip episodes that are already played locally
                if let local = localEpisodes[guid], local.isPlayed {
                    logger.info("Queue sync: skipping played episode from server: \(syncItem.title ?? guid)")
                    return nil
                }
                
                let serverPos = Int(syncItem.positionSec ?? 0)
                
                // Try local episode first (has richest metadata)
                if let local = localEpisodes[guid] {
                    return QueueItem(
                        id: guid,
                        title: local.title,
                        podcastTitle: local.podcast?.title ?? syncItem.podcastTitle ?? "",
                        audioUrl: local.audioUrl ?? syncItem.episodeUrl,
                        artworkUrl: local.imageUrl ?? local.podcast?.logoUrl ?? syncItem.artworkUrl,
                        durationSeconds: local.durationSeconds ?? syncItem.durationSec.map { Int($0) },
                        positionSeconds: serverPos,
                        podcastUrl: syncItem.podcastUrl,
                        pubDate: local.pubDate,
                        podcastAuthor: local.podcast?.author,
                        episodeDescription: local.episodeDescription
                    )
                }
                
                // Fall back to server-provided metadata
                return QueueItem(
                    id: guid,
                    title: syncItem.title ?? "Unknown Episode",
                    podcastTitle: syncItem.podcastTitle ?? "",
                    audioUrl: syncItem.episodeUrl,
                    artworkUrl: syncItem.artworkUrl,
                    durationSeconds: syncItem.durationSec.map { Int($0) },
                    positionSeconds: serverPos,
                    podcastUrl: syncItem.podcastUrl,
                    pubDate: nil
                )
            }
            
            // Append new items to local queue
            if !newQueueItems.isEmpty {
                audioManager.appendToQueue(newQueueItems)
                logger.info("Queue sync: merged \(newQueueItems.count) new items from server")
            }
            
            // Step 3: PUSH — send the full merged queue to server
            var syncItems: [QueueSyncItem] = []
            
            if let current = audioManager.currentItem {
                syncItems.append(QueueSyncItem(
                    podcastUrl: current.podcastUrl,
                    episodeUrl: current.audioUrl,
                    episodeGuid: current.id,
                    sortOrder: 0,
                    positionSec: Double(current.positionSeconds),
                    title: current.title,
                    podcastTitle: current.podcastTitle,
                    artworkUrl: current.artworkUrl,
                    durationSec: current.durationSeconds.map { Double($0) }
                ))
            }
            
            let pushQueueCount = audioManager.queue.count
            let pushCurrentTitle = audioManager.currentItem?.title ?? "nil"
            logger.info("Queue sync PUSH: audioManager.queue has \(pushQueueCount) items, currentItem=\(pushCurrentTitle)")
            for (index, item) in audioManager.queue.enumerated() {
                // For conflicted items, push the SERVER position to preserve
                // server state until the user resolves the conflict
                let pushPosition = conflictedServerPositions[item.id] ?? Double(item.positionSeconds)
                syncItems.append(QueueSyncItem(
                    podcastUrl: item.podcastUrl,
                    episodeUrl: item.audioUrl,
                    episodeGuid: item.id,
                    sortOrder: (audioManager.currentItem != nil ? 1 : 0) + index,
                    positionSec: pushPosition,
                    title: item.title,
                    podcastTitle: item.podcastTitle,
                    artworkUrl: item.artworkUrl,
                    durationSec: item.durationSeconds.map { Double($0) }
                ))
            }
            logger.info("Queue sync PUSH: built \(syncItems.count) syncItems (before dedup)")
            for (i, si) in syncItems.enumerated() {
                logger.info("  PUSH[\(i)]: \(si.title ?? "nil") guid=\(si.episodeGuid ?? "nil") sortOrder=\(si.sortOrder) url=\(si.episodeUrl)")
            }
            
            // Deduplicate by episodeUrl
            var seenUrls = Set<String>()
            let deduped = syncItems.filter { seenUrls.insert($0.episodeUrl).inserted }
            
            // API spec (Build 122): server caps at 200 items — truncate locally
            // to avoid server-side silent truncation and sync loops.
            let truncated = Array(deduped.prefix(Self.maxQueueSyncItems))
            if deduped.count > Self.maxQueueSyncItems {
                logger.warning("Queue sync: truncated \(deduped.count) → \(truncated.count) items (API limit)")
            }
            
            // Snapshot the queue BEFORE the push await — any items added to the
            // queue during this await are "in-flight" and will be lost when
            // Step 4 ADOPT replaces the queue with the server response.
            let prePushQueueIds = Set(audioManager.queue.map(\.id))
            
            logger.info("Queue sync: pushing \(truncated.count) items to server (deduped from \(syncItems.count))")
            let syncResult = try await syncClient.syncQueue(items: truncated)
            let responseItems = syncResult.items
            let droppedItemsFromServer = syncResult.droppedItems
            logger.info("Queue sync: pushed \(truncated.count) items, got \(responseItems.count) back (explicitly dropped \(droppedItemsFromServer.count))")
            for (i, ri) in responseItems.enumerated() {
                logger.info("  RESPONSE[\(i)]: \(ri.title ?? "nil") guid=\(ri.episodeGuid ?? "nil") sortOrder=\(ri.sortOrder)")
            }
            
            // Detect items added locally while the push was in flight.
            // These items are NOT in the server response (the server only knows
            // about what was pushed). We must preserve them after adopt.
            let currentQueueAfterPush = audioManager.queue
            inFlightAdds = currentQueueAfterPush.filter { !prePushQueueIds.contains($0.id) }
            if !inFlightAdds.isEmpty {
                logger.info("Queue sync: detected \(inFlightAdds.count) items added during push — will preserve")
            }
            
            // Step 4: ADOPT — use the server's response as the final queue
            // Trust the server response array order as canonical — do NOT re-sort
            // by sortOrder integers (which may be stale or broken on the server).
            
            var seenAdoptedIds = Set<String>()
            let responseFiltered = responseItems
                .filter { ($0.episodeGuid ?? $0.episodeUrl) != currentId }
                .filter { item in
                    let guid = item.episodeGuid ?? item.episodeUrl
                    if seenAdoptedIds.contains(guid) { return false }
                    seenAdoptedIds.insert(guid)
                    return true
                }
            
            let localEpisodesForResponse = buildLocalEpisodeLookup(for: responseFiltered)
            
            // Build a set of GUIDs we explicitly pushed so we can trust them in ADOPT
            let adoptPushedGuids = Set(truncated.map { $0.episodeGuid ?? $0.episodeUrl })
            
            let finalQueue: [QueueItem] = responseFiltered.compactMap { syncItem in
                let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
                
                // Only filter played episodes that we did NOT push. If we pushed it,
                // the user intentionally has it in their queue (e.g., they marked it
                // as unplayed and re-added it). The episode action sync may have
                // re-marked it as played from stale server data — don't trust that.
                if !adoptPushedGuids.contains(guid),
                   let localEp = localEpisodesForResponse[guid], localEp.isPlayed {
                    logger.info("Queue sync adopt: skipping played episode (not in push): \(syncItem.title ?? guid)")
                    return nil
                }
                
                // Use the reconciled local queue for position lookup
                let localItem = audioManager.queue.first { $0.id == guid }
                let serverPos = Int(syncItem.positionSec ?? 0)
                let resolvedPosition: Int
                
                switch strategy {
                case .serverWins:
                    resolvedPosition = serverPos
                case .deviceWins:
                    if let localPos = localItem?.positionSeconds, localPos > 0 {
                        resolvedPosition = localPos
                    } else {
                        resolvedPosition = serverPos
                    }
                case .ask:
                    // For .ask, use the already-reconciled local position (from Step 2a)
                    // The conflict wizard will update later if the user chooses server
                    if let localPos = localItem?.positionSeconds, localPos > 0 {
                        resolvedPosition = localPos
                    } else {
                        resolvedPosition = serverPos
                    }
                }
                
                if let local = localEpisodesForResponse[guid] {
                    return QueueItem(
                        id: guid,
                        title: local.title,
                        podcastTitle: local.podcast?.title ?? syncItem.podcastTitle ?? "",
                        audioUrl: local.audioUrl ?? syncItem.episodeUrl,
                        artworkUrl: local.imageUrl ?? local.podcast?.logoUrl ?? syncItem.artworkUrl,
                        durationSeconds: local.durationSeconds ?? syncItem.durationSec.map { Int($0) },
                        positionSeconds: resolvedPosition,
                        podcastUrl: syncItem.podcastUrl,
                        pubDate: local.pubDate,
                        podcastAuthor: local.podcast?.author,
                        episodeDescription: local.episodeDescription
                    )
                }
                
                return QueueItem(
                    id: guid,
                    title: syncItem.title ?? localItem?.title ?? "Unknown Episode",
                    podcastTitle: syncItem.podcastTitle ?? localItem?.podcastTitle ?? "",
                    audioUrl: syncItem.episodeUrl,
                    artworkUrl: syncItem.artworkUrl ?? localItem?.artworkUrl,
                    durationSeconds: syncItem.durationSec.map { Int($0) } ?? localItem?.durationSeconds,
                    positionSeconds: resolvedPosition,
                    podcastUrl: syncItem.podcastUrl,
                    pubDate: localItem?.pubDate
                )
            }
            
            logger.info("Queue sync ADOPT: finalQueue has \(finalQueue.count) items (from \(responseFiltered.count) responseFiltered)")
            for (i, fq) in finalQueue.enumerated() {
                logger.info("  ADOPT[\(i)]: \(fq.title) id=\(fq.id.prefix(40))")
            }
            audioManager.replaceQueue(finalQueue)
            logger.info("Queue sync: adopted \(finalQueue.count) items from server response")
            
            // Re-append items that were added locally during the push await.
            // These were never part of the push payload, so they aren't in the
            // server response. They'll be pushed on the next debounced push.
            if !inFlightAdds.isEmpty {
                let adoptedIds = Set(finalQueue.map(\.id))
                let stillMissing = inFlightAdds.filter { !adoptedIds.contains($0.id) }
                if !stillMissing.isEmpty {
                    audioManager.appendToQueue(stillMissing)
                    logger.info("Queue sync: re-appended \(stillMissing.count) in-flight items after adopt")
                }
            }
            
            // Process items explicitly dropped by the server
            for dropped in droppedItemsFromServer {
                if dropped.reason == "web_deleted" {
                    logger.info("Queue sync: item deleted via web, dropping locally: \(dropped.title ?? "")")
                } else if dropped.reason == "completed" {
                    let guid = dropped.guid ?? dropped.episodeUrl
                    let localItem = currentQueueAfterPush.first { $0.id == guid }
                    if let localItem, !localItem.isPlayed {
                        // User is actively trying to re-listen
                        let position = Double(localItem.positionSeconds)
                        let duration = localItem.durationSeconds.map { Double($0) }
                        try? await syncClient.syncPlayback(
                            podcastUrl: localItem.podcastUrl,
                            episodeUrl: localItem.audioUrl,
                            episodeGuid: localItem.id,
                            positionSec: position,
                            durationSec: duration,
                            nowPlaying: false,
                            completed: false,
                            deviceId: self.deviceId
                        )
                        audioManager.appendToQueue([localItem])
                        logger.info("Queue sync: recovered completed item for re-listen: \(localItem.title)")
                    } else {
                        logger.info("Queue sync: item completed on server, dropping locally: \(dropped.title ?? "")")
                    }
                } else if dropped.reason == "capped" {
                    logger.warning("Queue sync: server capped queue at 200 items, dropping locally: \(dropped.title ?? "")")
                } else {
                    logger.info("Queue sync: server dropped item (\(dropped.reason)), dropping locally: \(dropped.title ?? "")")
                }
            }
            
            // Detect items we PUSHED but the server did NOT return AND did not report as explicitly dropped.
            // This happens when the server silently drops items (e.g., unique
            // constraint violation, INSERT failure, or server-side bug).
            // Preserve the local queue items so they aren't lost — the next
            // debounced push will retry sending them to the server.
            let pushedGuids = Set(truncated.compactMap(\.episodeGuid))
            let pushedUrls = Set(truncated.map(\.episodeUrl))
            let explicitDroppedGuids = Set(droppedItemsFromServer.compactMap(\.guid))
            let explicitDroppedUrls = Set(droppedItemsFromServer.map(\.episodeUrl))
            
            let serverReturnedIds = Set(serverItems.compactMap(\.episodeGuid))
            let serverReturnedUrls = Set(serverItems.map(\.episodeUrl))
            
            let silentlyDroppedItems = currentQueueAfterPush.filter { item in
                let wasPushed = pushedGuids.contains(item.id) || pushedUrls.contains(item.audioUrl)
                if !wasPushed { return false }
                
                // If the server returned it, it wasn't SILENTLY dropped by the server.
                // We might have chosen not to adopt it locally (e.g. because it is played),
                // but the server did its job.
                let returnedByServer = serverReturnedIds.contains(item.id) || serverReturnedUrls.contains(item.audioUrl)
                if returnedByServer { return false }
                
                let explicitlyDropped = explicitDroppedGuids.contains(item.id) || explicitDroppedUrls.contains(item.audioUrl)
                if explicitlyDropped { return false }
                
                return item.id != currentId  // Don't re-add current item
            }
            
            if !silentlyDroppedItems.isEmpty {
                audioManager.appendToQueue(silentlyDroppedItems)
                logger.warning("Queue sync: SERVER SILENTLY DROPPED \(silentlyDroppedItems.count) items — preserved locally: \(silentlyDroppedItems.map(\.title).joined(separator: ", "))")
            }
            
            // Mark that a queue sync has completed — enables stale item pruning
            // on subsequent syncs (Step 1.5). Without this flag, the first sync
            // on a new device would incorrectly prune legitimately queued episodes.
            UserDefaults.standard.set(true, forKey: "proQueueSyncCompleted")
            
            // Persist the server response GUIDs for the next sync's pruning comparison.
            // Only items in THIS set that disappear from the next server response
            // will be pruned — items the server has never seen are safe.
            // NOTE: Server-dropped items and in-flight items are included here
            // to protect them from being pruned on the next sync before the
            // retry push can get them to the server.
            var allServerGuids = finalQueue.map(\.id)
            if let currentId {
                allServerGuids.append(currentId)
            }
            // Include server-dropped items in the "known" set so they survive
            // the next sync's pruning step
            allServerGuids.append(contentsOf: silentlyDroppedItems.map(\.id))
            UserDefaults.standard.set(allServerGuids, forKey: Self.proQueueSyncServerGuidsKey)
            
        } catch {
            logger.error("Queue sync failed: \(error.localizedDescription)")
        }
        
        // If items were added during sync, trigger a debounced push so they
        // reach the server on the next cycle. isSyncingQueue is still true
        // here (cleared by defer), so we schedule via Task to let defer run first.
        if !inFlightAdds.isEmpty {
            Task { [weak self] in
                self?.pushQueueToProServerDebounced()
            }
        }
        
        return conflicts
    }
    
    /// Maximum number of queue items to sync with the server.
    /// API spec (Build 122): server silently truncates at 200.
    static let maxQueueSyncItems = 200
    
    /// UserDefaults key storing the GUIDs from the last successful server sync.
    /// Used by Step 1.5 pruning to distinguish "server-removed" items (should prune)
    /// from "locally-added, not yet pushed" items (should preserve).
    static let proQueueSyncServerGuidsKey = "proQueueSyncServerGuids"
    
    /// Debounce work item for queue push — prevents spamming the server
    /// when the user rapidly reorders or adds/removes queue items.
    private static let queuePushDebounceInterval: TimeInterval = 2.0
    private var queuePushTask: Task<Void, Never>?
    
    /// Push the full queue (currentItem + upcoming) to the Pro server.
    /// No-op for gPodder clients or Vault mode.
    func pushQueueToProServer() async {
        guard let syncClient, await syncClient.supportsQueueSync else { return }
        
        // Build the sync payload: currentItem (sortOrder 0) + queue items (sortOrder 1, 2, ...)
        var syncItems: [QueueSyncItem] = []
        
        if let current = audioManager.currentItem {
            syncItems.append(QueueSyncItem(
                podcastUrl: current.podcastUrl,
                episodeUrl: current.audioUrl,
                episodeGuid: current.id,
                sortOrder: 0,
                positionSec: Double(current.positionSeconds),
                title: current.title,
                podcastTitle: current.podcastTitle,
                artworkUrl: current.artworkUrl,
                durationSec: current.durationSeconds.map { Double($0) }
            ))
        }
        
        for (index, item) in audioManager.queue.enumerated() {
            syncItems.append(QueueSyncItem(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                sortOrder: (audioManager.currentItem != nil ? 1 : 0) + index,
                positionSec: Double(item.positionSeconds),
                title: item.title,
                podcastTitle: item.podcastTitle,
                artworkUrl: item.artworkUrl,
                durationSec: item.durationSeconds.map { Double($0) }
            ))
        }
        
        // Deduplicate by episodeUrl — server warned about duplicate entries.
        // Keep the first occurrence (currentItem has priority at sortOrder 0).
        var seenUrls = Set<String>()
        let deduped = syncItems.filter { seenUrls.insert($0.episodeUrl).inserted }
        
        // API spec (Build 122): server caps at 200 items — truncate locally.
        let truncated = Array(deduped.prefix(Self.maxQueueSyncItems))
        if deduped.count > Self.maxQueueSyncItems {
            logger.warning("pushQueue: truncated \(deduped.count) → \(truncated.count) items (API limit)")
        }
        
        do {
            let standaloneQueueCount = audioManager.queue.count
            let standaloneCurrentTitle = audioManager.currentItem?.title ?? "nil"
            logger.info("pushQueueToProServer: pushing \(truncated.count) items (queue=\(standaloneQueueCount), currentItem=\(standaloneCurrentTitle))")
            for (i, si) in truncated.enumerated() {
                logger.info("  STANDALONE_PUSH[\(i)]: \(si.title ?? "nil") guid=\(si.episodeGuid ?? "nil") sortOrder=\(si.sortOrder)")
            }
            try await syncClient.syncQueue(items: truncated)
            logger.info("Pushed \(truncated.count) queue items to Pro server")
        } catch {
            logger.error("Failed to push queue to Pro server: \(error.localizedDescription)")
        }
    }
    
    /// Push queue to Pro server with debouncing — call this from rapid-fire
    /// queue mutation callbacks (e.g., `onQueueChanged`).
    func pushQueueToProServerDebounced() {
        // Suppress debounced pushes while a full sync is running.
        // The sync's Step 3 PUSH handles the server update; concurrent
        // debounced pushes would race with it and could overwrite state.
        guard !isSyncingQueue else {
            logger.info("pushQueueToProServerDebounced: SUPPRESSED (isSyncingQueue=true)")
            return
        }
        logger.info("pushQueueToProServerDebounced: scheduling push in \(Self.queuePushDebounceInterval)s")
        
        queuePushTask?.cancel()
        queuePushTask = Task {
            try? await Task.sleep(for: .seconds(Self.queuePushDebounceInterval))
            guard !Task.isCancelled else { return }
            await pushQueueToProServer()
        }
    }
    
    /// Pull the server queue and REPLACE the local queue with it.
    /// After push-then-pull, the server is the source of truth.
    /// The currently-playing episode is preserved (not replaced from queue).
    /// No-op for gPodder clients or Vault mode.
    func pullQueueFromProServer() async {
        guard let syncClient, await syncClient.supportsQueueSync else { return }
        
        do {
            let serverItems = try await syncClient.getQueue()
            logger.info("Pulled \(serverItems.count) queue items from Pro server")
            
            // Filter out the currently-playing episode (don't re-add it to queue)
            let currentId = audioManager.currentItem?.id
            let filteredItems = serverItems
                .filter { $0.episodeGuid != currentId }
                .sorted { $0.sortOrder < $1.sortOrder }
            
            // Build a lookup of local episodes by guid for metadata enrichment
            let localEpisodes = buildLocalEpisodeLookup(for: filteredItems)
            
            // Respect the user's conflict strategy for position resolution
            let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
            
            // Build the complete replacement queue from server items
            let replacementQueue: [QueueItem] = filteredItems.compactMap { syncItem in
                let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
                
                // Determine position: server vs local
                let localItem = audioManager.queue.first { $0.id == guid }
                let serverPos = Int(syncItem.positionSec ?? 0)
                let resolvedPosition: Int
                
                switch strategy {
                case .serverWins:
                    resolvedPosition = serverPos
                case .deviceWins, .ask:
                    // Prefer local position if the item exists locally and has been played
                    if let localPos = localItem?.positionSeconds, localPos > 0 {
                        resolvedPosition = localPos
                    } else {
                        resolvedPosition = serverPos
                    }
                }
                
                // Try local episode first (has the richest metadata)
                if let local = localEpisodes[guid] {
                    return QueueItem(
                        id: guid,
                        title: local.title,
                        podcastTitle: local.podcast?.title ?? syncItem.podcastTitle ?? "",
                        audioUrl: local.audioUrl ?? syncItem.episodeUrl,
                        artworkUrl: local.imageUrl ?? local.podcast?.logoUrl ?? syncItem.artworkUrl,
                        durationSeconds: local.durationSeconds ?? syncItem.durationSec.map { Int($0) },
                        positionSeconds: resolvedPosition,
                        podcastUrl: syncItem.podcastUrl,
                        pubDate: local.pubDate,
                        podcastAuthor: local.podcast?.author,
                        episodeDescription: local.episodeDescription
                    )
                }
                
                // Fall back to server-provided metadata
                return QueueItem(
                    id: guid,
                    title: syncItem.title ?? "Unknown Episode",
                    podcastTitle: syncItem.podcastTitle ?? "",
                    audioUrl: syncItem.episodeUrl,
                    artworkUrl: syncItem.artworkUrl,
                    durationSeconds: syncItem.durationSec.map { Int($0) },
                    positionSeconds: resolvedPosition,
                    podcastUrl: syncItem.podcastUrl,
                    pubDate: nil
                )
            }
            
            // Full replacement: clear local queue and set server state as canonical
            audioManager.replaceQueue(replacementQueue)
            
            logger.info("Replaced queue with \(replacementQueue.count) items from server")
        } catch {
            logger.error("Failed to pull queue from Pro server: \(error.localizedDescription)")
        }
    }
    
    /// Build a lookup dictionary of local episodes by GUID and audioUrl for the given sync items.
    /// Uses PodcastManager's subscription data to find matching episodes.
    /// Indexes by both GUID and audioUrl so server items using either identifier can match.
    private func buildLocalEpisodeLookup(for syncItems: [QueueSyncItem]) -> [String: Episode] {
        guard let podcastManager else { return [:] }
        
        var lookup: [String: Episode] = [:]
        let guidSet = Set(syncItems.compactMap { $0.episodeGuid })
        let urlSet = Set(syncItems.map(\.episodeUrl))
        
        for podcast in podcastManager.subscriptions {
            for episode in podcast.episodes {
                if guidSet.contains(episode.guid) {
                    lookup[episode.guid] = episode
                }
                // Also index by audioUrl for lookups when episodeGuid is nil
                if let audioUrl = episode.audioUrl, urlSet.contains(audioUrl) {
                    lookup[audioUrl] = episode
                }
            }
        }
        return lookup
    }

    /// Convert a server `QueueSyncItem` into a local `QueueItem`.
    /// Used by the fresh-device adoption path to build the queue from server data.
    private func buildQueueItemFromSyncItem(_ syncItem: QueueSyncItem) -> QueueItem {
        let guid = syncItem.episodeGuid ?? syncItem.episodeUrl
        var item = QueueItem(
            id: guid,
            title: syncItem.title ?? "Unknown Episode",
            podcastTitle: syncItem.podcastTitle ?? "",
            audioUrl: syncItem.episodeUrl,
            artworkUrl: syncItem.artworkUrl,
            durationSeconds: syncItem.durationSec.map { Int($0) },
            positionSeconds: Int(syncItem.positionSec ?? 0),
            podcastUrl: syncItem.podcastUrl,
            pubDate: nil
        )
        
        // Apply per-podcast settings so server-synced queue items aren't left
        // with default 0/0/1.0 skip/speed values. The settingsResolver in
        // AudioManager will re-resolve at play time anyway, but this ensures
        // the QueueItem carries correct values for UI display and persistence.
        if let podcast = podcastManager?.subscriptions.first(where: { $0.url == syncItem.podcastUrl }),
           let episode = podcast.episodes.first(where: { $0.guid == guid }) {
            item = applyEffectiveSettings(item, episode: episode)
        }
        
        return item
    }

    
    // MARK: - Sync Conflict Resolution
    
    /// If the resolved conflict's episode is currently loaded, seek the player
    /// **and** explicitly update the position metadata so that:
    /// 1. Cold-start play() uses the resolved position (not the stale local one)
    /// 2. The progress tracker doesn't overwrite Episode.listenedSeconds with stale data
    /// 3. Queue persistence saves the resolved position for app relaunch
    ///
    /// Called by SyncConflictSheet after resolving a conflict via PodcastManager.
    func resolveConflictIfPlaying(_ conflict: SyncConflict, chosenPosition: Int) {
        guard currentEpisodeGuid == conflict.episodeGuid else {
            // Not the currently-playing episode — no seek needed
            return
        }
        logger.info("Seeking to resolved position \(chosenPosition) for currently-playing episode \(conflict.episodeGuid)")
        
        // Explicitly update position metadata BEFORE seeking.
        // AVPlayer.seek() is a no-op when there's no loaded player item (cold start),
        // and the periodic time observer won't fire to update currentPosition.
        // Without these explicit updates, play() → cold-start path uses the stale local position.
        audioManager.currentPosition = TimeInterval(chosenPosition)
        audioManager.currentItem?.positionSeconds = chosenPosition
        
        seek(to: TimeInterval(chosenPosition))
    }
    
    /// Resolve a queue-level sync conflict by updating the queue item's position.
    /// Called from the SyncConflictSheet when the user picks "Use Device" or "Use Server"
    /// for queue items.
    func resolveQueueConflict(_ conflict: SyncConflict, chosenPosition: Int) {
        // Update the queue item's position
        let queue = audioManager.queue
        if let index = queue.firstIndex(where: { $0.id == conflict.episodeGuid }) {
            let item = queue[index]
            let updated = QueueItem(
                id: item.id,
                title: item.title,
                podcastTitle: item.podcastTitle,
                audioUrl: item.audioUrl,
                artworkUrl: item.artworkUrl,
                durationSeconds: item.durationSeconds,
                positionSeconds: chosenPosition,
                podcastUrl: item.podcastUrl,
                pubDate: item.pubDate,
                podcastAuthor: item.podcastAuthor,
                episodeDescription: item.episodeDescription
            )
            var newQueue = queue
            newQueue[index] = updated
            audioManager.replaceQueue(newQueue)
            logger.info("Resolved queue conflict for \(conflict.episodeGuid) → position \(chosenPosition)")
        }
        
        // Also update the current item if it matches — both seek AND metadata
        if let current = audioManager.currentItem, current.id == conflict.episodeGuid {
            audioManager.currentPosition = TimeInterval(chosenPosition)
            audioManager.currentItem?.positionSeconds = chosenPosition
            seek(to: TimeInterval(chosenPosition))
        }
        
        // Push the resolved position to the server
        Task {
            await pushQueueToProServer()
        }
    }
    
    // MARK: - Post-Sync Queue Cleanup
    
    /// Removes episodes from the AudioManager queue (and currentItem) that have been
    /// marked as `isPlayed` in SwiftData by episode action sync.
    ///
    /// Called after `applyEpisodeActions` in the sync orchestrator to bridge the gap
    /// between SwiftData updates and AudioManager state.
    ///
    /// Guards:
    /// - Skips items with no matching SwiftData Episode (server-only queue items)
    /// - Skips items whose Episode is not played
    /// - Uses `markCurrentEpisodeAsPlayed(fromSync: true)` for the current item
    ///   to prevent outbound action echo
    func clearPlayedEpisodesFromQueue(podcastManager: PodcastManager) {
        // Check currentItem first — query SwiftData for played status
        if let current = audioManager.currentItem,
           podcastManager.isEpisodePlayed(guid: current.id) {
            logger.info("clearPlayedEpisodesFromQueue: clearing played currentItem '\(current.title)'")
            markCurrentEpisodeAsPlayed(fromSync: true)
        }
        
        // Remove played items from the Up Next queue
        let beforeCount = audioManager.queue.count
        let filtered = audioManager.queue.filter { !podcastManager.isEpisodePlayed(guid: $0.id) }
        if filtered.count < beforeCount {
            audioManager.replaceQueue(filtered)
            logger.info("clearPlayedEpisodesFromQueue: removed \(beforeCount - filtered.count) played items from queue")
        }
    }
    
    // MARK: - Pro: Now Playing Sync
    
    /// Pushes the currently-playing episode to the Pro server with `nowPlaying` flag.
    /// This tells the web player (and other devices) which episode is active.
    /// No-op for gPodder clients or Vault mode.
    func syncNowPlayingToProServer(nowPlaying: Bool = true, completed: Bool? = nil) {
        guard let item = audioManager.currentItem,
              let syncClient else { return }
        
        let pos = currentPosition
        let dur = item.durationSeconds.map { Double($0) } ?? (currentDuration > 0 ? currentDuration : nil)
        let device = deviceId
        
        Task {
            do {
                try await syncClient.syncPlayback(
                    podcastUrl: item.podcastUrl,
                    episodeUrl: item.audioUrl,
                    episodeGuid: item.id,
                    positionSec: pos,
                    durationSec: dur,
                    nowPlaying: nowPlaying,
                    completed: completed,
                    deviceId: device
                )
                logger.info("Synced nowPlaying=\(nowPlaying) completed=\(String(describing: completed)) for: \(item.title)")
            } catch {
                logger.error("Failed to sync nowPlaying: \(error.localizedDescription)")
            }
        }
    }
    
    /// Overload that also clears the previous episode's nowPlaying state.
    /// Called when the user manually switches episodes or auto-advance fires.
    func syncNowPlayingToProServer(nowPlaying: Bool = true, clearingPrevious previousItem: QueueItem?) {
        // Bug 2 fix: Clear the previous episode's nowPlaying before setting the new one
        if let previousItem, let syncClient {
            let prevPos = Double(previousItem.positionSeconds)
            let prevDur = previousItem.durationSeconds.map { Double($0) }
            let device = deviceId
            Task {
                do {
                    try await syncClient.syncPlayback(
                        podcastUrl: previousItem.podcastUrl,
                        episodeUrl: previousItem.audioUrl,
                        episodeGuid: previousItem.id,
                        positionSec: prevPos,
                        durationSec: prevDur,
                        nowPlaying: false,
                        completed: nil,
                        deviceId: device
                    )
                    logger.info("Cleared nowPlaying for previous: \(previousItem.title)")
                } catch {
                    logger.error("Failed to clear previous nowPlaying: \(error.localizedDescription)")
                }
            }
        }
        // Now set the new episode as nowPlaying
        syncNowPlayingToProServer(nowPlaying: nowPlaying)
    }
    
    /// Sends `completed: true, nowPlaying: false` for a specific finished episode.
    /// Unlike `syncNowPlayingToProServer`, this takes the completed item explicitly
    /// rather than reading `audioManager.currentItem` (which may have already
    /// auto-advanced to the next episode).
    ///
    /// Bug 1 fix: The old code called `syncNowPlayingToProServer(completed: true)`
    /// which read `audioManager.currentItem` — but auto-advance had already changed
    /// it to the NEXT episode, so `completed: true` was sent for the wrong episode.
    func syncCompletedEpisodeToProServer(_ item: QueueItem) {
        guard let syncClient else { return }
        
        let totalDuration = Double(item.durationSeconds ?? 0)
        let device = deviceId
        
        Task {
            do {
                try await syncClient.syncPlayback(
                    podcastUrl: item.podcastUrl,
                    episodeUrl: item.audioUrl,
                    episodeGuid: item.id,
                    positionSec: totalDuration,
                    durationSec: totalDuration,
                    nowPlaying: false,
                    completed: true,
                    deviceId: device
                )
                logger.info("Synced completed=true for finished episode: \(item.title)")
            } catch {
                logger.error("Failed to sync completed episode: \(error.localizedDescription)")
            }
        }
    }
    
    /// Tracks the previous currentItem so it can be cleared on the server
    /// when the user switches to a new episode.
    private var _previousItem: QueueItem?
    
    /// Store the current item as "previous" before an episode switch.
    func trackPreviousItem(_ item: QueueItem) {
        _previousItem = item
    }
    
    /// Immediately flushes any pending stats events to the Pro server.
    ///
    /// Called on:
    /// - App entering background (`.scenePhase == .background`)
    /// - Playback pause
    /// - Episode end / auto-advance
    ///
    /// No-op if the user is not authenticated with a YourPods Pro client,
    /// or if there are no pending events to upload.
    func flushStatsIfAuthenticated() {
        guard let proClient = syncClient as? YourPodsProClient else { return }
        
        Task {
            let events = await statsBuffer.flush()
            guard !events.isEmpty else { return }
            
            do {
                try await proClient.pushStatsEvents(events)
                logger.info("Flushed \(events.count) stats events on trigger")
            } catch {
                logger.error("Stats flush failed — restoring \(events.count) events: \(error.localizedDescription)")
                await statsBuffer.restore(events)
            }
        }
    }

    /// Overload that accepts a pre-fetched server state captured BEFORE the
    /// nowPlaying push (Step 5b). This prevents the push from overwriting the
    /// server's `completed: true` flag before reconciliation can read it.
    ///
    /// - Parameter preFetchedState: The server state captured before Step 5b pushed.
    ///   This method uses it directly instead of calling `getCurrentPlayback()`.
    func reconcileNowPlayingWithServer(preFetchedState: ProPlaybackState?) async {
        // Guard: Nothing to reconcile if no episode is loaded
        guard audioManager.currentItem != nil else {
            logger.info("reconcileNowPlaying(preFetched): skipping — no current item loaded")
            return
        }
        
        // Use the pre-fetched state directly — no network call
        await performReconciliation(with: preFetchedState)
    }

    /// Reconciles the local now-playing state with the Pro server during foreground sync.
    ///
    /// Called as Step 5c in `ProSyncOrchestrator`, after pushing nowPlaying (Step 5b).
    /// Uses the server's `completed` flag as the authoritative signal — no client-side
    /// heuristics (95% threshold, action map, etc.).
    ///
    /// Cases:
    /// 1. Server's current episode is `completed: true` → mark played, advance
    /// 2. Server's current episode is different from local → load server's episode
    ///    (do NOT mark local as played — it may be legitimately in progress on this device)
    /// 3. Server returns nil (no active playback) → no-op (nil ≠ completed;
    ///    server may not have received our nowPlaying push yet, or may have no state)
    /// 4. Same episode, different position → reconcile using syncConflictStrategy
    /// 5. Not a Pro client → no-op
    ///
    /// The `isPlaying` guard is applied per-case rather than globally:
    /// - `completed: true` + playing → defer (never mark playing episode as completed)
    /// - Different episode + playing → log and defer to queue sync
    /// - Same episode + playing → no-op (don't seek during active playback)
    /// - All cases when paused → full reconciliation
    func reconcileNowPlayingWithServer() async {
        // Guard 2: Nothing to reconcile if no episode is loaded
        guard audioManager.currentItem != nil else {
            logger.info("reconcileNowPlaying: skipping — no current item loaded")
            return
        }
        
        // Guard 3: Only supported for clients that implement playback reconciliation.
        // gPodder/Vault default to false — they don't have the /playback/current endpoint.
        guard let client = syncClient else {
            return
        }
        
        let supportsReconciliation = await client.supportsPlaybackReconciliation
        guard supportsReconciliation else {
            return
        }
        
        do {
            let serverState = try await client.getCurrentPlayback()
            await performReconciliation(with: serverState)
        } catch {
            logger.error("reconcileNowPlaying failed: \(error.localizedDescription)")
        }
    }
    
    /// Shared reconciliation logic used by both the parameterless and pre-fetched overloads.
    /// Accepts the server state directly — no network calls.
    private func performReconciliation(with serverState: ProPlaybackState?) async {
        guard let currentItem = audioManager.currentItem else { return }
        let isPlaying = audioManager.isPlaying
        
        if let state = serverState {
            if state.completed == true {
                // Case 1: Server says the current episode is finished
                guard !isPlaying else {
                    logger.info("reconcileNowPlaying: server=completed but playing — deferring")
                    return
                }
                logger.info("reconcileNowPlaying: server reports completed — marking as played")
                markCurrentEpisodeAsPlayed(fromSync: true)
            } else if state.episodeUrl != currentItem.audioUrl {
                // Case 2: Server is playing a different episode
                guard !isPlaying else {
                    // Log and defer — queue sync will handle item membership.
                    // Don't interrupt active playback.
                    logger.info("reconcileNowPlaying: server has '\(state.title ?? "?")' but playing '\(currentItem.title)' — deferring to queue sync")
                    return
                }
                // Paused → safe to switch to server's episode
                logger.info("reconcileNowPlaying: server playing different episode — switching (local preserved)")
                
                let item = QueueItem(
                    id: state.episodeGuid ?? state.episodeUrl,
                    title: state.title ?? "Unknown Episode",
                    podcastTitle: state.podcastTitle ?? "",
                    audioUrl: state.episodeUrl,
                    artworkUrl: state.artUrl,
                    durationSeconds: state.durationSec.map { Int($0) },
                    positionSeconds: Int(state.positionSec),
                    podcastUrl: state.podcastUrl,
                    pubDate: nil
                )
                await audioManager.playEpisode(item, initialPosition: state.positionSec, preserveCurrent: false)
                audioManager.pause()  // Load at position but don't auto-play
            } else {
                // Case 3: Same episode — reconcile position if needed
                guard !isPlaying else { return }
                
                let serverPos = Int(state.positionSec)
                let localPos = currentItem.positionSeconds
                let diff = abs(serverPos - localPos)
                
                // Skip noise — position differences ≤10s are not worth reconciling
                guard diff > 10 else { return }
                
                let strategy = settingsManager?.syncConflictStrategy ?? .serverWins
                switch strategy {
                case .serverWins:
                    logger.info("reconcileNowPlaying: adopting server position \(serverPos)s (was \(localPos)s)")
                    audioManager.currentItem?.positionSeconds = serverPos
                    audioManager.seek(to: state.positionSec)
                case .deviceWins:
                    // Keep local position
                    break
                case .ask:
                    // Silently adopt if one side is 0 (never played); otherwise defer
                    if localPos == 0 || serverPos == 0 {
                        let adoptPos = max(serverPos, localPos)
                        audioManager.currentItem?.positionSeconds = adoptPos
                        audioManager.seek(to: Double(adoptPos))
                    }
                }
            }
        } else {
            // Case 4: No active playback on server — this is a no-op.
            // Nil means "the server has no active playback state" (confirmed by
            // server SQL: rows are filtered by completed=FALSE). It does NOT mean
            // the current episode is completed. Common causes:
            //   - Episode started locally but nowPlaying not pushed yet (sync ordering)
            //   - Server transient error
            //   - User just started listening
            logger.info("reconcileNowPlaying: no server playback state — preserving local item (nil ≠ completed)")
        }
    }

    /// Checks the Pro server for a `nowPlaying` episode from another device.
    /// If found and no episode is currently loaded locally, loads it into the player
    /// at the server's last position. The episode loads ready to play — the user
    /// presses play when ready, just like any queue-restored episode.
    ///
    /// Guards:
    /// - No-op if an episode is already loaded locally (queue restore takes priority)
    /// - No-op for gPodder clients or Vault mode (protocol default returns nil)
    /// - Skips stale states (updatedAt > 24h ago)
    /// - Skips completed episodes
    func restoreNowPlayingFromProServer() async {
        guard audioManager.currentItem == nil,
              let client = syncClient else { return }
        
        do {
            guard let state = try await client.getCurrentPlayback(),
                  state.nowPlaying == true,
                  state.completed != true else { return }
            
            // Staleness guard: don't restore episodes from more than 24 hours ago
            if let updatedAtStr = state.updatedAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let updatedAt = formatter.date(from: updatedAtStr)
                    ?? ISO8601DateFormatter().date(from: updatedAtStr) {
                    let age = Date().timeIntervalSince(updatedAt)
                    if age > 24 * 3600 {
                        logger.info("Skipping stale nowPlaying state (age: \(Int(age / 3600))h)")
                        return
                    }
                }
            }
            
            // Build a QueueItem from server state
            let item = QueueItem(
                id: state.episodeGuid ?? state.episodeUrl,
                title: state.title ?? "Unknown Episode",
                podcastTitle: state.podcastTitle ?? "",
                audioUrl: state.episodeUrl,
                artworkUrl: state.artUrl,
                durationSeconds: state.durationSec.map { Int($0) },
                positionSeconds: Int(state.positionSec),
                podcastUrl: state.podcastUrl,
                pubDate: nil
            )
            
            logger.info("Restoring nowPlaying from server: \(item.title) at \(Int(state.positionSec))s")
            await audioManager.playEpisode(item, initialPosition: state.positionSec, preserveCurrent: false)
            audioManager.pause()  // Load at position but don't auto-play
        } catch {
            logger.error("Failed to restore nowPlaying: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Progress Calculation
    
    /// Calculates playback progress as a fraction clamped to [0, 1].
    /// Use this everywhere progress is displayed to avoid overflow/underflow.
    nonisolated static func playbackProgress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
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


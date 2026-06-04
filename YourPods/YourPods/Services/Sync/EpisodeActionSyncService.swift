import Foundation
import SwiftData
import os

/// Isolated service for episode action synchronization.
///
/// Owns the action map (listen positions), conflict tracking, and all
/// episode action sync operations (pull/push/apply). Extracted from
/// PodcastManager to isolate concerns and reduce God Object risk.
///
/// Dependencies are injected via closures to avoid tight coupling:
/// - `subscriptionsProvider`: returns current podcast subscriptions
/// - `syncClientProvider`: returns the active sync client (nil in Vault mode)
/// - `profileIdProvider`: returns the active profile ID for timestamp keys
@MainActor
final class EpisodeActionSyncService {
    
    // MARK: - Completion Threshold
    
    /// Calculates the effective "complete" position in seconds, accounting for
    /// the podcast's skipOutroSeconds. For episodes with large outros, the threshold
    /// is lowered so that reaching the content end (before the outro) counts as complete.
    ///
    /// - Parameters:
    ///   - totalDuration: Episode duration in seconds.
    ///   - skipOutroSeconds: The podcast's configured outro skip duration (0 if unset).
    /// - Returns: The position (in seconds) at or above which the episode is "effectively complete."
    static func effectiveCompletionThreshold(totalDuration: Int, skipOutroSeconds: Int) -> Int {
        guard totalDuration > 60 else { return totalDuration }
        
        let standard = Int(Double(totalDuration) * 0.95)
        let outroAdjusted = totalDuration - max(skipOutroSeconds, 0)
        let minimumFloor = Int(Double(totalDuration) * 0.80)
        
        // Use the lower of 95% or (total - skipOutro), but never go below 80%
        return max(minimumFloor, min(standard, outroAdjusted))
    }
    
    // MARK: - State
    
    /// Map of episode GUID → latest EpisodeAction (listen position, timestamp).
    /// Source of truth for server-reported listen positions.
    private(set) var actionMap: [String: EpisodeAction] = [:]
    
    /// Per-episode conflict occurrence counts (for "ask" strategy UI).
    private var conflictCounts: [String: Int] = [:]
    
    // MARK: - ActionMap Persistence Throttle
    
    /// Timestamp of the last `persistActionMap()` disk write.
    private var lastActionMapPersistTime: Date = .distantPast
    
    /// Throttle interval for actionMap persistence (60 seconds).
    /// Critical save points (sync completion, app backgrounding) use
    /// `forcePersistActionMap()` to bypass this throttle.
    private static let actionMapPersistInterval: TimeInterval = 60
    
    /// Counter for test observability — tracks how many times `persistActionMap()` was called.
    private(set) var actionMapPersistCount: Int = 0
    
    // MARK: - Episode Index (O(1) lookup for large libraries)
    
    /// Flat lookup index for episodes — avoids O(N×M) nested loops in metadata lookups.
    struct EpisodeIndex {
        let byGuid: [String: (episode: Episode, podcast: Podcast)]
        let byAudioUrl: [String: (episode: Episode, podcast: Podcast)]
        let byGuidCaseInsensitive: [String: (episode: Episode, podcast: Podcast)]
    }
    
    /// Build a flat lookup index from the current subscriptions.
    /// O(N) once, then O(1) per lookup instead of O(N×M) per lookup.
    func buildEpisodeIndex() -> EpisodeIndex {
        var byGuid: [String: (episode: Episode, podcast: Podcast)] = [:]
        var byAudioUrl: [String: (episode: Episode, podcast: Podcast)] = [:]
        var byGuidCI: [String: (episode: Episode, podcast: Podcast)] = [:]
        for podcast in subscriptions {
            for episode in podcast.episodes {
                let entry = (episode: episode, podcast: podcast)
                byGuid[episode.guid] = entry
                byGuidCI[episode.guid.lowercased()] = entry
                if let url = episode.audioUrl {
                    byAudioUrl[url] = entry
                }
            }
        }
        return EpisodeIndex(byGuid: byGuid, byAudioUrl: byAudioUrl, byGuidCaseInsensitive: byGuidCI)
    }
    
    // MARK: - File-Based ActionMap Persistence
    
    /// File URL for the action map JSON file (replaces UserDefaults for large maps).
    /// Stub — returns a placeholder path until implemented.
    static var actionMapFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("episodeActionMap.json")
    }
    
    // MARK: - Dependencies (injected)
    
    private let modelContext: ModelContext
    private let subscriptionsProvider: () -> [Podcast]
    private let syncClientProvider: () -> SyncClient?
    private let profileIdProvider: () -> String?
    private let deviceIdProvider: () -> String
    private let queueItemsProvider: () -> [QueueItem]
    
    /// Pre-save store health check. Returns `true` if the store is safe to write.
    /// Injected for testability — production uses `StoreHealthProbe.rawWriteProbe`.
    private let storeHealthCheck: () -> Bool
    
    private let logger = Logger(subsystem: "com.yourpods", category: "episodeActionSync")
    
    // MARK: - Init
    
    init(
        modelContext: ModelContext,
        subscriptionsProvider: @escaping () -> [Podcast],
        syncClientProvider: @escaping () -> SyncClient?,
        profileIdProvider: @escaping () -> String?,
        deviceIdProvider: @escaping () -> String,
        queueItemsProvider: @escaping () -> [QueueItem] = { [] },
        storeHealthCheck: @escaping () -> Bool = { true }
    ) {
        self.modelContext = modelContext
        self.subscriptionsProvider = subscriptionsProvider
        self.syncClientProvider = syncClientProvider
        self.profileIdProvider = profileIdProvider
        self.deviceIdProvider = deviceIdProvider
        self.queueItemsProvider = queueItemsProvider
        self.storeHealthCheck = storeHealthCheck
    }
    
    // MARK: - Convenience accessors
    
    private var subscriptions: [Podcast] { subscriptionsProvider() }
    private var syncClient: SyncClient? { syncClientProvider() }
    private var activeProfileId: String? { profileIdProvider() }
    private var deviceId: String { deviceIdProvider() }
    
    /// Update the queue items provider after initialization.
    /// Called from YourPodsApp.init() once AudioManager is available.
    func setQueueItemsProvider(_ provider: @escaping () -> [QueueItem]) {
        // Work around the let-binding by using a mutable wrapper.
        // Since this is called once during app bootstrap, the overhead is negligible.
        self._mutableQueueItemsProvider = provider
    }
    private var _mutableQueueItemsProvider: (() -> [QueueItem])?
    
    // MARK: - Sync Episode Actions (Pull from Server)
    
    /// Pull episode actions from the server and merge into the local action map.
    ///
    /// - Parameters:
    ///   - force: When true, pulls all history (since=0). Otherwise uses incremental timestamp.
    ///   - strategy: How to resolve conflicts between local and server positions.
    /// - Returns: Unresolved conflicts for user review (only when strategy is `.ask`).
    func syncEpisodeActions(force: Bool = true, strategy: SyncStrategy = .serverWins) async throws -> [SyncConflict] {
        guard let client = syncClient else {
            logger.info("No sync client — skipping episode action sync")
            return []
        }
        
        // When force=true, pull ALL history (since=0).
        // Otherwise use the last sync timestamp for incremental sync.
        let epProfileId = activeProfileId ?? "global"
        let since = force ? 0 : UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(epProfileId)")
        logger.info("Fetching episode actions since \(since) (force=\(force))...")
        
        let actions = try await client.getEpisodeActions(since: since)
        logger.info("Received \(actions.count) episode actions from server")
        
        var conflicts: [SyncConflict] = []
        
        for action in actions {
            let key = action.guid ?? action.episode
            let existing = actionMap[key]
            
            if let existing, let existingPos = existing.position, let newPos = action.position {
                // Only overwrite actionMap when the server action is newer
                if action.timestamp >= existing.timestamp {
                    actionMap[key] = action
                }
                
                // Skip conflict when local position is 0 — episode hasn't been
                // touched on this device, so server position is authoritative.
                // This prevents conflict spam on first sync.
                guard existingPos > 0 else { continue }
                
                if abs(existingPos - newPos) > 5 {
                    // Same-device check: if both the existing actionMap entry and
                    // the incoming server action are from THIS device, the gap is
                    // a stale-disk persistence artifact (background RunLoop throttling),
                    // not a real cross-device conflict. Silently keep the newest.
                    if existing.device != nil && existing.device == deviceId,
                       action.device != nil && action.device == deviceId {
                        // Already handled by the timestamp check above — just skip conflict.
                        continue
                    }
                    
                    // Look up episode/podcast metadata for the conflict UI.
                    // When the key is a GUID, also try the audio URL as fallback.
                    let (epTitle, podTitle, podUrl, artUrl, audioUrl, totalDur) = lookupEpisodeMetadata(guid: key, audioUrlFallback: action.episode)
                    
                    // Skip conflict for episodes already marked as played
                    let isAlreadyPlayed = isEpisodePlayed(guid: key, audioUrlFallback: action.episode)
                    
                    // Skip conflict for episodes that are effectively complete
                    // (either position is ≥ the smart completion threshold)
                    let isEffectivelyComplete: Bool = {
                        guard let total = totalDur, total > 60 else { return false }
                        let skipOutro = lookupSkipOutroSeconds(guid: key, audioUrlFallback: action.episode)
                        let threshold = Self.effectiveCompletionThreshold(totalDuration: total, skipOutroSeconds: skipOutro)
                        return existingPos >= threshold || newPos >= threshold
                    }()
                    
                    // Skip conflicts for episodes with no resolvable metadata.
                    // These are orphaned actionMap entries (e.g., from podcasts the user
                    // unsubscribed from) that can't be displayed meaningfully to the user.
                    // Single episodes from search are covered by the queue items fallback.
                    let isResolvable = epTitle != nil
                    
                    if !isAlreadyPlayed && !isEffectivelyComplete && isResolvable {
                        let count = incrementConflictCount(for: key)
                        conflicts.append(SyncConflict(
                            episodeGuid: key,
                            episodeTitle: epTitle,
                            podcastTitle: podTitle,
                            podcastUrl: podUrl,
                            artworkUrl: artUrl,
                            audioUrl: audioUrl,
                            localPosition: existingPos,
                            serverPosition: newPos,
                            serverTimestamp: action.timestamp,
                            totalDuration: totalDur,
                            occurrenceCount: count
                        ))
                    } else if !isResolvable {
                        logger.debug("Skipping conflict for unresolvable episode: \(key)")
                    }
                }
            } else {
                // No existing entry — just store the server action
                actionMap[key] = action
            }
        }
        
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: "lastEpisodeActionSync_\(epProfileId)")
        persistActionMap()
        
        // Apply synced positions to Episode objects using the cooperative async variant.
        // The async path checks Task.isCancelled and calls Task.yield() between per-podcast
        // saves, preventing watchdog kills during background refresh and allowing graceful
        // exit when BGAppRefreshTask expires.
        let applyConflicts = await applyEpisodeActionsAsync(strategy: strategy)
        
        // Merge conflicts — deduplicate by episodeGuid, prefer applyConflicts (has richer metadata)
        let applyGuids = Set(applyConflicts.map(\.episodeGuid))
        let uniqueActionMapConflicts = conflicts.filter { !applyGuids.contains($0.episodeGuid) }
        let allConflicts = uniqueActionMapConflicts + applyConflicts
        
        let totalStored = self.actionMap.count
        logger.info("Episode action sync complete: \(actions.count) received, \(totalStored) total stored, \(allConflicts.count) conflicts")
        return allConflicts
    }
    
    // MARK: - Apply Episode Actions (Update Models)
    
    /// Apply the action map to Episode model objects to update listen progress.
    @discardableResult
    func applyEpisodeActions(strategy: SyncStrategy = .serverWins) -> [SyncConflict] {
        let (conflicts, _) = applyEpisodeActionsWithStats(strategy: strategy)
        return conflicts
    }
    
    /// Async variant that yields cooperatively and respects cancellation.
    func applyEpisodeActionsAsync(strategy: SyncStrategy = .serverWins) async -> [SyncConflict] {
        let (conflicts, _) = await applyEpisodeActionsCore(strategy: strategy, cooperative: true)
        return conflicts
    }
    
    /// Async variant of applyEpisodeActionsWithStats.
    func applyEpisodeActionsWithStatsAsync(strategy: SyncStrategy = .serverWins) async -> ([SyncConflict], Int) {
        return await applyEpisodeActionsCore(strategy: strategy, cooperative: true)
    }
    
    /// Cross-podcast batch save threshold.
    /// Saves are batched across podcasts to reduce WAL checkpoint overhead.
    /// With 5000 episodes, this yields ~10 saves instead of ~100 per-podcast saves.
    private static let crossPodcastSaveBatchSize = 500
    
    /// Synchronous variant with save count stats.
    func applyEpisodeActionsWithStats(strategy: SyncStrategy = .serverWins) -> ([SyncConflict], Int) {
        // Pre-validate store health before attempting any saves.
        // modelContext.save() can trigger a WAL checkpoint that crashes with
        // guarded_pwrite_np / pread if pages are corrupt. The sqlite3 C API
        // probe returns an error code instead of crashing with a signal.
        if !storeHealthCheck() {
            logger.warning("Store health check failed — skipping episode action apply to prevent WAL crash")
            return ([], 0)
        }
        
        var updatedCount = 0
        var saveCount = 0
        var unresolvedConflicts: [SyncConflict] = []
        var dirtyAcrossPodcasts = 0
        
        for podcast in subscriptions {
            let (podcastConflicts, podcastUpdated) = applyActionsForPodcast(
                podcast, strategy: strategy, cooperative: false
            )
            unresolvedConflicts.append(contentsOf: podcastConflicts)
            updatedCount += podcastUpdated
            dirtyAcrossPodcasts += podcastUpdated
            
            // Batch save across podcasts
            if dirtyAcrossPodcasts >= Self.crossPodcastSaveBatchSize {
                do {
                    try modelContext.save()
                    saveCount += 1
                } catch {
                    logger.error("Batch save failed at \(updatedCount) episodes: \(error.localizedDescription)")
                }
                dirtyAcrossPodcasts = 0
            }
        }
        
        // Final save for remaining dirty episodes
        if dirtyAcrossPodcasts > 0 {
            do {
                try modelContext.save()
                saveCount += 1
            } catch {
                logger.error("Final save failed at \(updatedCount) episodes: \(error.localizedDescription)")
            }
        }
        
        logger.info("Applied listen status (sync) to \(updatedCount) episodes (strategy: \(strategy.rawValue), \(unresolvedConflicts.count) unresolved, \(saveCount) saves)")
        return (unresolvedConflicts, saveCount)
    }
    
    /// Unified async core with cooperative yielding support.
    func applyEpisodeActionsCore(strategy: SyncStrategy, cooperative: Bool) async -> ([SyncConflict], Int) {
        // Pre-validate store health before attempting any saves.
        // modelContext.save() can trigger a WAL checkpoint that crashes with
        // guarded_pwrite_np / pread if pages are corrupt. The sqlite3 C API
        // probe returns an error code instead of crashing with a signal.
        if !storeHealthCheck() {
            logger.warning("Store health check failed — skipping episode action apply to prevent WAL crash")
            return ([], 0)
        }
        
        var updatedCount = 0
        var saveCount = 0
        var unresolvedConflicts: [SyncConflict] = []
        var dirtyAcrossPodcasts = 0
        
        for podcast in subscriptions {
            if cooperative && Task.isCancelled {
                logger.info("applyEpisodeActionsCore cancelled after \(updatedCount) episodes (\(saveCount) saves)")
                return (unresolvedConflicts, saveCount)
            }
            
            let (podcastConflicts, podcastUpdated) = applyActionsForPodcast(
                podcast, strategy: strategy, cooperative: cooperative
            )
            unresolvedConflicts.append(contentsOf: podcastConflicts)
            updatedCount += podcastUpdated
            dirtyAcrossPodcasts += podcastUpdated
            
            // Cross-podcast batch save
            if dirtyAcrossPodcasts >= Self.crossPodcastSaveBatchSize {
                if cooperative && Task.isCancelled {
                    logger.info("Skipping save — task cancelled (\(updatedCount) episodes mutated, \(saveCount) saves completed)")
                    return (unresolvedConflicts, saveCount)
                }
                do {
                    try modelContext.save()
                    saveCount += 1
                } catch {
                    logger.error("Batch save failed at \(updatedCount) episodes: \(error.localizedDescription)")
                }
                dirtyAcrossPodcasts = 0
            }
            
            if cooperative {
                await Task.yield()
            }
        }
        
        // Final save for remaining dirty episodes
        if dirtyAcrossPodcasts > 0 {
            if !(cooperative && Task.isCancelled) {
                do {
                    try modelContext.save()
                    saveCount += 1
                } catch {
                    logger.error("Final save failed at \(updatedCount) episodes: \(error.localizedDescription)")
                }
            }
        }
        
        let modeLabel = cooperative ? "async/cooperative" : "sync"
        logger.info("Applied listen status (\(modeLabel)) to \(updatedCount) episodes (strategy: \(strategy.rawValue), \(unresolvedConflicts.count) unresolved, \(saveCount) saves)")
        return (unresolvedConflicts, saveCount)
    }
    
    /// Shared per-podcast episode action processing.
    ///
    /// Processes all episodes for a single podcast: looks up actions in the action map,
    /// applies the strategy (serverWins/deviceWins/ask), marks played at 95%, and saves
    /// in batched autoreleasepools.
    ///
    /// **Crash fix (Build 54):** `modelContext.save()` is now called OUTSIDE the
    /// autoreleasepool. Previously, `save()` was inside the pool, which drained
    /// temporary NSString bridge objects before Core Data finished column comparison
    /// in `-[NSSQLRow newColumnMaskFrom:columnInclusionOptions:]`, causing a
    /// `__CFStringEqual` signal crash. Moving save outside ensures all bridged
    /// strings remain alive until after the save completes.
    /// Shared per-podcast episode action processing.
    ///
    /// Processes all episodes for a single podcast: looks up actions in the action map,
    /// applies the strategy (serverWins/deviceWins/ask), marks played at 95%.
    ///
    /// **Performance fix (Build 75):** Saves are now handled by the caller
    /// (`applyEpisodeActionsCore` / `applyEpisodeActionsWithStats`) using cross-podcast
    /// batch saves. This reduces save count from O(podcasts) to O(total_episodes/500).
    ///
    /// **Crash fix (Build 54):** Episode mutations happen inside autoreleasepools
    /// but saves happen outside — prevents `__CFStringEqual` signal crash from
    /// bridged NSString temporaries being drained before Core Data's column diff.
    private func applyActionsForPodcast(
        _ podcast: Podcast,
        strategy: SyncStrategy,
        cooperative: Bool = false
    ) -> (conflicts: [SyncConflict], updated: Int) {
        var updatedCount = 0
        var unresolvedConflicts: [SyncConflict] = []
        
        let conflictThreshold = 10
        let batchSize = 50
        let episodes = podcast.episodes
        
        for batchStart in stride(from: 0, to: episodes.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, episodes.count)
            
            // Mutate episode properties inside the autoreleasepool to contain
            // temporary Obj-C objects from SwiftData property access.
            autoreleasepool {
                for i in batchStart..<batchEnd {
                    let episode = episodes[i]
                    
                    let action = actionMap[episode.guid] ?? (episode.audioUrl.flatMap { actionMap[$0] })
                    guard let action else { continue }
                    
                    if let serverPosition = action.position, serverPosition > 0 {
                        let localPosition = episode.listenedSeconds
                        
                        switch strategy {
                        case .serverWins:
                            episode.listenedSeconds = serverPosition
                            
                        case .deviceWins:
                            if localPosition == 0 {
                                episode.listenedSeconds = serverPosition
                            }
                            // When localPosition > 0, device position is always kept
                            
                        case .ask:
                            if episode.isPlayed {
                                episode.listenedSeconds = max(localPosition, serverPosition)
                            } else {
                                let total = episode.durationSeconds ?? 0
                                let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                                let completionThreshold = Self.effectiveCompletionThreshold(totalDuration: total, skipOutroSeconds: skipOutro)
                                let isEffectivelyComplete = total > 60 && (
                                    localPosition >= completionThreshold ||
                                    serverPosition >= completionThreshold
                                )
                                
                                if isEffectivelyComplete {
                                    episode.listenedSeconds = max(localPosition, serverPosition)
                                } else if localPosition == 0 {
                                    episode.listenedSeconds = serverPosition
                                } else if abs(serverPosition - localPosition) > conflictThreshold {
                                    // Same-device check: if the actionMap entry was written by
                                    // THIS device, the gap is a stale SwiftData disk save from
                                    // iOS background RunLoop throttling, not a real cross-device
                                    // conflict. Silently adopt max(local, server).
                                    if action.device != nil && action.device == deviceId {
                                        episode.listenedSeconds = max(localPosition, serverPosition)
                                    } else {
                                        let count = incrementConflictCount(for: episode.guid)
                                        unresolvedConflicts.append(SyncConflict(
                                            episodeGuid: episode.guid,
                                            episodeTitle: episode.title,
                                            podcastTitle: podcast.title,
                                            podcastUrl: podcast.url,
                                            artworkUrl: episode.imageUrl ?? podcast.logoUrl,
                                            audioUrl: episode.audioUrl,
                                            localPosition: localPosition,
                                            serverPosition: serverPosition,
                                            serverTimestamp: action.timestamp,
                                            totalDuration: episode.durationSeconds,
                                            occurrenceCount: count
                                        ))
                                    }
                                } else {
                                    episode.listenedSeconds = max(localPosition, serverPosition)
                                }
                            }
                        }
                    }
                    
                    // Mark as played if position is at or past the completion threshold.
                    // Fall back to episode.durationSeconds when the server action
                    // doesn't include a `total` field (optional in gPodder spec).
                    let effectiveTotal = action.total ?? episode.durationSeconds
                    if let position = action.position, let total = effectiveTotal, total > 60, position > 60 {
                        let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                        let completionThreshold = Self.effectiveCompletionThreshold(totalDuration: total, skipOutroSeconds: skipOutro)
                        if position >= completionThreshold {
                            episode.isPlayed = true
                        }
                    }
                    
                    updatedCount += 1
                }
            }
        }
        
        return (unresolvedConflicts, updatedCount)
    }
    
    // MARK: - Send / Get Actions
    
    /// Push a single episode action to the server and update local map.
    func sendEpisodeAction(_ action: EpisodeAction) async {
        actionMap[action.guid ?? action.episode] = action
        throttledPersistActionMap()
        guard let client = syncClient else { return }
        _ = try? await client.uploadEpisodeActions([action])
    }
    
    /// Persist action map with 60s throttle — for hot-path calls during playback.
    /// Reduces UserDefaults write pressure from ~2,640 writes/22h to ~44 writes/22h.
    private func throttledPersistActionMap() {
        let now = Date()
        guard now.timeIntervalSince(lastActionMapPersistTime) >= Self.actionMapPersistInterval else { return }
        lastActionMapPersistTime = now
        persistActionMap()
    }
    
    /// Force-persist action map, bypassing the 60s throttle.
    /// Call on sync completion, conflict resolution, and app backgrounding.
    func forcePersistActionMap() {
        lastActionMapPersistTime = Date()
        persistActionMap()
    }
    
    /// Look up the latest action for an episode by GUID.
    func getLatestAction(for guid: String) -> EpisodeAction? {
        actionMap[guid]
    }
    
    /// Update the action map locally without uploading to server.
    /// Used by batch operations (e.g., markAllEpisodesAsPlayed) that handle
    /// persistence and upload separately.
    func sendActionLocally(_ action: EpisodeAction) {
        actionMap[action.guid ?? action.episode] = action
    }
    
    // MARK: - Conflict Resolution
    
    /// Resolve a sync conflict by updating the local model, actionMap, and server.
    func resolveConflict(_ conflict: SyncConflict, chosenPosition: Int) {
        // 1. Update local Episode.listenedSeconds
        updateEpisodeProgressByGuid(episodeGuid: conflict.episodeGuid, position: chosenPosition)
        
        // 2. Build an EpisodeAction with the resolved position
        let action = EpisodeAction(
            podcast: conflict.podcastUrl ?? "",
            episode: conflict.audioUrl ?? "",
            guid: conflict.episodeGuid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: chosenPosition,
            started: 0,
            total: conflict.totalDuration ?? chosenPosition,
            device: deviceId
        )
        
        // 3. Update actionMap so next sync won't re-detect this conflict
        actionMap[conflict.episodeGuid] = action
        persistActionMap()
        
        // 4. Clear conflict count since user resolved it
        clearConflictCount(for: conflict.episodeGuid)
        
        // 5. Upload to server
        Task {
            guard let client = syncClient else { return }
            do {
                _ = try await client.uploadEpisodeActions([action])
                logger.info("Uploaded conflict resolution for \(conflict.episodeGuid) at position \(chosenPosition)")
            } catch {
                logger.error("Failed to upload conflict resolution: \(error.localizedDescription)")
            }
        }
    }
    
    /// Update episode listened position by GUID (for conflict resolution).
    private func updateEpisodeProgressByGuid(episodeGuid: String, position: Int) {
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }) {
                episode.listenedSeconds = position
                if storeHealthCheck() {
                    modelContext.safeSave()
                }
                return
            }
        }
    }
    
    // MARK: - Metadata Lookup
    
    /// Look up episode metadata from subscriptions for conflict display.
    /// Searches by episode GUID first, then falls back to audioUrl match
    /// (needed when server actions have no guid field — common with gPodder).
    /// Final fallback: check the playback queue for episodes added without subscribing.
    private func lookupEpisodeMetadata(guid: String, audioUrlFallback: String? = nil) -> (episodeTitle: String?, podcastTitle: String?, podcastUrl: String?, artworkUrl: String?, audioUrl: String?, totalDuration: Int?) {
        let guidLower = guid.lowercased()
        
        for podcast in subscriptions {
            // Primary lookup: match by episode GUID (exact)
            if let episode = podcast.episodes.first(where: { $0.guid == guid }) {
                return (
                    episode.title,
                    podcast.title,
                    podcast.url,
                    episode.imageUrl ?? podcast.logoUrl,
                    episode.audioUrl,
                    episode.durationSeconds
                )
            }
            // Case-insensitive GUID fallback: UUIDs are case-insensitive per RFC 4122,
            // and gPodder servers may return GUIDs in different case than the RSS feed.
            if let episode = podcast.episodes.first(where: { $0.guid.lowercased() == guidLower }) {
                return (
                    episode.title,
                    podcast.title,
                    podcast.url,
                    episode.imageUrl ?? podcast.logoUrl,
                    episode.audioUrl,
                    episode.durationSeconds
                )
            }
            // Fallback: match by audioUrl (when the action key is a URL, not a GUID)
            if let episode = podcast.episodes.first(where: { $0.audioUrl == guid }) {
                return (
                    episode.title,
                    podcast.title,
                    podcast.url,
                    episode.imageUrl ?? podcast.logoUrl,
                    episode.audioUrl,
                    episode.durationSeconds
                )
            }
            // Fallback 2: try the separate audio URL when the key was a GUID
            if let fallbackUrl = audioUrlFallback, fallbackUrl != guid,
               let episode = podcast.episodes.first(where: { $0.audioUrl == fallbackUrl }) {
                return (
                    episode.title,
                    podcast.title,
                    podcast.url,
                    episode.imageUrl ?? podcast.logoUrl,
                    episode.audioUrl,
                    episode.durationSeconds
                )
            }
        }
        
        // Fallback: check queue items (for single episodes added without subscribing)
        let queueItems = (_mutableQueueItemsProvider ?? queueItemsProvider)()
        if let item = queueItems.first(where: { $0.id == guid }) {
            return (
                item.title,
                item.podcastTitle,
                item.podcastUrl,
                item.artworkUrl,
                item.audioUrl,
                item.durationSeconds
            )
        }
        // Case-insensitive queue item ID match
        if let item = queueItems.first(where: { $0.id.lowercased() == guidLower }) {
            return (
                item.title,
                item.podcastTitle,
                item.podcastUrl,
                item.artworkUrl,
                item.audioUrl,
                item.durationSeconds
            )
        }
        if let item = queueItems.first(where: { $0.audioUrl == guid }) {
            return (
                item.title,
                item.podcastTitle,
                item.podcastUrl,
                item.artworkUrl,
                item.audioUrl,
                item.durationSeconds
            )
        }
        // Fallback 2: try separate audio URL in queue items
        if let fallbackUrl = audioUrlFallback, fallbackUrl != guid,
           let item = queueItems.first(where: { $0.audioUrl == fallbackUrl || $0.id == fallbackUrl }) {
            return (
                item.title,
                item.podcastTitle,
                item.podcastUrl,
                item.artworkUrl,
                item.audioUrl,
                item.durationSeconds
            )
        }
        
        return (nil, nil, nil, nil, nil, nil)
    }
    
    /// Look up the podcast's `skipOutroSeconds` setting for an episode.
    /// Returns 0 if not found or not set.
    private func lookupSkipOutroSeconds(guid: String, audioUrlFallback: String? = nil) -> Int {
        let guidLower = guid.lowercased()
        for podcast in subscriptions {
            let matched = podcast.episodes.contains {
                $0.guid == guid ||
                $0.guid.lowercased() == guidLower ||
                $0.audioUrl == guid ||
                (audioUrlFallback != nil && $0.audioUrl == audioUrlFallback)
            }
            if matched {
                return podcast.effectiveSettings.skipOutroSeconds ?? 0
            }
        }
        return 0
    }
    
    /// Check if an episode is already marked as played (used to skip conflict detection).
    /// Searches by GUID first, then falls back to audioUrl match.
    private func isEpisodePlayed(guid: String, audioUrlFallback: String? = nil) -> Bool {
        let guidLower = guid.lowercased()
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == guid }) {
                return episode.isPlayed
            }
            // Case-insensitive GUID fallback (matches lookupEpisodeMetadata logic)
            if let episode = podcast.episodes.first(where: { $0.guid.lowercased() == guidLower }) {
                return episode.isPlayed
            }
            if let episode = podcast.episodes.first(where: { $0.audioUrl == guid }) {
                return episode.isPlayed
            }
            if let fallbackUrl = audioUrlFallback, fallbackUrl != guid,
               let episode = podcast.episodes.first(where: { $0.audioUrl == fallbackUrl }) {
                return episode.isPlayed
            }
        }
        return false
    }
    
    /// Load action map from UserDefaults (legacy/migration) or file (primary).
    ///
    /// Order: UserDefaults first (for backward compat during migration and tests),
    /// then file. When UserDefaults data is found, it's migrated to file and the
    /// key is removed.
    func loadActionMap() {
        // 1. Check UserDefaults first (migration path + test compat)
        if let data = UserDefaults.standard.data(forKey: "episodeActionMap"),
           let decoded = try? JSONDecoder().decode([String: EpisodeAction].self, from: data) {
            self.actionMap = decoded
            let count = self.actionMap.count
            logger.info("Migrated \(count) episode actions from UserDefaults to file")
            // Persist to file and remove legacy key
            persistActionMap()
            UserDefaults.standard.removeObject(forKey: "episodeActionMap")
            return
        }
        
        // 2. Load from file (primary persistence after migration)
        let fileURL = Self.actionMapFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([String: EpisodeAction].self, from: data)
                self.actionMap = decoded
                let count = self.actionMap.count
                logger.info("Loaded \(count) persisted episode actions from file")
            } catch {
                logger.error("Failed to load action map from file: \(error.localizedDescription)")
            }
        }
    }
    
    /// Persist action map to a dedicated JSON file.
    /// Uses atomic writes to prevent partial-write corruption.
    func persistActionMap() {
        actionMapPersistCount += 1
        do {
            let data = try JSONEncoder().encode(actionMap)
            let fileURL = Self.actionMapFileURL
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist action map to file: \(error.localizedDescription)")
        }
    }
    
    /// Test-only: override lastActionMapPersistTime to simulate time passing.
    func testOverrideLastActionMapPersistTime(_ date: Date) {
        lastActionMapPersistTime = date
    }
    
    /// Replace the entire action map and persist (used by pruning).
    func replaceActionMap(_ newMap: [String: EpisodeAction]) {
        actionMap = newMap
        persistActionMap()
    }
    
    /// Clear the action map and conflict counts (used during Force Pull).
    func clearActionMapAndConflicts() {
        actionMap.removeAll()
        conflictCounts.removeAll()
        persistActionMap()
        persistConflictCounts()
    }
    
    // MARK: - Conflict Count Tracking
    
    /// Load conflict counts from UserDefaults.
    func loadConflictCounts() {
        if let data = UserDefaults.standard.data(forKey: "syncConflictCounts"),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            conflictCounts = decoded
        }
    }
    
    @discardableResult
    private func incrementConflictCount(for guid: String) -> Int {
        let count = (conflictCounts[guid] ?? 0) + 1
        conflictCounts[guid] = count
        persistConflictCounts()
        return count
    }
    
    private func clearConflictCount(for guid: String) {
        conflictCounts.removeValue(forKey: guid)
        persistConflictCounts()
    }
    
    private func persistConflictCounts() {
        if let data = try? JSONEncoder().encode(conflictCounts) {
            UserDefaults.standard.set(data, forKey: "syncConflictCounts")
        }
    }
    
    // MARK: - Hidden Episodes Store
    
    /// Set of episode GUIDs that the user has hidden.
    /// Hidden episodes have `isPlayed = true` and are tracked here
    /// so the "Show Hidden" toggle can reveal them distinctly from
    /// genuinely-played episodes.
    private(set) var hiddenEpisodeGuids: Set<String> = []
    
    /// Check if an episode is hidden.
    func isHidden(guid: String) -> Bool {
        hiddenEpisodeGuids.contains(guid)
    }
    
    /// Mark an episode as hidden or unhidden.
    /// When hiding: sets `episode.isPlayed = true` and adds to hidden set.
    /// When unhiding: sets `episode.isPlayed = false` and removes from hidden set.
    ///
    /// Guard: when `hidden = false` and the episode was never in the hidden set,
    /// skip the `isPlayed` mutation entirely. This prevents the sync from
    /// clobbering `isPlayed = true` on genuinely-played, never-hidden episodes
    /// when the server returns `hidden: false` for every non-hidden playback state.
    func setHidden(guid: String, hidden: Bool) {
        let wasHidden = hiddenEpisodeGuids.contains(guid)
        
        if hidden {
            hiddenEpisodeGuids.insert(guid)
        } else {
            hiddenEpisodeGuids.remove(guid)
        }
        
        // Only mutate isPlayed when the hidden state actually changes.
        // When unhiding: only reset isPlayed if the episode was previously hidden
        // (don't clobber isPlayed for genuinely-played, never-hidden episodes).
        // When hiding: always set isPlayed = true (hidden episodes are filtered as played).
        guard hidden || wasHidden else { return }
        
        // Update the Episode model's isPlayed flag
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == guid }) {
                episode.isPlayed = hidden
                if storeHealthCheck() {
                    modelContext.safeSave()
                }
                break
            }
        }
    }
    
    /// Returns the GUIDs of hidden episodes belonging to a specific podcast.
    func hiddenGuids(for podcast: Podcast) -> [String] {
        podcast.episodes
            .map(\.guid)
            .filter { hiddenEpisodeGuids.contains($0) }
    }
    
    /// Load hidden GUIDs from UserDefaults.
    func loadHiddenGuids() {
        guard let data = UserDefaults.standard.data(forKey: "hiddenEpisodeGuids"),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return
        }
        hiddenEpisodeGuids = decoded
    }
    
    /// Persist hidden GUIDs to UserDefaults.
    func persistHiddenGuids() {
        if let data = try? JSONEncoder().encode(hiddenEpisodeGuids) {
            UserDefaults.standard.set(data, forKey: "hiddenEpisodeGuids")
        }
    }
}

import Foundation
import SwiftData
import CoreData
import os

/// Background write actor for the sync pipeline.
///
/// Owns a private `ModelContext` created lazily inside actor isolation,
/// ensuring the executor is the actor's (background) — NOT the calling
/// actor's. This avoids the `@ModelActor` gotcha where the context runs
/// on main if the actor is instantiated from `@MainActor`.
///
/// All save operations run through `SuspensionGuard` via `safeSave()` to
/// prevent 0xDEAD10CC suspension kills during SQLite write transactions.
///
/// The context uses `NSMergeByPropertyObjectTrumpMergePolicy` so saves
/// don't conflict with the main context's concurrent saves (e.g. the
/// progress timer updating `listenedSeconds` every 60s).
actor SyncStore {
    private let container: ModelContainer
    private let storeURL: URL?
    private let storeHealthCheck: @Sendable () -> Bool
    private let logger = Logger(subsystem: "com.yourpods", category: "syncStore")

    private var _context: ModelContext?

    init(
        container: ModelContainer,
        storeURL: URL? = nil,
        storeHealthCheck: @escaping @Sendable () -> Bool = { true }
    ) {
        self.container = container
        self.storeURL = storeURL
        self.storeHealthCheck = storeHealthCheck
    }

    /// Lazily-created context that runs on this actor's executor.
    /// `autosaveEnabled = false` — all saves are explicit via `safeSave()`.
    ///
    /// Merge policy is set directly on the `NSManagedObjectContext` obtained from
    /// `NSPersistentContainer`, bypassing the `underlyingNSContext` path which
    /// returns nil for background contexts in Xcode 26 (Apple removed `_nsContext`).
    private var context: ModelContext {
        if let c = _context { return c }
        let c = ModelContext(container)
        c.autosaveEnabled = false
        // Set merge policy directly — don't rely on underlyingNSContext which
        // may be nil for background contexts in Xcode 26.
        // Try the Mirror path first (works pre-Xcode 26):
        if let nsCtx = Mirror(reflecting: c)
            .children.first(where: { $0.label == "_nsContext" })?
            .value as? NSManagedObjectContext {
            nsCtx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        }
        // Also try via ModelContext.underlyingNSContext for completeness:
        c.applyObjectTrumpMergePolicy()
        _context = c
        return c
    }

    /// Internal accessor for test helpers. Production code uses `context` directly.
    var testContext: ModelContext { context }

    /// Returns whether the current thread is the main thread.
    /// Used by tests to verify actor isolation runs off-main.
    func checkIsMainThread() -> Bool {
        Thread.isMainThread
    }

    /// Returns the ObjectIdentifier of the actor's ModelContext.
    /// Used by tests to verify it's a different context than mainContext.
    func contextObjectID() -> ObjectIdentifier {
        ObjectIdentifier(context)
    }


    /// Save the background context with SuspensionGuard protection
    /// and optional store-health pre-check.
    @discardableResult
    func save() -> Bool {
        if let storeURL {
            return context.guardedSave(storeURL: storeURL)
        }
        return context.safeSave()
    }

    // MARK: - Episode Action Apply

    /// Cross-podcast batch save threshold.
    private static let crossPodcastSaveBatchSize = 500

    /// Apply episode actions to Episode models on this actor's background context.
    ///
    /// Ported from `EpisodeActionSyncService.applyEpisodeActionsCore` — preserves
    /// every invariant: 500-episode cross-podcast batching, cancellation gates,
    /// health-check probing, cooperative yields, autoreleasepool layout.
    ///
    /// - Parameters:
    ///   - actionMap: Map of episode GUID → latest action. Snapshot from MainActor.
    ///   - strategy: How to resolve local vs. server position conflicts.
    ///   - deviceId: This device's ID, for same-device conflict suppression.
    ///   - currentlyPlayingGuidProvider: MainActor-isolated read of the GUID the user is
    ///     currently playing. Re-evaluated once **per podcast** (the `await` hops to the
    ///     MainActor for a live value) so an episode the user switches to mid-loop is also
    ///     excluded — a single up-front snapshot would miss the switch and let the
    ///     background write clobber the live position (two-writer race).
    /// - Returns: Outcome with conflicts, counts, and newly-played GUIDs.
    /// - Parameter completionIsServerAuthoritative: when true the caller's profile receives
    ///   completion as an explicit side-channel and the sync contract forbids re-deriving it
    ///   from position here. This actor carries its own copy of the heuristic, so a guard on
    ///   the MainActor path alone would leave the copy that actually runs during a sync.
    func applyEpisodeActions(
        actionMap: [String: EpisodeAction],
        strategy: SyncStrategy,
        deviceId: String,
        completionIsServerAuthoritative: Bool = false,
        currentlyPlayingGuidProvider: (@MainActor @Sendable () -> String?)? = nil
    ) async -> EpisodeActionApplyOutcome {

        // Cancellation gate BEFORE the write probe
        if Task.isCancelled {
            logger.info("applyEpisodeActions cancelled before start — skipping")
            return .empty
        }

        // Pre-validate store health
        if !storeHealthCheck() {
            logger.warning("Store health check failed — skipping episode action apply")
            return .empty
        }

        // Fetch all podcasts with their episodes on our background context
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? context.fetch(descriptor) else {
            logger.error("Failed to fetch podcasts for episode action apply")
            return .empty
        }

        var updatedCount = 0
        var saveCount = 0
        var conflicts: [SyncConflict] = []
        var newlyPlayedGuids: [String] = []
        var dirtyAcrossPodcasts = 0
        var skippedActionsForPlaying: [EpisodeAction] = []

        for podcast in podcasts {
            if Task.isCancelled {
                logger.info("applyEpisodeActions cancelled after \(updatedCount) episodes (\(saveCount) saves)")
                return EpisodeActionApplyOutcome(
                    conflicts: conflicts, updatedCount: updatedCount,
                    saveCount: saveCount, newlyPlayedGuids: newlyPlayedGuids,
                    skippedActionsForPlayingEpisodes: skippedActionsForPlaying
                )
            }

            // Re-read the live now-playing GUID per podcast (the `await` hops to the
            // MainActor). The inter-podcast `Task.yield()` below is exactly when the user
            // can switch episodes, so a value snapshotted once at the top would miss the
            // switch and let this background write clobber the new episode's live position.
            var currentlyPlayingGuid: String?
            if let provider = currentlyPlayingGuidProvider { currentlyPlayingGuid = await provider() }

            let (podcastConflicts, podcastUpdated, podcastNewlyPlayed, podcastSkipped) = applyActionsForPodcast(
                podcast, actionMap: actionMap, strategy: strategy,
                deviceId: deviceId,
                completionIsServerAuthoritative: completionIsServerAuthoritative,
                currentlyPlayingGuid: currentlyPlayingGuid
            )
            conflicts.append(contentsOf: podcastConflicts)
            updatedCount += podcastUpdated
            dirtyAcrossPodcasts += podcastUpdated
            newlyPlayedGuids.append(contentsOf: podcastNewlyPlayed)
            if let podcastSkipped { skippedActionsForPlaying.append(podcastSkipped) }

            // Cross-podcast batch save
            if dirtyAcrossPodcasts >= Self.crossPodcastSaveBatchSize {
                if Task.isCancelled {
                    logger.info("Skipping save — task cancelled (\(updatedCount) episodes mutated, \(saveCount) saves)")
                    return EpisodeActionApplyOutcome(
                        conflicts: conflicts, updatedCount: updatedCount,
                        saveCount: saveCount, newlyPlayedGuids: newlyPlayedGuids,
                        skippedActionsForPlayingEpisodes: skippedActionsForPlaying
                    )
                }
                guard storeHealthCheck() else {
                    logger.warning("Store health check failed mid-loop — aborting (\(updatedCount) mutated, \(saveCount) saves)")
                    return EpisodeActionApplyOutcome(
                        conflicts: conflicts, updatedCount: updatedCount,
                        saveCount: saveCount, newlyPlayedGuids: newlyPlayedGuids,
                        skippedActionsForPlayingEpisodes: skippedActionsForPlaying
                    )
                }
                if save() { saveCount += 1 }
                dirtyAcrossPodcasts = 0
            }

            await Task.yield()
        }

        // Final save for remaining dirty episodes
        if dirtyAcrossPodcasts > 0 {
            if !(Task.isCancelled) {
                guard storeHealthCheck() else {
                    logger.warning("Store health check failed before final save")
                    return EpisodeActionApplyOutcome(
                        conflicts: conflicts, updatedCount: updatedCount,
                        saveCount: saveCount, newlyPlayedGuids: newlyPlayedGuids,
                        skippedActionsForPlayingEpisodes: skippedActionsForPlaying
                    )
                }
                if save() { saveCount += 1 }
            }
        }

        logger.info("Applied episode actions (background): \(updatedCount) episodes, \(conflicts.count) conflicts, \(saveCount) saves")
        return EpisodeActionApplyOutcome(
            conflicts: conflicts, updatedCount: updatedCount,
            saveCount: saveCount, newlyPlayedGuids: newlyPlayedGuids,
            skippedActionsForPlayingEpisodes: skippedActionsForPlaying
        )
    }

    /// Per-podcast episode action processing — ported from
    /// `EpisodeActionSyncService.applyActionsForPodcast`.
    ///
    /// Mutations happen inside autoreleasepools; saves happen in the caller.
    private func applyActionsForPodcast(
        _ podcast: Podcast,
        actionMap: [String: EpisodeAction],
        strategy: SyncStrategy,
        deviceId: String,
        completionIsServerAuthoritative: Bool,
        currentlyPlayingGuid: String?
    ) -> (conflicts: [SyncConflict], updated: Int, newlyPlayed: [String], skippedAction: EpisodeAction?) {
        var updatedCount = 0
        var unresolvedConflicts: [SyncConflict] = []
        var newlyPlayed: [String] = []
        var skippedAction: EpisodeAction?

        let conflictThreshold = SyncThresholds.applyConflictGapSeconds
        let batchSize = 50
        let episodes = podcast.episodes

        for batchStart in stride(from: 0, to: episodes.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, episodes.count)

            autoreleasepool {
                for i in batchStart..<batchEnd {
                    let episode = episodes[i]

                    // Skip the currently-playing episode to avoid racing
                    // with the 60-second progress timer on MainActor.
                    // Capture the action so the caller can apply it on main.
                    if let playingGuid = currentlyPlayingGuid, episode.guid == playingGuid {
                        let action = actionMap[episode.guid] ?? (episode.audioUrl.flatMap { actionMap[$0] })
                        if let action { skippedAction = action }
                        continue
                    }

                    let action = actionMap[episode.guid] ?? (episode.audioUrl.flatMap { actionMap[$0] })
                    guard let action else { continue }

                    let wasPlayed = episode.isPlayed

                    if let serverPosition = action.position, serverPosition > 0 {
                        let localPosition = episode.listenedSeconds

                        switch strategy {
                        case .serverWins:
                            episode.setListenedSecondsIfChanged(serverPosition)

                        case .deviceWins:
                            if localPosition == 0 {
                                episode.setListenedSecondsIfChanged(serverPosition)
                            }

                        case .ask:
                            if episode.isPlayed {
                                episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                            } else {
                                let total = episode.durationSeconds ?? 0
                                let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                                let completionThreshold = EpisodeActionSyncService.effectiveCompletionThreshold(
                                    totalDuration: total, skipOutroSeconds: skipOutro
                                )
                                let isEffectivelyComplete = total > 60 && (
                                    localPosition >= completionThreshold ||
                                    serverPosition >= completionThreshold
                                )

                                if isEffectivelyComplete {
                                    episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                                } else if localPosition == 0 {
                                    episode.setListenedSecondsIfChanged(serverPosition)
                                } else if abs(serverPosition - localPosition) > conflictThreshold {
                                    if action.device != nil && action.device == deviceId {
                                        episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                                    } else {
                                        // SyncStore doesn't track occurrenceCount — that stays
                                        // on MainActor's EpisodeActionSyncService.
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
                                            occurrenceCount: 0
                                        ))
                                    }
                                } else {
                                    episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                                }
                            }
                        }
                    }

                    // Mark as played if position passes completion threshold. Skipped
                    // entirely when the server owns the flag (per the sync contract).
                    let effectiveTotal = action.total ?? episode.durationSeconds
                    if !completionIsServerAuthoritative,
                       let position = action.position, let total = effectiveTotal,
                       total > 60, position > 60 {
                        let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                        let completionThreshold = EpisodeActionSyncService.effectiveCompletionThreshold(
                            totalDuration: total, skipOutroSeconds: skipOutro
                        )
                        if position >= completionThreshold {
                            episode.markPlayedIfNeeded()
                        }
                    }

                    if !wasPlayed && episode.isPlayed {
                        newlyPlayed.append(episode.guid)
                    }
                    updatedCount += 1
                }
            }
        }

        return (unresolvedConflicts, updatedCount, newlyPlayed, skippedAction)
    }

    // MARK: - Feed Result Apply

    /// Apply parsed RSS feed results to podcast metadata and episodes.
    ///
    /// Ported from `PodcastManager.applyFeedResult` — handles metadata updates,
    /// new episode inserts, existing episode metadata updates, and stale marking.
    /// Feed URL migrations (itunes:new-feed-url) are detected and returned as
    /// `FeedURLMigration` values; the caller handles profile (dis)association.
    ///
    /// Single `guardedSave` at end (matching today's single-save shape).
    func applyFeedResults(_ results: [FeedFetchResult]) async -> FeedApplyOutcome {
        guard !Task.isCancelled else {
            logger.info("applyFeedResults cancelled before start — skipping")
            return .empty
        }

        // Pre-validate store health
        if !storeHealthCheck() {
            logger.warning("Store health check failed — skipping feed result apply")
            return .empty
        }

        // Fetch all podcasts on our background context (keyed by URL for lookup)
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? context.fetch(descriptor) else {
            logger.error("Failed to fetch podcasts for feed result apply")
            return .empty
        }
        let byURL = Dictionary(podcasts.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })

        var newEpisodeGuids: [String] = []
        var urlMigrations: [FeedURLMigration] = []

        for result in results {
            guard let podcast = byURL[result.url] else {
                logger.warning("No subscription found for fetched URL: \(result.url)")
                continue
            }

            let (guids, migration) = applyFeedResult(result, to: podcast)
            newEpisodeGuids.append(contentsOf: guids)
            if let migration { urlMigrations.append(migration) }
        }

        // Single save for all mutations
        save()

        logger.info("Applied feed results (background): \(newEpisodeGuids.count) new episodes, \(urlMigrations.count) URL migrations")
        return FeedApplyOutcome(
            newEpisodeGuids: newEpisodeGuids,
            urlMigrations: urlMigrations
        )
    }

    /// Apply a single feed result to a podcast — ported from PodcastManager.applyFeedResult.
    private func applyFeedResult(
        _ result: FeedFetchResult,
        to podcast: Podcast
    ) -> (newGuids: [String], migration: FeedURLMigration?) {
        let parsed = result.parsed
        let parsedEpisodes = result.episodes
        var migration: FeedURLMigration?

        // ── Update podcast metadata ──
        FeedMetadataMapper.apply(parsed, to: podcast)

        // ── Handle feed URL migration (itunes:new-feed-url) ──
        if let newUrl = parsed.newFeedUrl, !newUrl.isEmpty, newUrl != podcast.url {
            logger.warning("Feed \(podcast.title) declares new URL: \(newUrl). Recording migration.")
            let oldUrl = podcast.url
            podcast.url = newUrl
            podcast.newFeedUrl = nil
            migration = FeedURLMigration(oldUrl: oldUrl, newUrl: newUrl)
        }

        // ── Create new episodes / update existing ──
        let existingGuids = Set(podcast.episodes.map(\.guid))

        var newGuids: [String] = []
        for ep in parsedEpisodes where !existingGuids.contains(ep.guid) {
            let episode = Episode(
                guid: ep.guid,
                title: ep.title,
                episodeDescription: ep.description,
                audioUrl: ep.audioUrl,
                pubDate: ep.pubDate,
                imageUrl: ep.imageUrl,
                durationSeconds: ep.durationSeconds,
                link: ep.link,
                chaptersUrl: ep.chaptersUrl,
                transcriptUrl: ep.transcriptUrl,
                podcast: podcast
            )
            FeedMetadataMapper.apply(ep, to: episode)
            context.insert(episode)
            newGuids.append(ep.guid)
        }

        // Update existing episodes with new metadata fields
        for ep in parsedEpisodes where existingGuids.contains(ep.guid) {
            if let existing = podcast.episodes.first(where: { $0.guid == ep.guid }) {
                FeedMetadataMapper.apply(ep, to: existing)
            }
        }

        // ── Mark stale episodes ──
        let feedGuids = Set(parsedEpisodes.map(\.guid))
        let feedAudioBaseURLs = Set(parsedEpisodes.compactMap { ep -> String? in
            guard let url = ep.audioUrl else { return nil }
            return stripQueryParams(url)
        })

        for localEp in podcast.episodes {
            let inFeedByGuid = feedGuids.contains(localEp.guid)
            let inFeedByURL: Bool = {
                guard let audioUrl = localEp.audioUrl else { return false }
                return feedAudioBaseURLs.contains(stripQueryParams(audioUrl))
            }()

            if inFeedByGuid || inFeedByURL {
                if localEp.isStale { localEp.isStale = false }
            } else {
                if !localEp.isStale { localEp.isStale = true }
            }
        }

        return (newGuids, migration)
    }

    // MARK: - Subscription Persistence

    /// Insert podcasts + episodes with dedup-by-URL guard.
    ///
    /// Returns URLs actually inserted (dedup skips excluded).
    /// Ported from `PodcastManager.persistPodcastFromSync`.
    func persistNewPodcasts(_ payloads: [NewPodcastPayload]) async -> [String] {
        guard !Task.isCancelled else {
            logger.info("persistNewPodcasts cancelled — skipping")
            return []
        }

        var insertedUrls: [String] = []

        for payload in payloads {
            // Dedup guard: skip if already in store
            let url = payload.url
            let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.url == url })
            if let existing = try? context.fetch(descriptor), !existing.isEmpty {
                logger.debug("persistNewPodcasts: skipping duplicate URL: \(url)")
                continue
            }

            let podcast = Podcast(
                url: payload.url,
                title: payload.parsed.title,
                podcastDescription: payload.parsed.description,
                logoUrl: payload.parsed.logoUrl,
                website: payload.parsed.website,
                author: payload.parsed.author
            )
            podcast.sortOrder = payload.sortOrder

            FeedMetadataMapper.apply(payload.parsed, to: podcast)

            // Set markedPlayedBefore to now so we don't flood the queue with back catalog
            podcast.effectiveSettings.markedPlayedBefore = Date()

            context.insert(podcast)

            for ep in payload.episodes {
                let episode = Episode(
                    guid: ep.guid,
                    title: ep.title,
                    episodeDescription: ep.description,
                    audioUrl: ep.audioUrl,
                    pubDate: ep.pubDate,
                    imageUrl: ep.imageUrl,
                    durationSeconds: ep.durationSeconds,
                    link: ep.link,
                    chaptersUrl: ep.chaptersUrl,
                    transcriptUrl: ep.transcriptUrl,
                    podcast: podcast
                )
                FeedMetadataMapper.apply(ep, to: episode)
                context.insert(episode)
            }

            insertedUrls.append(payload.url)
            logger.info("Persisted from sync (background): \(payload.parsed.title) with \(payload.episodes.count) episodes")
        }

        if !insertedUrls.isEmpty {
            save()
        }

        return insertedUrls
    }

    /// Delete podcasts by URL (cascade removes episodes via SwiftData relationship).
    func deletePodcasts(urls: [String]) async {
        guard !urls.isEmpty else { return }

        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? context.fetch(descriptor) else {
            logger.error("Failed to fetch podcasts for deletion")
            return
        }

        let urlSet = Set(urls)
        var deletedCount = 0
        for podcast in podcasts where urlSet.contains(podcast.url) {
            context.delete(podcast)
            deletedCount += 1
            logger.info("Deleted subscription (server initiated, background): \(podcast.url)")
        }

        if deletedCount > 0 {
            save()
        }
    }
}

// MARK: - Result Types

/// Sendable outcome from `SyncStore.applyEpisodeActions`.
struct EpisodeActionApplyOutcome: Sendable {
    let conflicts: [SyncConflict]
    let updatedCount: Int
    let saveCount: Int
    let newlyPlayedGuids: [String]
    /// Actions for episodes that were excluded from the background write because they
    /// were the live now-playing episode when their podcast was processed. The main
    /// actor applies these (it owns playback state, serialized with the progress timer).
    /// An array — a mid-loop episode switch can exclude more than one episode per cycle.
    let skippedActionsForPlayingEpisodes: [EpisodeAction]

    static let empty = EpisodeActionApplyOutcome(
        conflicts: [], updatedCount: 0, saveCount: 0, newlyPlayedGuids: [],
        skippedActionsForPlayingEpisodes: []
    )
}

/// Sendable outcome from `SyncStore.applyFeedResults`.
struct FeedApplyOutcome: Sendable {
    let newEpisodeGuids: [String]
    let urlMigrations: [FeedURLMigration]

    static let empty = FeedApplyOutcome(newEpisodeGuids: [], urlMigrations: [])
}

/// A feed URL migration detected during feed apply.
struct FeedURLMigration: Sendable {
    let oldUrl: String
    let newUrl: String
}

/// Payload for inserting a new podcast from sync.
/// sortOrder is snapshotted on main to avoid reading subscriptions.count inside the actor.
struct NewPodcastPayload: Sendable {
    let url: String
    let parsed: ParsedPodcast
    let episodes: [ParsedEpisode]
    let sortOrder: Int
}

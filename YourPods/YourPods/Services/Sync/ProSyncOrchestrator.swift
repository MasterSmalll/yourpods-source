import Foundation
import os

/// Sync orchestrator for YourPods Pro (and YourPods Sync free) profiles.
///
/// Holds a `SyncClient` that is expected to be a `YourPodsProClient` at runtime.
/// The concrete type is checked internally for Pro-only operations (settings,
/// stats, groups), but the protocol typing allows testability with spy clients.
///
/// Runs all sync steps: settings → subscriptions → RSS refresh →
/// auto-queue/download → episode actions → stats → groups → queue.
struct ProSyncOrchestrator: SyncOrchestrator {
    let client: any SyncClient
    private let logger = Logger(subsystem: "com.yourpods", category: "sync.pro")

    func sync(
        podcastManager: PodcastManager,
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        conflictStrategy: SyncStrategy,
        isBackground: Bool
    ) async -> [SyncConflict] {
        if isBackground {
            return await syncBackground(
                podcastManager: podcastManager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: conflictStrategy
            )
        } else {
            return await syncForeground(
                podcastManager: podcastManager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: conflictStrategy
            )
        }
    }

    // MARK: - Foreground Sync (original order)


    // MARK: - Background Sync (reordered for BGTask time budget)

    /// Background sync: episode actions → queue → settings → subscriptions → RSS.
    /// Prioritizes high-value data (resume position, cross-device handoff) because
    /// BGTask gives ~30s and RSS refresh alone can consume most of that.
    private func syncBackground(
        podcastManager: PodcastManager,
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        conflictStrategy: SyncStrategy
    ) async -> [SyncConflict] {
        logger.info("Pro sync: starting (background — prioritizing episode actions + queue)")

        // ── Priority 1: Episode actions (resume position) ──────────────
        var conflicts: [SyncConflict] = []
        do {
            // Incremental pull (force: false) from the persisted cursor. A full
            // re-pull (since=0) on every sync re-fetches + re-applies the entire
            // history, blowing the iOS disk-write budget and stranding the sync in
            // a never-completes loop — see GPodderSyncOrchestrator, which is incremental.
            conflicts = try await podcastManager.syncEpisodeActions(force: false, strategy: conflictStrategy)
        } catch {
            if Task.isCancelled || error.isCancellationError {
                logger.info("Pro sync (bg): episode action sync cancelled — stopping")
                return conflicts
            }
            logger.error("Pro sync (bg): episode action sync failed: \(error.localizedDescription)")
            podcastManager.lastSyncError = error.localizedDescription
            conflicts = await podcastManager.applyEpisodeActionsAsync(strategy: conflictStrategy)
        }

        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping after episode actions")
            return conflicts
        }

        // Hidden state changes (extracted from episode action response, no extra call)
        let hiddenChanges = podcastManager.episodeActionSync.lastFetchedHiddenChanges
        if !hiddenChanges.isEmpty {
            podcastManager.episodeActionSync.applyHiddenChanges(hiddenChanges)
            logger.info("Pro sync (bg): processed \(hiddenChanges.count) hidden state change(s)")
        }

        // Drain completion outbox BEFORE applying completed changes from the server.
        // This ensures B3's guard (pendingCompletionGuids) can skip un-completing an
        // episode we are about to re-push as completed.
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before completion outbox drain")
            return conflicts
        }
        await podcastManager.drainCompletionOutbox(using: client, baselines: playerManager.playbackBaselines)

        // Completed state changes (same response): honor the server's authoritative
        // `completed` flag so a finished-on-web episode is marked played here — this
        // is what lets the now-playing cleanup below clear the mini player.
        let completedChanges = podcastManager.episodeActionSync.lastFetchedCompletedChanges
        if !completedChanges.isEmpty {
            podcastManager.episodeActionSync.applyCompletedChanges(completedChanges)
            logger.info("Pro sync (bg): processed \(completedChanges.count) completed state change(s)")
        }

        // Un-completed state changes: apply server completed:false (relisten / re-add
        // on another device). Runs AFTER the completion outbox drain above so the
        // pending-guid guard in applyUncompletedChanges correctly skips locally
        // just-finished episodes whose push hasn't landed yet.
        let uncompletedChanges = podcastManager.episodeActionSync.lastFetchedUncompletedChanges
        if !uncompletedChanges.isEmpty {
            podcastManager.episodeActionSync.applyUncompletedChanges(uncompletedChanges)
            logger.info("Pro sync (bg): processed \(uncompletedChanges.count) uncompleted state change(s)")
        }

        // Every side-channel from this window has now been applied, so the cursor can
        // move past it. Before this, the cursor advanced the moment the window arrived —
        // and any of the cancellation gates above returning early took the changes with it.
        podcastManager.episodeActionSync.commitCursorToken()

        // ── Priority 2: Queue sync (cross-device handoff) ──────────────
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before queue sync")
            return conflicts
        }

        let queueConflicts = await playerManager.syncQueueWithServer()
        conflicts.append(contentsOf: queueConflicts)

        // ── Priority 3: Playback state reconciliation ──────────────────
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before playback reconciliation")
            return conflicts
        }

        // Unified with the foreground path: read → clear finished → guarded push
        // → reconcile (Fix C — clear-before-push prevents now-playing resurrection).
        await syncPlaybackChain(playerManager: playerManager, podcastManager: podcastManager)

        // ── Priority 4: Settings sync ──────────────────────────────────
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before settings sync")
            return conflicts
        }

        // Unified with the foreground path: pull → three-way merge → sparse push
        // (shared helper, so bg and fg conflict-resolution can never diverge).
        await reconcileGlobalProfileSettings(settingsManager: settingsManager)

        // ── Priority 5: Subscription sync + RSS refresh (large, lower urgency) ──
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before subscription sync")
            return conflicts
        }

        let authFailed = await podcastManager.syncSubscriptionsWithRecovery()
        if authFailed { return conflicts }

        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before RSS refresh")
            return conflicts
        }

        let newEpisodes = await podcastManager.refreshAllFeeds()

        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before auto-queue/download")
            return conflicts
        }

        await podcastManager.processNewEpisodes(
            newEpisodes,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        // ── Priority 6: Stats + groups (lowest urgency) ────────────────
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before stats/groups")
            return conflicts
        }

        if let proClient = client as? YourPodsProClient,
           let activeProfile = settingsManager.activeProfile,
           activeProfile.profileType == .yourpodsPro {
            let profileName = activeProfile.proProfileName
            let pendingEvents = await playerManager.statsBuffer.flush()
            if !pendingEvents.isEmpty {
                do {
                    try await proClient.pushStatsEvents(pendingEvents)
                } catch {
                    await playerManager.statsBuffer.restore(pendingEvents)
                }
            }
            await podcastManager.syncGroupsPushThenPull(profileName: profileName, client: proClient)
        }

        // ── Priority 7: Annotation sync (notes) ────────────────────────
        guard !Task.isCancelled else {
            logger.info("Pro sync (bg): cancelled — stopping before annotation sync")
            return conflicts
        }

        await syncAnnotations(
            podcastManager: podcastManager,
            settingsManager: settingsManager
        )

        logger.info("Pro sync (bg): complete")
        return conflicts
    }

    /// Foreground sync: (settings ∥ subscriptions) → RSS → episode actions →
    /// (playback chain ∥ stats/groups) → queue.
    /// Uses `async let` to overlap independent network waits.
    private func syncForeground(
        podcastManager: PodcastManager,
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        conflictStrategy: SyncStrategy
    ) async -> [SyncConflict] {
        logger.info("Pro sync: starting (foreground)")

        // ── Group A: Settings ∥ Subscriptions ──────────────────────────
        // Profile/podcast settings and subscription sync are independent:
        // settings touch SettingsManager + API; subscriptions touch
        // PodcastManager subscription list + API. Both run on @MainActor
        // so local mutations are serial; only the network waits overlap.

        async let settingsResult: Void = syncSettings(
            settingsManager: settingsManager,
            podcastManager: podcastManager
        )
        async let subsResult: Bool = podcastManager.syncSubscriptionsWithRecovery()

        // Await both — settings is fire-and-forget (errors logged internally),
        // subscriptions can signal auth failure.
        _ = await settingsResult
        let authFailed = await subsResult

        if authFailed { return [] }

        // Step gates: once the task is cancelled (BGTask expiration, app
        // backgrounding), no further step may start — later steps open SQLite
        // write transactions, and a write straddling suspension is killed
        // with 0xDEAD10CC.
        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before RSS refresh")
            return []
        }

        // Step 3: Refresh RSS feeds (depends on subscription list from Group A)
        let newEpisodes = await podcastManager.refreshAllFeeds()

        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before auto-queue/download")
            return []
        }

        // Step 4: Auto-queue + auto-download new episodes
        await podcastManager.processNewEpisodes(
            newEpisodes,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before episode action sync")
            return []
        }

        // Step 5: Episode action sync (playback positions)
        var conflicts: [SyncConflict] = []
        do {
            // Incremental pull (force: false) from the persisted cursor — same
            // anti-thrash reasoning as the background path above.
            conflicts = try await podcastManager.syncEpisodeActions(force: false, strategy: conflictStrategy)
        } catch {
            if Task.isCancelled || error.isCancellationError {
                logger.info("Pro sync: episode action sync cancelled — stopping")
                return conflicts
            }
            logger.error("Pro sync: episode action sync failed: \(error.localizedDescription)")
            podcastManager.lastSyncError = error.localizedDescription
            conflicts = await podcastManager.applyEpisodeActionsAsync(strategy: conflictStrategy)
        }

        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before playback state sync")
            return conflicts
        }

        // Step 5e: Hidden state changes (from episode action response, no extra call)
        let hiddenChanges = podcastManager.episodeActionSync.lastFetchedHiddenChanges
        if !hiddenChanges.isEmpty {
            podcastManager.episodeActionSync.applyHiddenChanges(hiddenChanges)
            logger.info("Pro sync: processed \(hiddenChanges.count) hidden state change(s) (from episode action response)")
        }

        // Step 5e.1b: Drain completion outbox BEFORE applying server completed changes.
        // Must run here so B3's pendingCompletionGuids guard sees the outbox before
        // the apply step can overwrite local state. Gate on Task.isCancelled.
        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before completion outbox drain")
            return conflicts
        }
        await podcastManager.drainCompletionOutbox(using: client, baselines: playerManager.playbackBaselines)

        // Step 5e.2: Completed state changes (same response): honor the server's
        // authoritative `completed` flag so a finished-on-web episode is marked
        // played, letting the now-playing cleanup clear the mini player.
        let completedChanges = podcastManager.episodeActionSync.lastFetchedCompletedChanges
        if !completedChanges.isEmpty {
            podcastManager.episodeActionSync.applyCompletedChanges(completedChanges)
            logger.info("Pro sync: processed \(completedChanges.count) completed state change(s) (from episode action response)")
        }

        // Step 5e.3: Un-completed state changes: apply server completed:false (relisten /
        // re-add on another device). Runs AFTER the completion outbox drain above so
        // the pending-guid guard in applyUncompletedChanges correctly skips locally
        // just-finished episodes whose push hasn't landed yet.
        let uncompletedChanges = podcastManager.episodeActionSync.lastFetchedUncompletedChanges
        if !uncompletedChanges.isEmpty {
            podcastManager.episodeActionSync.applyUncompletedChanges(uncompletedChanges)
            logger.info("Pro sync: processed \(uncompletedChanges.count) uncompleted state change(s)")
        }

        // Every side-channel from this window has now been applied, so the cursor can
        // move past it. Before this, the cursor advanced the moment the window arrived —
        // and any of the cancellation gates above returning early took the changes with it.
        podcastManager.episodeActionSync.commitCursorToken()

        // Step 5f: Fetch server-side conflicts
        // Server conflicts are canonical — they track resolutions across devices.
        if let proClient = client as? YourPodsProClient {
            do {
                let serverConflicts = try await proClient.getSyncConflicts()

                // Position conflicts: dedup against locally-detected conflicts by the
                // episode's audio URL (the server keys by `episodeUrl`, which equals
                // the local SyncConflict.audioUrl). Keying on GUID here silently failed.
                let newServerConflicts = Self.mergedServerPositionConflicts(
                    local: conflicts, server: serverConflicts.conflicts
                )
                conflicts.append(contentsOf: newServerConflicts)

                // URL rewrites: surface only when the user wants prompts (.ask) and
                // dedup by oldUrl — respect syncConflictStrategy in all code paths.
                // The server strips the `url_rewrite:` row prefix and emits oldUrl/newUrl
                // directly; re-stripping a prefix that is no longer there was harmless,
                // but reading these off `episodeUrl`/`podcastUrl` was not — those keys
                // are absent from a rewrite, so the array could not decode.
                let rewrites = serverConflicts.urlRewrites.map { rewrite -> URLRewriteConflict in
                    URLRewriteConflict(
                        oldUrl: rewrite.oldUrl,
                        newUrl: rewrite.newUrl,
                        podcastTitle: nil,
                        artworkUrl: nil
                    )
                }
                playerManager.deliverUrlRewrites(rewrites, strategy: conflictStrategy)

                if serverConflicts.total > 0 {
                    logger.info("Pro sync: fetched \(serverConflicts.total) server conflicts (\(newServerConflicts.count) new position, \(serverConflicts.urlRewrites.count) URL rewrites)")
                }
            } catch {
                // Non-fatal — local conflict detection still works
                logger.error("Pro sync: failed to fetch server conflicts: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before playback/stats sync")
            return conflicts
        }

        // ── Group B: Playback chain ∥ Stats/groups ─────────────────────
        // Playback reconciliation (5b-5d) and stats/groups upload (6) are
        // independent — different server endpoints, different local data.
        async let playbackResult: Void = syncPlaybackChain(
            playerManager: playerManager,
            podcastManager: podcastManager
        )
        async let statsResult: Void = syncStatsAndGroups(
            playerManager: playerManager,
            podcastManager: podcastManager,
            settingsManager: settingsManager
        )

        _ = await (playbackResult, statsResult)

        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before queue sync")
            return conflicts
        }

        // Step 7: Queue sync — pull → merge → push → adopt
        let queueConflicts = await playerManager.syncQueueWithServer()
        conflicts.append(contentsOf: queueConflicts)

        guard !Task.isCancelled else {
            logger.info("Pro sync: cancelled — stopping before annotation sync")
            return conflicts
        }

        // Step 8: Annotation sync (notes) — push dirty → pull delta → apply
        await syncAnnotations(
            podcastManager: podcastManager,
            settingsManager: settingsManager
        )

        logger.info("Pro sync: complete")
        return conflicts
    }

    // MARK: - Step Helpers

    /// Steps 1 + 1b: Profile settings push-then-pull + per-podcast settings.
    private func syncSettings(
        settingsManager: SettingsManager,
        podcastManager: PodcastManager
    ) async {
        // Step 1: Global profile settings — pull → three-way merge → sparse push.
        await reconcileGlobalProfileSettings(settingsManager: settingsManager)

        // Step 1b: Per-podcast settings (push-then-pull)
        if let activeProfile = settingsManager.activeProfile,
           activeProfile.profileType == .yourpodsPro {
            let profileName = activeProfile.proProfileName

            let dirtySettings = podcastManager.collectDirtyPodcastSettings()
            if !dirtySettings.isEmpty {
                do {
                    try await client.pushPodcastSettingsBatch(
                        profileName: profileName,
                        items: dirtySettings
                    )
                    logger.info("Pro sync: batch-pushed \(dirtySettings.count) per-podcast setting overrides")
                } catch {
                    logger.error("Pro sync: failed to batch-push per-podcast settings: \(error.localizedDescription)")
                }
            }

            do {
                let serverPodcastSettings = try await client.pullPodcastSettings(
                    profileName: profileName,
                    since: nil
                )
                if !serverPodcastSettings.isEmpty {
                    podcastManager.applyPerPodcastOverridesFromServer(serverPodcastSettings)
                    logger.info("Pro sync: applied \(serverPodcastSettings.count) per-podcast setting overrides")
                }
            } catch let error as YourPodsProError where error.isSubscriptionRequired {
                logger.info("Pro sync: per-podcast settings pull gated (free tier) — pushes continue")
            } catch {
                logger.error("Pro sync: failed to pull per-podcast settings: \(error.localizedDescription)")
            }
        }
    }

    /// Reconcile global profile settings with the server (Step 1 / Priority 4).
    ///
    /// Order is **pull → merge → sparse push**:
    /// - Pulling first lets `applyFromProfile` detect genuine same-key conflicts
    ///   (both sides changed since the base) instead of having our push mask them.
    /// - We push **only the keys this device changed**. The server merges JSONB per
    ///   key (`payload || EXCLUDED.payload`), so a full-blob PATCH would clobber
    ///   another device's keys — the root cause of "changed on web, not on my phone".
    ///
    /// Shared by the foreground and background paths so they cannot diverge. The pull
    /// is Pro-gated on the free tier (nil ⇒ no server view); the sparse push always
    /// runs so free-tier devices keep accumulating settings server-side.
    private func reconcileGlobalProfileSettings(settingsManager: SettingsManager) async {
        guard await client.supportsSettingsSync,
              let activeProfile = settingsManager.activeProfile,
              activeProfile.profileType == .yourpodsPro else { return }
        let profileName = activeProfile.proProfileName

        var serverSettings: ProProfileSettings?
        do {
            serverSettings = try await client.getProfileSettings(profileName: profileName)
        } catch let error as YourPodsProError where error.isSubscriptionRequired {
            logger.info("Pro sync: profile settings pull gated (free tier) — sparse push continues")
        } catch {
            logger.error("Pro sync: failed to pull profile settings: \(error.localizedDescription)")
        }

        // Three-way merge locally; returns the sparse set of keys to PATCH.
        let pushPayload = settingsManager.applyFromProfile(serverSettings, profileName: profileName)

        guard !pushPayload.isEmpty else {
            logger.debug("Pro sync: profile settings already in sync — nothing to push")
            return
        }
        do {
            try await client.patchProfileSettings(profileName: profileName, payload: pushPayload)
            logger.info("Pro sync: pushed \(pushPayload.count) changed profile setting(s) for '\(profileName)'")
        } catch {
            logger.error("Pro sync: failed to push profile settings: \(error.localizedDescription)")
        }
    }

    /// Steps 5b-5d: Playback state read → clear finished → push now-playing → reconcile.
    ///
    /// Ordering note (Fix C): the finished-episode cleanup runs
    /// BEFORE the now-playing push. Otherwise a still-loaded finished episode is
    /// re-asserted as `nowPlaying: true` on the server every sync — which (server
    /// mutual-exclusion) un-completes it and republishes it to every device
    /// ("resurrection"). Clearing first means a finished current item is dropped
    /// locally (`currentItem -> nil`) and never pushed. The push is additionally
    /// gated on `isPlayed` (NOT `isPlaying`): a paused-but-unplayed episode must
    /// still push now-playing for cross-device handoff.
    private func syncPlaybackChain(
        playerManager: PlayerManager,
        podcastManager: PodcastManager
    ) async {
        // Step 5b-read: Capture server playback state BEFORE we push local state.
        var preFetchedServerState: ProPlaybackState?
        do {
            preFetchedServerState = try await client.getCurrentPlayback()
            if let s = preFetchedServerState {
                // Public: present/shape booleans (no PII). Private: episode title.
                logger.info("Pro sync: pre-fetched server playback present=true nowPlaying=\(s.nowPlaying.map(String.init) ?? "nil", privacy: .public) completed=\(s.completed.map(String.init) ?? "nil", privacy: .public) pos=\(Int(s.positionSec), privacy: .public)s title='\(s.title ?? "?")'")
            } else {
                logger.info("Pro sync: pre-fetched server playback present=false (nil — no active server state)")
            }
        } catch let error as YourPodsProError where error.isSubscriptionRequired {
            logger.info("Pro sync: playback state pull gated (free tier) — push continues")
        } catch {
            logger.error("Pro sync: failed to pre-fetch server playback state: \(error.localizedDescription)")
        }

        // Step 5c (clear-first): drop any finished current item before pushing,
        // so a completed episode is never re-asserted as now-playing.
        playerManager.clearPlayedEpisodesFromQueue(podcastManager: podcastManager)

        // Step 5d-write: Push current playback state. Gate on isPlayed (NOT isPlaying):
        // a played/finished item must never push nowPlaying:true. (If clear-first
        // already dropped it, this block is skipped entirely.)
        if let currentItem = playerManager.audioManager.currentItem {
            let isPlayed = podcastManager.isEpisodePlayed(guid: currentItem.id)
            // Sync contract: this is the periodic push, the highest-frequency one, and the one the
            // reconciler's conflicts come back to — so it goes through the CAS seam rather
            // than straight at the client. `pushPlaybackWithCAS` carries this episode's
            // stored baseline, consumes the answer (acks advance it, adopts are written
            // locally), and routes a divergence neither side can settle to the sheet.
            //
            // Sending `baseVersion: nil` here was not merely "unversioned": a versionless
            // push can never be *refused*, and only a refusal produces the `conflicts[]`
            // entry the server persists as a `sync_conflicts` row. Every divergence
            // arriving on this path was therefore invisible to the entire conflict
            // feature, however correct `PlaybackReconciler` was.
            //
            // `completed: isPlayed` and not `isPlayed ? true : nil` — see the wire comment
            // in `pushPlaybackWithCAS`. Once the push is versioned the server stops
            // merging, so an omitted flag decodes to `false` and is written verbatim.
            // The two halves of this change are one change: adding the baseline while
            // still omitting the flag would be worse than the versionless push it replaces.
            //
            // Errors are logged and swallowed inside the seam, so there is nothing to catch.
            await playerManager.pushPlaybackWithCAS(
                item: currentItem,
                positionSec: playerManager.currentPosition,
                nowPlaying: !isPlayed,
                completed: isPlayed,
                client: client,
                // The periodic push carries this device's event time so
                // the server can reject a stale push that would clobber newer state.
                // While actively playing this is `now` (live source → wins); while
                // paused/idle it's the frozen last-change time (stale → loses).
                eventTime: playerManager.audioManager.playbackEventTimeForSync,
                attempt: 1
            )
            logger.info("Pro sync: pushed playback for \(currentItem.title) (nowPlaying=\(!isPlayed))")
        }

        // Step 5e: Reconcile now-playing with server using PRE-FETCHED state.
        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedServerState)
    }

    /// Step 6: Stats flush + groups sync.
    private func syncStatsAndGroups(
        playerManager: PlayerManager,
        podcastManager: PodcastManager,
        settingsManager: SettingsManager
    ) async {
        guard let proClient = client as? YourPodsProClient,
              let activeProfile = settingsManager.activeProfile,
              activeProfile.profileType == .yourpodsPro else { return }

        let profileName = activeProfile.proProfileName

        let pendingEvents = await playerManager.statsBuffer.flush()
        if !pendingEvents.isEmpty {
            do {
                try await proClient.pushStatsEvents(pendingEvents)
                logger.info("Pro sync: uploaded \(pendingEvents.count) stats events")
            } catch {
                logger.error("Pro sync: stats upload failed — restoring \(pendingEvents.count) events: \(error.localizedDescription)")
                await playerManager.statsBuffer.restore(pendingEvents)
            }
        }

        await podcastManager.syncGroupsPushThenPull(profileName: profileName, client: proClient)
    }

    // MARK: - Annotation Sync

    /// Push dirty annotations → pull delta → apply to local store.
    ///
    /// Push and pull are separate steps because the POST response returns
    /// full state (all annotations), while GET ?since= returns a delta.
    /// We push first so the server has our latest state, then pull to
    /// receive changes from other devices.
    ///
    /// Must run on `@MainActor` — `AnnotationService` wraps SwiftData's
    /// `ModelContext`, which is not thread-safe. Without this annotation the
    /// method executes on the cooperative pool, causing `dirtyAnnotations()`
    /// to return empty (no push) and `applyDelta` inserts to silently fail
    /// (pull ignored). Other sync steps avoid this because they route through
    /// `@MainActor` methods on `PodcastManager`/`PlayerManager`.
    @MainActor
    private func syncAnnotations(
        podcastManager: PodcastManager,
        settingsManager: SettingsManager
    ) async {
        guard let proClient = client as? YourPodsProClient,
              let activeProfile = settingsManager.activeProfile,
              activeProfile.profileType == .yourpodsPro else { return }

        let annotationService = podcastManager.annotationService!

        // ── Push dirty annotations ──────────────────────────────────────
        let dirty = annotationService.dirtyAnnotations()
        if !dirty.isEmpty {
            let items = dirty.map { annotation -> SyncAnnotationItem in
                var item = SyncAnnotationItem(
                    id: annotation.annotationId,
                    episodeUrl: annotation.episodeUrl,
                    podcastUrl: annotation.podcastUrl,
                    episodeGuid: annotation.episodeGuid,
                    timestampSec: annotation.timestampSec,
                    noteText: annotation.noteText,
                    chapterTitle: annotation.chapterTitle,
                    chapterStartSec: annotation.chapterStartSec,
                    transcriptText: annotation.transcriptText,
                    transcriptStartSec: annotation.transcriptStartSec,
                    transcriptEndSec: annotation.transcriptEndSec,
                    color: annotation.color,
                    tags: annotation.tags,
                    deleted: annotation.deleted
                )
                // Attach snapshot for first annotation on this episode
                if annotationService.needsSnapshot(for: annotation.episodeUrl),
                   let podcastTitle = annotation.podcastTitle,
                   let episodeTitle = annotation.episodeTitle {
                    item.snapshot = AnnotationSnapshotInfo(
                        podcastTitle: podcastTitle,
                        episodeTitle: episodeTitle,
                        artUrl: annotation.artUrl,
                        description: annotation.episodeDescription,
                        durationSec: annotation.durationSec,
                        transcriptUrl: annotation.transcriptUrl
                    )
                }
                return item
            }
            do {
                let response = try await proClient.syncAnnotations(items)
                annotationService.markAllClean()
                // Apply the full-state response from the push
                annotationService.applyDelta(response.annotations)
                if let cursor = response.syncedAt { settingsManager.lastAnnotationSyncedAt = cursor }
                annotationService.hardDeleteSyncedTombstones()
                logger.info("Pro sync: pushed \(items.count) annotations (synced=\(response.synced ?? 0), dropped=\(response.dropped ?? 0))")
            } catch {
                logger.error("Pro sync: annotation push failed: \(error.localizedDescription)")
            }
        } else {
            // ── Pull delta (no local changes to push) ───────────────────
            do {
                let response = try await proClient.pullAnnotations(
                    since: settingsManager.lastAnnotationSyncedAt
                )
                if !response.annotations.isEmpty {
                    annotationService.applyDelta(response.annotations)
                    annotationService.hardDeleteSyncedTombstones()
                    logger.info("Pro sync: pulled \(response.annotations.count) annotation deltas")
                }
                if let cursor = response.syncedAt { settingsManager.lastAnnotationSyncedAt = cursor }
            } catch {
                logger.error("Pro sync: annotation pull failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Server Conflict Merge

    /// Merge server-side position conflicts into the locally-detected set,
    /// de-duplicating by the episode's audio URL. The server keys each conflict by
    /// `episodeUrl`, which equals the local `SyncConflict.audioUrl`; GUIDs are kept
    /// as a fallback key. Previously this compared `episodeUrl` against a set of
    /// local *GUIDs*, so the guard never fired and the same episode surfaced twice
    /// in the Sync Conflicts sheet (one local row with title/artwork, one server
    /// row showing the raw URL).
    static func mergedServerPositionConflicts(
        local: [SyncConflict],
        server: [ProServerConflict]
    ) -> [SyncConflict] {
        var existingKeys = Set(local.compactMap(\.audioUrl))
        existingKeys.formUnion(local.map(\.episodeGuid))

        var result: [SyncConflict] = []
        for sc in server {
            guard existingKeys.insert(sc.episodeUrl).inserted else { continue }
            // Carry the metadata the server already resolved. `enrichSyncConflict`
            // backfills title/podcast/art from RSS on the GET, and discarding it here
            // is why a server-surfaced row rendered as a bare URL next to a local row
            // that had all three.
            result.append(SyncConflict(
                episodeGuid: sc.episodeUrl,
                episodeTitle: sc.episodeTitle,
                podcastTitle: sc.podcastTitle,
                podcastUrl: sc.podcastUrl,
                artworkUrl: sc.artUrl,
                audioUrl: sc.episodeUrl,
                localPosition: Int(sc.localPosition ?? 0),
                serverPosition: Int(sc.serverPosition ?? 0),
                serverTimestamp: 0,
                totalDuration: sc.duration.map(Int.init),
                occurrenceCount: sc.occurrenceCount ?? 1,
                // Absent means "not known to be played" — the deployed server predates
                // the field, and reading a missing key as `true` would relabel every
                // conflict on production as finished.
                serverCompleted: sc.serverCompleted ?? false,
                // Whose position `localPosition` is. Dropping it here is what left the
                // sheet unable to tell this device's row from another's.
                deviceId: sc.deviceId,
                // The server keys conflicts by episodeUrl and sends no numeric id;
                // resolution under the sync contract carries the position, not a row pointer.
                serverConflictId: nil
            ))
        }
        return result
    }
}

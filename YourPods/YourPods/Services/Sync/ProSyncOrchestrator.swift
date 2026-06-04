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
        conflictStrategy: SyncStrategy
    ) async -> [SyncConflict] {
        logger.info("Pro sync: starting")

        // Step 1: Push local profile settings, then pull server defaults
        // Uses protocol methods — any SyncClient with supportsSettingsSync can be tested.
        if await client.supportsSettingsSync,
           let activeProfile = settingsManager.activeProfile,
           activeProfile.profileType == .yourpodsPro {

            let profileName = activeProfile.proProfileName

            // Push current local settings to server (local is source of truth)
            do {
                let payload = settingsManager.asProfilePayload()
                try await client.patchProfileSettings(profileName: profileName, payload: payload)
                logger.info("Pro sync: pushed profile settings for '\(profileName)'")
            } catch {
                logger.error("Pro sync: failed to push profile settings: \(error.localizedDescription)")
            }

            // Pull server settings — first-sync guard prevents overwrite
            do {
                if let serverSettings = try await client.getProfileSettings(profileName: profileName) {
                    settingsManager.applyFromProfile(serverSettings, profileName: profileName)
                }
            } catch {
                logger.error("Pro sync: failed to pull profile settings: \(error.localizedDescription)")
            }
        }

        // Step 1b: Per-podcast settings — push-then-pull (mirrors global settings and groups).
        //
        // ⚠️ Push MUST happen before pull. Without this ordering, the server's
        // stale per-podcast settings overwrite local edits (e.g. autopilot changes)
        // before the local values ever reach the server. The user sees their change
        // vanish on the next sync and the web UI never receives it.
        if let activeProfile = settingsManager.activeProfile,
           activeProfile.profileType == .yourpodsPro {
            let profileName = activeProfile.proProfileName

            // Push dirty local per-podcast settings to server first (local wins).
            // Uses batch PATCH to send all settings in a single request,
            // avoiding the 429 rate-limit regression caused by N individual POST calls.
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

            // Pull per-podcast setting overrides from server (now safe — server has our changes)
            do {
                let serverPodcastSettings = try await client.pullPodcastSettings(
                    profileName: profileName,
                    since: nil
                )
                if !serverPodcastSettings.isEmpty {
                    podcastManager.applyPerPodcastOverridesFromServer(serverPodcastSettings)
                    logger.info("Pro sync: applied \(serverPodcastSettings.count) per-podcast setting overrides")
                }
            } catch {
                logger.error("Pro sync: failed to pull per-podcast settings: \(error.localizedDescription)")
            }
        }

        // Step 2: Sync subscriptions (shared with gPodder)
        let authFailed = await podcastManager.syncSubscriptionsWithRecovery()
        if authFailed { return [] }

        // Step 3: Refresh RSS feeds
        let newEpisodes = await podcastManager.refreshAllFeeds()

        // Step 4: Auto-queue + auto-download new episodes
        await podcastManager.processNewEpisodes(
            newEpisodes,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        // Step 5: Episode action sync (playback positions)
        var conflicts: [SyncConflict] = []
        do {
            conflicts = try await podcastManager.syncEpisodeActions(strategy: conflictStrategy)
        } catch {
            // Suppress cancellation errors — they come from lifecycle transitions (foreground → background),
            // not real connectivity failures. Don't show a banner for expected cancellations.
            if Task.isCancelled || error.isCancellationError {
                logger.info("Pro sync: episode action sync cancelled — suppressing error banner")
            } else {
                logger.error("Pro sync: episode action sync failed: \(error.localizedDescription)")
                podcastManager.lastSyncError = error.localizedDescription
            }
            conflicts = await podcastManager.applyEpisodeActionsAsync(strategy: conflictStrategy)
        }

        // Step 5b-read: Capture server playback state BEFORE we push local state.
        // This is critical for cross-device completion detection — if we push
        // nowPlaying: true first, the server's `completed: true` from the web player
        // gets overwritten with a newer timestamp, and reconciliation will never
        // see the completion. By reading first, we capture the authoritative state.
        var preFetchedServerState: ProPlaybackState?
        do {
            preFetchedServerState = try await client.getCurrentPlayback()
        } catch {
            logger.error("Pro sync: failed to pre-fetch server playback state: \(error.localizedDescription)")
            // Non-fatal — reconciliation will still work, just without the pre-fetched advantage
        }

        // Step 5b-write: Push current playback state with nowPlaying flag.
        // This tells the server which episode is actively playing on this device,
        // enabling cross-device handoff and web player awareness.
        if let currentItem = playerManager.audioManager.currentItem {
            let deviceId = playerManager.deviceId
            do {
                try await client.syncPlayback(
                    podcastUrl: currentItem.podcastUrl,
                    episodeUrl: currentItem.audioUrl,
                    episodeGuid: currentItem.id,
                    positionSec: playerManager.currentPosition,
                    durationSec: currentItem.durationSeconds.map { Double($0) },
                    nowPlaying: true,
                    completed: nil,
                    deviceId: deviceId
                )
                logger.info("Pro sync: pushed nowPlaying state for \(currentItem.title)")
            } catch {
                logger.error("Pro sync: failed to push nowPlaying: \(error.localizedDescription)")
            }
        }

        // Step 5c: Reconcile now-playing with server using PRE-FETCHED state.
        // Uses the server state captured in Step 5b-read (before our push), so
        // cross-device completion (completed: true from web player) is detected
        // even though Step 5b-write has now overwritten it on the server.
        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedServerState)

        // Step 5d: Post-sync queue cleanup — bridge SwiftData → AudioManager.
        // If applyEpisodeActions (Step 5) marked episodes as isPlayed via the 95%
        // threshold, the AudioManager queue/currentItem may still hold them.
        // This step removes played episodes from the mini player.
        playerManager.clearPlayedEpisodesFromQueue(podcastManager: podcastManager)

        // Step 5e: Hidden episodes sync (Build 198).
        // Parse hidden state changes from the delta sync response and update
        // the local hidden set. Hidden episodes get isPlayed = true for filtering.
        if let proClient = client as? YourPodsProClient {
            let epProfileId = UserDefaults.standard.string(forKey: "activeProfileId") ?? "global"
            let since = UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(epProfileId)")
            do {
                let hiddenChanges = try await proClient.getHiddenStateChanges(since: since)
                for change in hiddenChanges {
                    podcastManager.episodeActionSync.setHidden(
                        guid: change.guid,
                        hidden: change.hidden
                    )
                }
                if !hiddenChanges.isEmpty {
                    podcastManager.episodeActionSync.persistHiddenGuids()
                    logger.info("Pro sync: processed \(hiddenChanges.count) hidden state change(s)")
                }
            } catch {
                logger.error("Pro sync: failed to sync hidden states: \(error.localizedDescription)")
                // Non-fatal — hidden state can be retried on next sync
            }
        }

        // Step 6: Pro-only — stats flush + groups sync (require concrete YourPodsProClient)
        if let proClient = client as? YourPodsProClient,
           let activeProfile = settingsManager.activeProfile,
           activeProfile.profileType == .yourpodsPro {

            let profileName = activeProfile.proProfileName

            // Flush and upload stats events (restore on failure so they aren't lost)
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

            // Groups push-then-pull
            await podcastManager.syncGroupsPushThenPull(profileName: profileName, client: proClient)
        }

        // Step 7: Queue sync — pull → merge → push → adopt (gated by supportsQueueSync)
        let queueConflicts = await playerManager.syncQueueWithServer()
        conflicts.append(contentsOf: queueConflicts)

        logger.info("Pro sync: complete")
        return conflicts
    }
}

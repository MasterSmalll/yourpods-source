import Foundation
import os

/// Sync orchestrator for gPodder profiles (Nextcloud self-hosted and gpodder.net).
///
/// Holds a `SyncClient` (protocol type, not `YourPodsProClient`) so
/// Pro-only methods are not visible. Runs: subscriptions → RSS refresh →
/// auto-queue/download → episode actions.
///
/// Never calls queue sync, settings sync, stats flush, or groups sync.
struct GPodderSyncOrchestrator: SyncOrchestrator {
    let client: any SyncClient
    private let logger = Logger(subsystem: "com.yourpods", category: "sync.gpodder")

    func sync(
        podcastManager: PodcastManager,
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        conflictStrategy: SyncStrategy
    ) async -> [SyncConflict] {
        logger.info("gPodder sync: starting")

        // Step 1: Sync subscriptions (push local adds/removes, pull server changes)
        let authFailed = await podcastManager.syncSubscriptionsWithRecovery()
        if authFailed { return [] }

        // Step 2: Refresh RSS feeds
        let newEpisodes = await podcastManager.refreshAllFeeds()

        // Step 3: Auto-queue + auto-download new episodes
        await podcastManager.processNewEpisodes(
            newEpisodes,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        // Step 4: Episode action sync (playback positions)
        var conflicts: [SyncConflict] = []
        do {
            conflicts = try await podcastManager.syncEpisodeActions(force: false, strategy: conflictStrategy)
        } catch {
            // Suppress cancellation errors — they come from lifecycle transitions (foreground → background),
            // not real connectivity failures. Don't show a banner for expected cancellations.
            if Task.isCancelled || error.isCancellationError {
                logger.info("gPodder sync: episode action sync cancelled — suppressing error banner")
            } else {
                logger.error("gPodder sync: episode action sync failed: \(error.localizedDescription)")
                podcastManager.lastSyncError = error.localizedDescription
            }
            conflicts = await podcastManager.applyEpisodeActionsAsync(strategy: conflictStrategy)
        }

        logger.info("gPodder sync: complete")
        return conflicts
    }
}

import Foundation
import os

/// Sync orchestrator for Vault mode (no account).
///
/// Vault users have no sync client — only RSS feed refresh, auto-queue,
/// and auto-download run. This orchestrator structurally cannot call
/// any server sync because it holds no `SyncClient` reference.
struct VaultSyncOrchestrator: SyncOrchestrator {
    private let logger = Logger(subsystem: "com.yourpods", category: "sync.vault")

    func sync(
        podcastManager: PodcastManager,
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        conflictStrategy: SyncStrategy,
        isBackground: Bool
    ) async -> [SyncConflict] {
        logger.info("Vault sync: starting RSS refresh (no server sync)")

        // Step 1: Refresh RSS feeds
        let newEpisodes = await podcastManager.refreshAllFeeds()

        // Step gate: once cancelled (BGTask expiration, app backgrounding),
        // no further step may start — auto-queue/download opens SQLite write
        // transactions, and a write straddling suspension is killed (0xDEAD10CC).
        guard !Task.isCancelled else {
            logger.info("Vault sync: cancelled — stopping before auto-queue/download")
            return []
        }

        // Step 2: Auto-queue + auto-download new episodes
        await podcastManager.processNewEpisodes(
            newEpisodes,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        logger.info("Vault sync: complete — \(newEpisodes.count) new episodes")
        return []  // No server → no conflicts
    }
}

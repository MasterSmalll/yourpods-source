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
        conflictStrategy: SyncStrategy,
        isBackground: Bool
    ) async -> [SyncConflict] {
        logger.info("gPodder sync: starting")

        // Step gates: once the task is cancelled (BGTask expiration, app
        // backgrounding), no further step may start — later steps open SQLite
        // write transactions, and a write straddling suspension is killed
        // with 0xDEAD10CC.

        // Step 1: Sync subscriptions (push local adds/removes, pull server changes)
        let authFailed = await podcastManager.syncSubscriptionsWithRecovery()
        if authFailed { return [] }

        guard !Task.isCancelled else {
            logger.info("gPodder sync: cancelled — stopping before RSS refresh")
            return []
        }

        // Step 2: Refresh RSS feeds
        let newEpisodes = await podcastManager.refreshAllFeeds()

        guard !Task.isCancelled else {
            logger.info("gPodder sync: cancelled — stopping before auto-queue/download")
            return []
        }

        // Step 3: Auto-queue + auto-download new episodes
        await podcastManager.processNewEpisodes(
            newEpisodes,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        guard !Task.isCancelled else {
            logger.info("gPodder sync: cancelled — stopping before episode action sync")
            return []
        }

        // Step 4: Episode action sync (playback positions)
        var conflicts: [SyncConflict] = []
        do {
            conflicts = try await podcastManager.syncEpisodeActions(force: false, strategy: conflictStrategy)
        } catch {
            // Suppress cancellation errors — they come from lifecycle transitions (foreground → background),
            // not real connectivity failures. Don't show a banner for expected cancellations.
            if Task.isCancelled || error.isCancellationError {
                logger.info("gPodder sync: episode action sync cancelled — stopping")
                return conflicts
            }
            logger.error("gPodder sync: episode action sync failed: \(error.localizedDescription)")
            podcastManager.lastSyncError = error.localizedDescription
            conflicts = await podcastManager.applyEpisodeActionsAsync(strategy: conflictStrategy)
        }

        logger.info("gPodder sync: episode actions complete")

        // Step 5: Optional Nextcloud notes sync (gated by user toggle)
        guard !Task.isCancelled else {
            logger.info("gPodder sync: cancelled — stopping before notes sync")
            return conflicts
        }

        if settingsManager.nextcloudNotesSyncEnabled,
           let profile = settingsManager.activeProfile,
           profile.profileType == .gpodder,
           let baseUrl = profile.baseUrl,
           let username = profile.username,
           let password = KeychainHelper.shared.password(forProfileId: profile.id) {
            let annotationService = podcastManager.annotationService!
            let allAnnotations = annotationService.getAllAnnotations()

            switch settingsManager.nextcloudNotesMode {
            case .webdav:
                let result = await NextcloudNotesService.syncToNextcloud(
                    annotations: allAnnotations,
                    baseUrl: baseUrl,
                    username: username,
                    password: password,
                    folder: settingsManager.nextcloudNotesFolder
                )
                logger.info("gPodder sync: notes WebDAV sync — \(result.uploaded) uploaded, \(result.failed) failed")

            case .notesApi:
                let result = await NextcloudNotesAPIService.syncToNextcloud(
                    annotations: allAnnotations,
                    baseUrl: baseUrl,
                    username: username,
                    password: password
                )
                logger.info("gPodder sync: notes API sync — \(result.created) created, \(result.updated) updated, \(result.failed) failed")
            }
        }

        logger.info("gPodder sync: complete")
        return conflicts
    }
}

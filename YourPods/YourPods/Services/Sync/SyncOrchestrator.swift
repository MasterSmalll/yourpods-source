import Foundation

// MARK: - SyncOrchestrator Protocol

/// Defines the sync behavior for a profile type.
///
/// Each concrete orchestrator declares exactly which sync steps to run,
/// providing file-level isolation between profile types. Changes to one
/// orchestrator cannot affect another.
///
/// - `VaultSyncOrchestrator`: RSS refresh only, no server contact.
/// - `GPodderSyncOrchestrator`: Subscriptions + RSS + episode actions.
/// - `ProSyncOrchestrator`: Everything (settings, subs, RSS, actions, stats, groups, queue).
@MainActor
protocol SyncOrchestrator {
    /// Run the full sync cycle for this profile type.
    ///
    /// - Returns: Any sync conflicts that need user resolution.
    func sync(
        podcastManager: PodcastManager,
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        conflictStrategy: SyncStrategy
    ) async -> [SyncConflict]
}

// MARK: - SyncOrchestratorFactory

/// Creates the appropriate `SyncOrchestrator` based on the active profile.
///
/// The factory checks the profile type and sync client to determine which
/// orchestrator to use. This is the single dispatch point for all sync
/// triggers (sync button, pull-to-refresh, background refresh, foreground sync).
@MainActor
enum SyncOrchestratorFactory {
    /// Create the correct orchestrator for the given profile.
    ///
    /// - Parameters:
    ///   - profile: The active server profile, or `nil` for Vault mode.
    ///   - podcastManager: The podcast manager instance.
    ///   - syncClient: The active sync client, or `nil` for Vault mode.
    /// - Returns: A `SyncOrchestrator` matching the profile type.
    static func make(
        profile: ServerProfile?,
        podcastManager: PodcastManager,
        syncClient: (any SyncClient)?
    ) -> SyncOrchestrator {
        // No sync client → Vault mode (RSS-only, no server contact)
        guard let syncClient else {
            return VaultSyncOrchestrator()
        }

        // No explicit profile but a sync client is wired → use gPodder-style
        // sync (subscriptions + RSS + episode actions). This preserves the
        // old monolith behavior where steps 2-4 ran whenever syncClient != nil.
        guard let profile else {
            return GPodderSyncOrchestrator(client: syncClient)
        }

        switch profile.profileType {
        case .gpodder, .gpodderNet:
            return GPodderSyncOrchestrator(client: syncClient)
        case .yourpodsPro:
            return ProSyncOrchestrator(client: syncClient)
        }
    }
}

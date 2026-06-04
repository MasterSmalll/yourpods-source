// ─── YourPods Pro ────────────────────────────────────────────────────────
// SyncClient abstracts the sync backend so PodcastManager and
// PlayerManager work identically with gPodder or YourPods Pro.
// The app does NOT require YourPods Pro — gPodder and Vault Mode
// are fully supported without it.
//
// For up-to-date information on the app source and YourPods Pro
// spec/source, visit: https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

import Foundation

/// Unified sync protocol that both `GPodderClient` and `YourPodsProClient` conform to.
///
/// `PodcastManager` and `PlayerManager` depend on this protocol, not concrete client types.
/// This allows the app to swap sync backends transparently based on the profile type.
protocol SyncClient: Actor {
    
    // MARK: - Subscriptions
    
    /// Push subscription changes to the server.
    /// - Parameters:
    ///   - add: Feed URLs to subscribe to.
    ///   - remove: Feed URLs to unsubscribe from.
    ///   - deviceId: The device identifier for this client.
    /// - Returns: Any URL rewrites the server applied.
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite]
    
    /// Pull subscription changes from the server since the given timestamp.
    /// - Parameters:
    ///   - deviceId: The device identifier for this client.
    ///   - since: Unix timestamp of last sync (0 for full sync).
    /// - Returns: Subscription delta (added/removed URLs + server timestamp).
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta
    
    /// Whether `pullSubscriptionChanges` returns the complete subscription list
    /// (not just a delta). When `true`, the `add` array in `SubscriptionDelta`
    /// represents ALL server subscriptions, enabling remote deletion detection
    /// on every sync — not just when `since == 0`.
    var returnsFullSubscriptionList: Bool { get }
    
    // MARK: - Episode Actions / Playback
    
    /// Upload a batch of episode actions (play positions, new, download, etc.).
    /// - Returns: Any URL rewrites the server applied.
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite]
    
    /// Fetch episode actions from the server since the given timestamp.
    /// - Parameter since: Unix timestamp of last sync (0 for full sync).
    /// - Returns: Array of episode actions from the server.
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction]
    
    // MARK: - Queue Sync (YourPods Pro only)
    
    /// Whether this sync backend supports full queue synchronization.
    /// `false` for gPodder, `true` for YourPods Pro.
    var supportsQueueSync: Bool { get }
    
    /// Push the full queue to the server, replacing server state.
    /// Returns the server's authoritative merged queue from the response, along with any explicitly dropped items.
    /// Only call when `supportsQueueSync` is `true`.
    @discardableResult
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult
    
    /// Pull the server queue.
    /// Only call when `supportsQueueSync` is `true`.
    func getQueue() async throws -> [QueueSyncItem]
    
    /// Delete a single queue item on the server (tombstone).
    /// Called when the user removes an episode from the queue on a Pro account.
    /// Only call when `supportsQueueSync` is `true`.
    func deleteQueueItem(episodeUrl: String) async throws
    
    // MARK: - Playback Sync (YourPods Sync / Pro)
    
    /// Push current playback state for a specific episode.
    /// Used by the orchestrator to push `nowPlaying: true` with `deviceId`
    /// before queue sync, enabling cross-device handoff.
    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?
    ) async throws
    
    /// Get the most recent playback state from the server.
    /// Used by `reconcileNowPlayingWithServer()` to detect cross-device completion.
    /// Returns nil for gPodder/Vault (default no-op).
    func getCurrentPlayback() async throws -> ProPlaybackState?
    
    /// Whether this client supports cross-device playback reconciliation.
    /// `true` for YourPods Pro (has `/playback/current` endpoint).
    /// `false` for gPodder/Vault (default).
    var supportsPlaybackReconciliation: Bool { get }
    
    // MARK: - Settings Sync (YourPods Pro only)
    
    /// Whether this sync backend supports settings synchronization.
    /// `false` for gPodder, `true` for YourPods Pro.
    var supportsSettingsSync: Bool { get }
    
    // MARK: - Global Profile Settings Sync (YourPods Pro only)
    
    /// Push global profile settings to the server.
    /// - Parameters:
    ///   - profileName: The profile name to push settings for.
    ///   - payload: The settings payload (server key format).
    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws
    
    /// Pull global profile settings from the server.
    /// - Parameter profileName: The profile name to pull settings for.
    /// - Returns: The server's profile settings, or `nil` if none exist.
    func getProfileSettings(profileName: String) async throws -> ProProfileSettings?
    
    // MARK: - Per-Podcast Settings Sync (YourPods Pro only)
    
    /// Pull per-podcast setting overrides from the server.
    /// - Parameters:
    ///   - profileName: The profile name to pull settings for.
    ///   - since: Optional timestamp for delta sync. Nil = full sync.
    /// - Returns: Array of per-podcast setting overrides.
    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting]
    
    /// Push a single per-podcast setting override to the server.
    /// - Parameters:
    ///   - profileName: The profile name to push settings for.
    ///   - podcastUrl: The podcast's feed URL.
    ///   - payload: The settings payload (server key format).
    func pushPodcastSetting(profileName: String, podcastUrl: String, payload: [String: AnyCodableValue]) async throws
    
    /// Batch push per-podcast setting overrides to the server in a single request.
    /// Replaces N individual `pushPodcastSetting` calls with one PATCH request,
    /// reducing HTTP calls from O(n) to O(1) and avoiding rate-limit (429) errors.
    /// - Parameters:
    ///   - profileName: The profile name to push settings for.
    ///   - items: Array of (podcastUrl, payload) pairs.
    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws
    
    // MARK: - Hidden Episodes (YourPods Sync / Pro)
    
    /// Hide episodes on the server. Sets hidden + isPlayed = true.
    /// Only supported by YourPods Sync / Pro backends.
    func hideEpisodes(_ episodes: [ProHideEpisodeRequest]) async throws
    
    /// Unhide a single episode on the server. Clears hidden flag.
    /// Only supported by YourPods Sync / Pro backends.
    func unhideEpisode(episodeUrl: String) async throws
}

// MARK: - Default No-Op Implementations

/// Default no-op for methods that only apply to YourPods Pro.
/// gPodder clients don't need to implement these.
extension SyncClient {
    var returnsFullSubscriptionList: Bool { false }
    
    func deleteQueueItem(episodeUrl: String) async throws {
        // No-op for gPodder / non-Pro clients
    }
    
    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?
    ) async throws {
        // No-op for gPodder / non-Pro clients
    }
    
    func getCurrentPlayback() async throws -> ProPlaybackState? {
        // No-op for gPodder / non-Pro clients — returns nil
        return nil
    }
    
    var supportsPlaybackReconciliation: Bool { false }
    
    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws {
        // No-op for gPodder / non-Pro clients
    }
    
    func getProfileSettings(profileName: String) async throws -> ProProfileSettings? {
        // No-op for gPodder / non-Pro clients
        return nil
    }
    
    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting] {
        // No-op for gPodder / non-Pro clients
        return []
    }
    
    func pushPodcastSetting(profileName: String, podcastUrl: String, payload: [String: AnyCodableValue]) async throws {
        // No-op for gPodder / non-Pro clients
    }
    
    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws {
        // Default: fall back to per-item push for non-Pro clients
        for item in items {
            try await pushPodcastSetting(profileName: profileName, podcastUrl: item.podcastUrl, payload: item.payload)
        }
    }
    
    func hideEpisodes(_ episodes: [ProHideEpisodeRequest]) async throws {
        // No-op for gPodder / non-Pro clients
    }
    
    func unhideEpisode(episodeUrl: String) async throws {
        // No-op for gPodder / non-Pro clients
    }
}

/// Simplified queue item for sync transport — avoids coupling to the
/// UI-layer `QueueItem` struct which contains presentation-only fields.
struct QueueSyncItem: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let sortOrder: Int
    let positionSec: Double?
    
    // Metadata for UI display (populated on pull, optional on push)
    let title: String?
    let podcastTitle: String?
    let artworkUrl: String?
    let durationSec: Double?
    
    /// Convenience init without metadata (for push or tests that don't need display fields).
    init(podcastUrl: String, episodeUrl: String, episodeGuid: String?,
         sortOrder: Int, positionSec: Double?,
         title: String? = nil, podcastTitle: String? = nil,
         artworkUrl: String? = nil, durationSec: Double? = nil) {
        self.podcastUrl = podcastUrl
        self.episodeUrl = episodeUrl
        self.episodeGuid = episodeGuid
        self.sortOrder = sortOrder
        self.positionSec = positionSec
        self.title = title
        self.podcastTitle = podcastTitle
        self.artworkUrl = artworkUrl
        self.durationSec = durationSec
    }
}

/// Information about a queue item explicitly dropped by the sync server
struct QueueDroppedItem {
    let episodeUrl: String
    let title: String?
    let guid: String?
    let reason: String
}

/// Return type for a full queue sync, containing both the final queue and any explicitly dropped items
struct QueueSyncResult {
    let items: [QueueSyncItem]
    let droppedItems: [QueueDroppedItem]
}

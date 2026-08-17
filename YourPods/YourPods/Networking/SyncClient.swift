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
    
    /// Fetch episode actions with server-provided timestamp for since advancement.
    /// Default implementation wraps `getEpisodeActions` with nil server timestamp.
    /// Clients that parse server timestamps should override this method.
    func getEpisodeActionsPage(since: Int) async throws -> EpisodeActionsPage
    
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

    /// Push the full queue with an optimistic-concurrency base version.
    /// The server applies only if `baseVersion` matches its current queue version,
    /// otherwise it returns 409 → `YourPodsProError.conflict`. `nil` = unconditional
    /// full-replace (legacy / no CAS). The default impl ignores the version, so the
    /// many test spies and gPodder need not implement it.
    @discardableResult
    func syncQueue(items: [QueueSyncItem], baseVersion: Int64?) async throws -> QueueSyncResult

    /// Pull the server queue together with its current version token.
    /// The default impl returns `getQueue()`'s items with `version: nil`.
    func getQueueWithVersion() async throws -> QueueSyncPullResult

    /// Delete a single queue item on the server (tombstone).
    /// Called when the user removes an episode from the queue on a Pro account.
    /// Only call when `supportsQueueSync` is `true`.
    func deleteQueueItem(episodeUrl: String) async throws

    /// Additively add a single episode to the server queue (explicit user re-add).
    /// Goes through POST /queue/add, which server-side clears completed + the deletion
    /// tombstone and resets position — unlike the full-replace syncQueue, this is
    /// additive so it can't clobber an item another device just added. No-op default.
    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws

    // MARK: - Playback Sync (YourPods Sync / Pro)
    
    /// Push current playback state for a specific episode.
    /// Used by the orchestrator to push `nowPlaying: true` with `deviceId`
    /// before queue sync, enabling cross-device handoff.
    ///
    /// `baseVersion` is the CAS baseline (per the sync contract) and is **required at every call
    /// site** — deliberately not defaulted. Swift protocol requirements cannot carry
    /// default values, so a defaulted parameter on the concrete type would stop it
    /// witnessing this requirement and dispatch silently to the no-op below. That has
    /// shipped twice. It also means every push has to make a conscious baseline decision
    /// at compile time rather than inheriting the legacy last-write-wins path by omission:
    ///
    /// - `nil` → legacy LWW. Correct only where no baseline is tracked yet.
    /// - `0`   → "I believe no row exists" (`PlaybackReconciler.baseVersionForPush`).
    /// - `N`   → the version last agreed with the server.
    ///
    /// Returns the per-episode outcome, or `nil` for clients/servers that do not answer
    /// with one. `conflicts[]` is the caller's work: a conflict nobody reads is a conflict
    /// nobody resolves, and the divergence it reported stays on screen.
    @discardableResult
    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?,
        clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse?

    /// Push episode actions and report the `version` each accepted write earned, per the sync contract.
    ///
    /// On Pro these actions are `POST /playback/sync` items, so every one of them bumps
    /// the row's version — this is the highest-frequency writer there is, firing on the
    /// user's sync interval throughout playback. Discarding the answer is what left every
    /// baseline stale from the first progress ping onward.
    ///
    /// They go out versionless on purpose and stay that way: they are gPodder-shaped rows
    /// replayed from an outbox, carrying their own (often old) event times and no
    /// per-episode baseline to speak for. Making them conditional would strand them.
    /// The ack is the part that was missing, not the baseline.
    func uploadEpisodeActionsRecordingVersions(
        _ actions: [EpisodeAction]
    ) async throws -> [ProPlaybackSyncResponse.Accepted]

    /// Get the most recent playback state from the server.
    /// Used by `reconcileNowPlayingWithServer()` to detect cross-device completion.
    /// Returns nil for gPodder/Vault (default no-op).
    func getCurrentPlayback() async throws -> ProPlaybackState?

    /// Authoritatively mark an episode unplayed on the server (relisten / mark-unplayed):
    /// clears completed + now-playing, resets position to 0, propagates via the delta.
    /// No-op for gPodder/Vault (default).
    func uncompletePlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        clientUpdatedAt: Date?
    ) async throws

    /// Resolve a proposed feed-URL rewrite.
    ///
    /// `accept` is a required part of the wire shape, not a convenience: the handler renames
    /// the subscription only when it is true, and Go decodes an absent bool to `false`, so
    /// omitting it turns the user's Accept into a Reject.
    ///
    /// **Throws on failure, and the caller must treat that as "not resolved."** The local
    /// rename may only be committed after this returns, or the library and the server end up
    /// permanently disagreeing about the feed with no way to retry.
    @discardableResult
    func resolveUrlRewrite(oldUrl: String, newUrl: String, accept: Bool) async throws -> ProResolveUrlRewriteResponse

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

/// Paginated response from getEpisodeActions, with an optional server-provided timestamp.
/// When the server provides a timestamp, use it for `since` advancement (spec-compliant).
/// When nil (mock/legacy), fall back to the newest action timestamp or wall-clock.
struct EpisodeActionsPage {
    let actions: [EpisodeAction]
    let serverTimestamp: Int?   // nil when backend/mock didn't provide one
}

// MARK: - Default No-Op Implementations

/// Default no-op for methods that only apply to YourPods Pro.
/// gPodder clients don't need to implement these.
extension SyncClient {
    var returnsFullSubscriptionList: Bool { false }
    
    /// Default implementation wraps getEpisodeActions with nil server timestamp.
    /// Clients that provide server timestamps should override this method.
    func getEpisodeActionsPage(since: Int) async throws -> EpisodeActionsPage {
        EpisodeActionsPage(actions: try await getEpisodeActions(since: since), serverTimestamp: nil)
    }

    /// Default: upload and report no versions. Same shape as `syncQueue(items:baseVersion:)`
    /// — a separate entry point so gPodder and the ~10 test spies keep witnessing the
    /// original `uploadEpisodeActions` requirement without change.
    func uploadEpisodeActionsRecordingVersions(
        _ actions: [EpisodeAction]
    ) async throws -> [ProPlaybackSyncResponse.Accepted] {
        _ = try await uploadEpisodeActions(actions)
        return []
    }
    
    func deleteQueueItem(episodeUrl: String) async throws {
        // No-op for gPodder / non-Pro clients
    }

    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws {
        // No-op for gPodder / non-Pro clients
    }

    @discardableResult
    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?,
        clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? {
        // No-op for gPodder / non-Pro clients
        return nil
    }
    
    func getCurrentPlayback() async throws -> ProPlaybackState? {
        // No-op for gPodder / non-Pro clients — returns nil
        return nil
    }

    func uncompletePlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        clientUpdatedAt: Date?
    ) async throws {
        // No-op for gPodder / non-Pro clients
    }

    /// gPodder / Vault have no rewrite endpoint. Succeeding is correct: the decision is
    /// purely local for them, so Accept must still rename the feed. Failing here would make
    /// Accept a no-op for every non-Pro user.
    @discardableResult
    func resolveUrlRewrite(oldUrl: String, newUrl: String, accept: Bool) async throws -> ProResolveUrlRewriteResponse {
        ProResolveUrlRewriteResponse(message: "no rewrite endpoint for this profile", updated: nil)
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

    // MARK: - Queue version / CAS — default no-CAS behavior

    /// Default: ignore the base version and do an unconditional full-replace
    /// (legacy behavior). `YourPodsProClient` overrides this to send `baseVersion`
    /// and map a 409 to `YourPodsProError.conflict`. Keeps the ~29 test spies and
    /// gPodder working unchanged (they only implement `syncQueue(items:)`).
    @discardableResult
    func syncQueue(items: [QueueSyncItem], baseVersion: Int64?) async throws -> QueueSyncResult {
        try await syncQueue(items: items)
    }

    /// Default: pull via `getQueue()` and report no version.
    func getQueueWithVersion() async throws -> QueueSyncPullResult {
        QueueSyncPullResult(items: try await getQueue(), version: nil)
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
    /// Server's queue version after this write. `nil` for non-Pro
    /// backends or a server that predates the version token.
    let version: Int64?

    init(items: [QueueSyncItem], droppedItems: [QueueDroppedItem], version: Int64? = nil) {
        self.items = items
        self.droppedItems = droppedItems
        self.version = version
    }
}

/// Return type for a queue pull that also carries the server's current version
/// token. `version` is `nil` for non-Pro / legacy servers.
struct QueueSyncPullResult {
    let items: [QueueSyncItem]
    let version: Int64?
}

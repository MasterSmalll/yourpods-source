import Foundation
import SwiftData
import os

// MARK: - Sync Thresholds (values pinned — do NOT change; regression risk)

/// Named constants for the position-gap thresholds used throughout sync.
/// Extracted from inline literals so they can be found, tested, and discussed.
enum SyncThresholds {
    /// Pull phase: position gap above which a conflict is detected in `syncEpisodeActions`.
    static let pullConflictGapSeconds = 5
    /// Apply phase: position gap above which a conflict is detected in `applyActionsForPodcast`.
    static let applyConflictGapSeconds = 5
    /// Pro reconciliation: position gap above which `performReconciliation` acts.
    static let reconcilePositionGapSeconds = 10
    /// Live forward seek: gap above which `syncPlaybackState` auto-seeks on track change.
    static let liveForwardSeekGapSeconds = 5
    /// Apply-side event-time comparison: how much the server's clock may trail this
    /// device's before a pulled position is judged genuinely stale (per the sync contract,
    /// apply side).
    ///
    /// A server `updatedAt` and a local `playbackEventTime` come from *different* clocks,
    /// so some allowance is required or a device running fast would never adopt anything.
    ///
    /// Kept deliberately small. Too generous and it swallows a genuinely recent local
    /// change — and the backward case does NOT self-heal: our push lands verbatim (fresh
    /// event time + `nowPlaying`), but adopting the pre-push snapshot makes the next push
    /// carry the older position *with the server's older event time*, so the merge falls
    /// to `GREATEST` and the higher, wrong position wins permanently. A few seconds
    /// covers ordinary NTP skew while staying far below any plausible
    /// seek-then-sync interval.
    ///
    /// This guesswork exists only because `/playback/current` exposes `updatedAt`
    /// (server arrival time) and not the row's `clientUpdatedAt`. Once the server
    /// returns the latter, compare event times directly and drop the allowance.
    static let remoteEventTimeSkewSeconds = 5
}

/// Per-cycle sync summary for observability and diagnostics.
struct SyncCycleSummary {
    var pushedCount: Int = 0
    var pulledCount: Int = 0
    var appliedCount: Int = 0
    var conflictCount: Int = 0
    var sinceOld: Int = 0
    var sinceNew: Int = 0
    var profileId: String = ""
}

/// A pending episode action waiting to be uploaded to the server.
struct OutboxEntry: Codable {
    let action: EpisodeAction
    let profileId: String?
    let enqueuedAt: Int
}

/// A pending `completed: true` push waiting to be delivered to the Pro server.
///
/// Fire-and-forget `Task { try? await syncPlayback(..., completed: true) }` silently
/// drops completions on App Check 403, network failures, and background cancellation.
/// The completion outbox persists the push and retries it each sync cycle until success.
struct PendingCompletion: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let durationSec: Double?
    let eventTime: Date

    /// Where the user actually was when the episode was completed.
    ///
    /// Without it the drain had nothing to send and fell back to `durationSec ?? 0` — a
    /// position nobody observed. `0` is the damaging half: the versionless merge writes it
    /// (the event-time predicate passes and the row is not now-playing), so completing an
    /// episode whose feed declares no duration erased the stored playhead.
    ///
    /// Optional because entries written by earlier builds are already on disk without it;
    /// those decode to `nil` and keep their previous behaviour.
    let positionSec: Double?

    init(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        durationSec: Double?,
        eventTime: Date,
        positionSec: Double? = nil
    ) {
        self.podcastUrl = podcastUrl
        self.episodeUrl = episodeUrl
        self.episodeGuid = episodeGuid
        self.durationSec = durationSec
        self.eventTime = eventTime
        self.positionSec = positionSec
    }
}

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

/// A single hidden state change from the server.
struct HiddenStateChange: Sendable {
    let guid: String
    let hidden: Bool
}

/// A single completed (finished) state change from the server.
/// Mirrors `HiddenStateChange`: the authoritative `completed` flag from
/// `GET /playback/recent` is applied as `isPlayed = true` on iOS, instead of
/// re-deriving completion from a lossy position>=threshold heuristic.
struct CompletedStateChange: Sendable {
    let guid: String
}

/// A single un-complete (relisten / mark-unplayed) state change from the server.
/// Emitted when a `/playback/recent` state has `completed: false`, which indicates
/// deliberate user intent on another device (re-add or start of relisten).
/// Applied by `applyUncompletedChanges` in the orchestrator after the completion
/// outbox is drained so the pending-guid guard is fully populated.
struct UncompletedStateChange: Sendable {
    let guid: String
}

/// What became of one conflict resolution, per the sync contract.
///
/// Three outcomes and not two, because `.stale` and `.failed` arrive as the same HTTP
/// status and call for opposite responses. A stale row was pruned server-side and can
/// never resolve, so retrying it loops forever and leaving it on screen offers a button
/// that cannot work; the answer is to re-read the list. A failure is recoverable and the
/// prompt should survive it.
enum ConflictResolveOutcome: Equatable, Sendable {
    /// The authoritative contract write landed — or there was no Pro client to make it.
    case landed
    /// `409 conflict_stale`: the row no longer describes current state. Refresh, don't retry.
    case stale
    /// Anything else — a 500, a dropped connection, an expired token.
    case failed
}

@MainActor
final class EpisodeActionSyncService {
    
    // MARK: - Completion Authority

    /// Whether the SERVER owns the completed flag for this profile, per the sync contract.
    ///
    /// A Pro profile receives completion as an explicit side-channel
    /// (`completedChanges` / `uncompletedChanges` → `applyCompletedChanges` /
    /// `applyUncompletedChanges`), and the contract is blunt about what the client may then
    /// do with position: it "MUST NOT re-derive completion from a local position-threshold
    /// heuristic."
    ///
    /// Not pedantry. The two authorities disagree in exactly the case that matters: un-mark
    /// an episode played elsewhere and the server sends `completed: false` while the
    /// position sits past 95%. The side-channel change is one-shot; the heuristic re-runs on
    /// every apply — so it wins by repetition and the un-complete undoes itself, with
    /// nothing on screen to explain it.
    ///
    /// gPodder, Nextcloud and Vault profiles keep the heuristic, because for them it is the
    /// only completion signal there is: those clients mark an episode played *solely* by
    /// reporting `position == total`, which is why the contract keeps the fallback scoped
    /// to them.
    var completionIsServerAuthoritative: Bool { syncClient is YourPodsProClient }

    // MARK: - Completion Threshold
    
    /// Calculates the effective "complete" position in seconds, accounting for
    /// the podcast's skipOutroSeconds. For episodes with large outros, the threshold
    /// is lowered so that reaching the content end (before the outro) counts as complete.
    ///
    /// - Parameters:
    ///   - totalDuration: Episode duration in seconds.
    ///   - skipOutroSeconds: The podcast's configured outro skip duration (0 if unset).
    /// - Returns: The position (in seconds) at or above which the episode is "effectively complete."
    nonisolated static func effectiveCompletionThreshold(totalDuration: Int, skipOutroSeconds: Int) -> Int {
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
    
    /// Summary of the most recent sync cycle (for observability / diagnostics).
    private(set) var lastSyncSummary: SyncCycleSummary?
    
    /// Hidden state changes extracted from the last `syncEpisodeActions` call.
    /// Populated when the sync client is `YourPodsProClient`, which returns
    /// hidden data alongside episode actions from the same API response.
    /// The orchestrator reads this after episode action sync instead of making
    /// a separate `getHiddenStateChanges()` call to the same endpoint.
    private(set) var lastFetchedHiddenChanges: [HiddenStateChange] = []

    /// Completed-episode changes extracted from the last `syncEpisodeActions` call.
    /// Populated (Pro clients only) from the same `/playback/recent` response as
    /// hidden changes. The orchestrator applies these so a finished-on-web episode
    /// is marked played authoritatively rather than via the position heuristic.
    private(set) var lastFetchedCompletedChanges: [CompletedStateChange] = []

    /// Un-completed-episode changes extracted from the last `syncEpisodeActions` call.
    /// Populated (Pro clients only) from the same `/playback/recent` response.
    /// The orchestrator applies these (after draining the completion outbox) so a
    /// re-add or relisten started on another device clears the played state here.
    private(set) var lastFetchedUncompletedChanges: [UncompletedStateChange] = []

    // MARK: - ActionMap Persistence Throttle
    
    /// Timestamp of the last `persistActionMap()` disk write.
    private var lastActionMapPersistTime: Date = .distantPast
    
    /// Throttle interval for actionMap persistence (60 seconds).
    /// Critical save points (sync completion, app backgrounding) use
    /// `forcePersistActionMap()` to bypass this throttle.
    private static let actionMapPersistInterval: TimeInterval = 60
    
    /// Counter for test observability — tracks how many times `persistActionMap()` was called.
    private(set) var actionMapPersistCount: Int = 0
    
    // MARK: - Outbox State
    
    /// Pending episode actions waiting to be uploaded.
    /// Key: action.guid ?? action.episode
    private(set) var outbox: [String: OutboxEntry] = [:]
    
    /// Guard to prevent re-entrant flushes.
    private var isFlushingOutbox = false

    /// Maximum number of outbox entries before oldest are dropped.
    private static let outboxMaxEntries = 500

    /// File URL for outbox persistence.
    private let outboxFileURL: URL

    // MARK: - Completion Outbox State

    /// Pending `completed: true` pushes, keyed by `episodeGuid ?? episodeUrl`.
    /// Retried each sync cycle until the Pro server confirms receipt.
    private(set) var completionOutbox: [String: PendingCompletion] = [:]

    /// Maximum entries for the completion outbox — mirrors episode-action cap.
    private static let completionOutboxMaxEntries = 500

    /// Test-injected completion outbox path override. When nil, the path is
    /// profile-scoped via `Self.completionOutboxFileURL(forProfile:)`.
    private let injectedCompletionOutboxFileURL: URL?

    /// File URL for completion outbox persistence (profile-scoped unless injected).
    private var completionOutboxFileURL: URL {
        injectedCompletionOutboxFileURL ?? Self.completionOutboxFileURL(forProfile: effectiveProfileId)
    }
    
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
            // Same deleted-model hazard as `applyActionsForPodcast`: the subs-delta
            // step of this very cycle can cascade-delete a podcast and its episodes on
            // the background writer. Reading a deleted model's @Persisted properties
            // traps in `_FullFutureBackingData.getValue`, so an unguarded index build
            // would simply relocate the crash.
            guard podcast.modelContext != nil, !podcast.isDeleted else {
                logger.debug("Skipped deleted podcast while building episode index")
                continue
            }
            for episode in podcast.episodes {
                guard episode.modelContext != nil, !episode.isDeleted else {
                    logger.debug("Skipped deleted episode while building episode index")
                    continue
                }
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
    
    /// Canonical key for actionMap entries.
    /// Always prefers GUID when the episode is known locally; falls back to URL.
    /// This prevents split-brain where server actions (keyed by URL for gpodder.net
    /// which strips GUIDs) and local actions (keyed by GUID) never meet.
    func canonicalActionKey(for action: EpisodeAction, index: EpisodeIndex) -> String {
        // If action has a GUID and we know that episode locally, use GUID
        if let guid = action.guid, index.byGuid[guid] != nil {
            return guid
        }
        // If action has an episode URL and we can find the episode, use its GUID
        if let entry = index.byAudioUrl[action.episode] {
            return entry.episode.guid
        }
        // Fallback: use whatever the action provides (guid ?? episode URL)
        return action.guid ?? action.episode
    }
    
    // MARK: - File-Based ActionMap Persistence
    
    /// File URL for the action map JSON file (replaces UserDefaults for large maps).
    /// The default (nil / "global") profile keeps the legacy unsuffixed filename for
    /// backward compatibility; named profiles get a `_<profileId>` suffix so positions
    /// never leak across profiles.
    static var actionMapFileURL: URL {
        actionMapFileURL(forProfile: nil)
    }

    /// Profile-scoped action map path. Named profiles get a `_<profileId>` suffix; the
    /// default (nil / "global") profile keeps the legacy unsuffixed filename.
    static func actionMapFileURL(forProfile profileId: String?) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let profileId, profileId != "global" {
            return appSupport.appendingPathComponent("episodeActionMap_\(profileId).json")
        }
        return appSupport.appendingPathComponent("episodeActionMap.json")
    }

    /// Profile-scoped completion outbox path. Mirrors `actionMapFileURL(forProfile:)`.
    static func completionOutboxFileURL(forProfile profileId: String?) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let profileId, profileId != "global" {
            return appSupport.appendingPathComponent("pendingCompletionOutbox_\(profileId).json")
        }
        return appSupport.appendingPathComponent("pendingCompletionOutbox.json")
    }
    
    // MARK: - Dependencies (injected)
    
    private let modelContext: ModelContext
    private let subscriptionsProvider: () -> [Podcast]
    private let syncClientProvider: () -> SyncClient?
    private let profileIdProvider: () -> String?
    private let deviceIdProvider: () -> String

    /// Where to record the versions the outbox flush earns, per the sync contract. A closure
    /// rather than the store itself so `PlayerManager.playbackBaselines` stays lazy — it is a
    /// file read, deliberately deferred to first sync rather than paid at launch. `nil` where
    /// there is nothing to record: gPodder, and tests asserting on what went out.
    var playbackBaselinesProvider: (() -> PlaybackBaselineStore?)?
    private let queueItemsProvider: () -> [QueueItem]
    
    /// Pre-save store health check. Returns `true` if the store is safe to write.
    /// Injected for testability — production uses `StoreHealthProbe.rawWriteProbe`.
    private let storeHealthCheck: @Sendable () -> Bool
    
    /// Background write actor — when set, the cooperative apply path delegates here.
    private(set) var syncStore: SyncStore?
    
    /// Live read of the currently-playing episode's GUID (for SyncStore's playing-guid
    /// exclusion). MainActor-isolated and `@Sendable` so the background actor can re-read
    /// it across the actor boundary per podcast (`await`) for a fresh value.
    var currentlyPlayingGuidProvider: (@MainActor @Sendable () -> String?)?
    
    /// Called after SyncStore writes, so the main context can refresh.
    var onMainContextRefreshNeeded: (() -> Void)?
    
    private let logger = Logger(subsystem: "com.yourpods", category: "episodeActionSync")
    
    // MARK: - Init
    
    init(
        modelContext: ModelContext,
        subscriptionsProvider: @escaping () -> [Podcast],
        syncClientProvider: @escaping () -> SyncClient?,
        profileIdProvider: @escaping () -> String?,
        deviceIdProvider: @escaping () -> String,
        queueItemsProvider: @escaping () -> [QueueItem] = { [] },
        storeHealthCheck: @escaping @Sendable () -> Bool = { true },
        syncStore: SyncStore? = nil,
        outboxFileURL: URL? = nil,
        completionOutboxFileURL: URL? = nil
    ) {
        self.modelContext = modelContext
        self.subscriptionsProvider = subscriptionsProvider
        self.syncClientProvider = syncClientProvider
        self.profileIdProvider = profileIdProvider
        self.deviceIdProvider = deviceIdProvider
        self.queueItemsProvider = queueItemsProvider
        self.storeHealthCheck = storeHealthCheck
        self.syncStore = syncStore

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let outboxFileURL {
            self.outboxFileURL = outboxFileURL
        } else {
            self.outboxFileURL = appSupport.appendingPathComponent("pendingActionOutbox.json")
        }
        self.injectedCompletionOutboxFileURL = completionOutboxFileURL
    }
    
    /// Set the SyncStore after initialization (called from PodcastManager.init).
    /// Pass nil to disable background delegation (used by parity tests).
    func setSyncStore(_ store: SyncStore?) {
        self.syncStore = store
    }

    // MARK: - Pro delta cursor (sync contract)

    /// Opaque `?since=` cursor for the Pro `/playback/recent` delta, stored per profile.
    /// Kept separate from the Unix `lastEpisodeActionSync_*` cursor, which remains the
    /// gPodder contract — the two servers parse `?since=` differently.
    private static func cursorTokenKey(profileId: String) -> String {
        "lastEpisodeActionSyncToken_\(profileId)"
    }

    private static func storedCursorToken(profileId: String) -> String? {
        UserDefaults.standard.string(forKey: cursorTokenKey(profileId: profileId))
    }

    /// The cursor the server handed back on the last pull, **not yet committed**.
    ///
    /// The cursor used to be written the moment it arrived, which marks a window consumed
    /// before anything has consumed it. Two ways that loses changes for good, since the
    /// server will not resend a window the client has acknowledged:
    ///
    /// 1. **Routine.** Only `ProSyncOrchestrator` applies the hidden / completed /
    ///    uncompleted side-channels. `PlayerManager.syncPlaybackState` pulls on every
    ///    episode change and applies none of them — so each track change fetched a window
    ///    of state changes, advanced past it, and dropped it.
    /// 2. **On cancellation or crash.** The orchestrator's own comment says the in-memory
    ///    mutations are "re-applied on the next sync if this one is cancelled". That is
    ///    only true while the cursor has not already moved past them.
    ///
    /// Discarding the pending token is always safe: the window is re-delivered and the
    /// applies are idempotent. Committing it without applying is not.
    private var pendingCursorToken: (token: String, profileId: String)?

    /// Acknowledge the last pulled window — call **after** its changes have been applied.
    ///
    /// A caller that does not apply the side-channels simply never calls this, and the
    /// window is re-delivered to one that does. That costs a repeated fetch; the
    /// alternative costs the changes themselves.
    func commitCursorToken() {
        guard let pending = pendingCursorToken else { return }
        Self.storeCursorToken(pending.token, profileId: pending.profileId)
        pendingCursorToken = nil
        logger.info("Committed delta cursor after applying its changes")
    }

    /// Test seam: whether a pulled window is still waiting to be acknowledged.
    var hasPendingCursorToken: Bool { pendingCursorToken != nil }

    private static func storeCursorToken(_ token: String, profileId: String) {
        UserDefaults.standard.set(token, forKey: cursorTokenKey(profileId: profileId))
    }
    
    // MARK: - Convenience accessors
    
    private var subscriptions: [Podcast] { subscriptionsProvider() }
    private var syncClient: SyncClient? { syncClientProvider() }
    private var activeProfileId: String? { profileIdProvider() }
    private var deviceId: String { deviceIdProvider() }

    /// Profile whose episode-action state (action map, completion outbox) is currently
    /// resident in memory. Resolved from `activeProfileId` on load; updated by
    /// `switchProfile`. Tracked separately from `activeProfileId` so a switch can
    /// persist the OUTGOING profile's files before the active id changes.
    private var loadedProfileId: String?

    /// Profile id used to compute scoped file paths — the resident profile if loaded,
    /// otherwise the live active profile, otherwise "global".
    private var effectiveProfileId: String { loadedProfileId ?? (activeProfileId ?? "global") }

    /// Profile-scoped action map file URL for the resident profile.
    private var currentActionMapFileURL: URL { Self.actionMapFileURL(forProfile: effectiveProfileId) }
    
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
        
        // Push-before-pull: flush any pending outbox entries before pulling.
        let pushedCount = await flushOutboxReturningCount()
        
        // When force=true, pull ALL history (since=0).
        // Otherwise use the last sync timestamp for incremental sync.
        let epProfileId = activeProfileId ?? "global"
        let since = force ? 0 : UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(epProfileId)")
        logger.info("Fetching episode actions since \(since) (force=\(force))...")

        // Use the combined method for Pro clients to avoid a duplicate
        // network round-trip — getEpisodeActions and getHiddenStateChanges
        // both hit the same /playback/recent endpoint.
        let actions: [EpisodeAction]
        var serverTimestamp: Int? = nil
        if let proClient = client as? YourPodsProClient {
            // Pro uses the server's own RFC3339 token as an OPAQUE cursor
            // (per the sync contract). The Unix `since` above is the shared SyncClient
            // contract and stays the gPodder cursor; re-deriving Pro's from
            // `max(action.timestamp)` meant following whichever *client* clock wrote
            // the newest action, so a device running fast would starve itself of
            // changes the moment the server honours our cursor.
            let sinceToken = force ? nil : Self.storedCursorToken(profileId: epProfileId)
            let pulled = try await proClient.getEpisodeActionsWithHiddenChanges(sinceToken: sinceToken)
            actions = pulled.actions
            lastFetchedHiddenChanges = pulled.hiddenChanges
            lastFetchedCompletedChanges = pulled.completedChanges
            lastFetchedUncompletedChanges = pulled.uncompletedChanges
            // Held, not stored — see `commitCursorToken`. Advancing the cursor here marks
            // this window consumed before anything has consumed it.
            if let token = pulled.serverToken {
                pendingCursorToken = (token: token, profileId: epProfileId)
            }
            logger.info("Received \(actions.count) episode actions + \(pulled.hiddenChanges.count) hidden changes + \(pulled.completedChanges.count) completed changes + \(pulled.uncompletedChanges.count) uncompleted changes from server (combined call, cursor=\(pulled.serverToken ?? "nil", privacy: .public))")
        } else {
            let page = try await client.getEpisodeActionsPage(since: since)
            actions = page.actions
            serverTimestamp = page.serverTimestamp
            lastFetchedHiddenChanges = []
            lastFetchedCompletedChanges = []
            lastFetchedUncompletedChanges = []
            logger.info("Received \(actions.count) episode actions from server (serverTs=\(serverTimestamp.map(String.init) ?? "nil"))")
        }
        
        var conflicts: [SyncConflict] = []
        let index = buildEpisodeIndex()
        
        for action in actions {
            let key = canonicalActionKey(for: action, index: index)
            let existing = actionMap[key]
            
            if let existing, let existingPos = existing.position, let newPos = action.position {
                // Echo guard: identical position is never a conflict.
                // This catches push-before-pull echoes where the server returns
                // our own just-pushed action in the same sync cycle.
                if existingPos == newPos {
                    if action.timestamp >= existing.timestamp {
                        actionMap[key] = action.preservingDevice(from: existing)
                    }
                    continue
                }
                
                // Only overwrite actionMap when the server action is newer
                if action.timestamp >= existing.timestamp {
                    actionMap[key] = action
                } else {
                    // Server action is older than our actionMap entry — this is stale
                    // history from a full pull (since=0), not a new cross-device change.
                    // Skip conflict detection to prevent the "swapped labels" bug where
                    // a re-sync shows Device=server-pos and Server=old-device-pos.
                    continue
                }
                
                // Skip conflict when local position is 0 — episode hasn't been
                // touched on this device, so server position is authoritative.
                // This prevents conflict spam on first sync.
                guard existingPos > 0 else { continue }
                
                // Use the Episode model's listenedSeconds as the true device position.
                // The actionMap's existingPos may contain a server-originated value from
                // a previous sync cycle, which would cause the "Device" label in the
                // conflict wizard to show a server position instead of the actual device position.
                let devicePos = lookupDevicePosition(guid: key, audioUrlFallback: action.episode, fallback: existingPos)
                
                if abs(devicePos - newPos) > SyncThresholds.pullConflictGapSeconds {
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
                            localPosition: devicePos,
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
        
        // Since advancement: prefer server timestamp, fall back to newest action, else keep unchanged.
        let newSinceValue: Int
        if let serverTs = serverTimestamp {
            newSinceValue = serverTs
        } else if let newest = actions.map(\.timestamp).max() {
            newSinceValue = max(since, newest)
        } else {
            newSinceValue = since
        }
        if newSinceValue < since {
            logger.info("Since rewound (\(since) → \(newSinceValue)) — one-time overlap re-pull expected")
        }
        UserDefaults.standard.set(newSinceValue, forKey: "lastEpisodeActionSync_\(epProfileId)")
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
        
        // Record sync summary for observability
        var summary = SyncCycleSummary()
        summary.pushedCount = pushedCount
        summary.pulledCount = actions.count
        summary.appliedCount = totalStored
        summary.conflictCount = allConflicts.count
        summary.sinceOld = since
        summary.sinceNew = newSinceValue
        summary.profileId = epProfileId
        lastSyncSummary = summary
        
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
                // Re-validate store health before each batch save.
                // The store may have become unhealthy since the initial check
                // (e.g., iOS revoking file access during background task expiration).
                guard storeHealthCheck() else {
                    logger.warning("Store health check failed mid-loop — aborting saves (\(updatedCount) episodes mutated, \(saveCount) saves completed)")
                    return (unresolvedConflicts, saveCount)
                }
                if modelContext.safeSave() {
                    saveCount += 1
                } else {
                    logger.error("Batch save failed at \(updatedCount) episodes")
                }
                dirtyAcrossPodcasts = 0
            }
        }
        
        // Final save for remaining dirty episodes
        if dirtyAcrossPodcasts > 0 {
            guard storeHealthCheck() else {
                logger.warning("Store health check failed before final save — skipping (\(updatedCount) episodes mutated, \(saveCount) saves completed)")
                return (unresolvedConflicts, saveCount)
            }
            if modelContext.safeSave() {
                saveCount += 1
            } else {
                logger.error("Final save failed at \(updatedCount) episodes")
            }
        }
        
        logger.info("Applied listen status (sync) to \(updatedCount) episodes (strategy: \(strategy.rawValue), \(unresolvedConflicts.count) unresolved, \(saveCount) saves)")
        return (unresolvedConflicts, saveCount)
    }
    
    /// Unified async core with cooperative yielding support.
    func applyEpisodeActionsCore(strategy: SyncStrategy, cooperative: Bool) async -> ([SyncConflict], Int) {
        // ── SyncStore delegation (background actor) ──
        // When cooperative mode is on AND a SyncStore is wired, delegate the
        // heavy write loop to the background actor. The main-context mutations
        // are replaced by a single reconcile after the actor saves.
        if cooperative, let store = syncStore {
            let outcome = await store.applyEpisodeActions(
                actionMap: actionMap,
                strategy: strategy,
                deviceId: deviceId,
                completionIsServerAuthoritative: completionIsServerAuthoritative,
                currentlyPlayingGuidProvider: currentlyPlayingGuidProvider
            )
            onMainContextRefreshNeeded?()
            // Apply the skipped now-playing-episode actions on main. SyncStore excludes
            // them (re-evaluated per podcast) to avoid racing with the progress timer; we
            // can safely apply them here since MainActor owns playback state. A mid-loop
            // switch can leave more than one excluded episode, so iterate.
            for skippedAction in outcome.skippedActionsForPlayingEpisodes {
                guard let guid = skippedAction.guid,
                      let position = skippedAction.position, position > 0 else { continue }
                applySkippedActionOnMain(guid: guid, action: skippedAction, strategy: strategy)
            }
            // Re-apply occurrence counts (tracked on MainActor, not in SyncStore)
            let countedConflicts = outcome.conflicts.map { conflict in
                SyncConflict(
                    episodeGuid: conflict.episodeGuid,
                    episodeTitle: conflict.episodeTitle,
                    podcastTitle: conflict.podcastTitle,
                    podcastUrl: conflict.podcastUrl,
                    artworkUrl: conflict.artworkUrl,
                    audioUrl: conflict.audioUrl,
                    localPosition: conflict.localPosition,
                    serverPosition: conflict.serverPosition,
                    serverTimestamp: conflict.serverTimestamp,
                    totalDuration: conflict.totalDuration,
                    occurrenceCount: incrementConflictCount(for: conflict.episodeGuid)
                )
            }
            return (countedConflicts, outcome.saveCount)
        }
        
        // Cancellation gate BEFORE the write probe: a cancelled task (BGTask
        // expiration, app backgrounding) must not open new SQLite write
        // transactions on its way out — the probe itself is 3 write
        // transactions, each a suspension-kill window (0xDEAD10CC).
        if cooperative && Task.isCancelled {
            logger.info("applyEpisodeActionsCore cancelled before start — skipping probe and apply")
            return ([], 0)
        }

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
                // Re-validate store health before each batch save.
                // The store may have become unhealthy since the initial check
                // (e.g., iOS revoking file access during background task expiration).
                guard storeHealthCheck() else {
                    logger.warning("Store health check failed mid-loop — aborting saves (\(updatedCount) episodes mutated, \(saveCount) saves completed)")
                    return (unresolvedConflicts, saveCount)
                }
                if modelContext.safeSave() {
                    saveCount += 1
                } else {
                    logger.error("Batch save failed at \(updatedCount) episodes")
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
                guard storeHealthCheck() else {
                    logger.warning("Store health check failed before final save — skipping (\(updatedCount) episodes mutated, \(saveCount) saves completed)")
                    return (unresolvedConflicts, saveCount)
                }
                if modelContext.safeSave() {
                    saveCount += 1
                } else {
                    logger.error("Final save failed at \(updatedCount) episodes")
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
    /// **Crash fix:** `modelContext.save()` is now called OUTSIDE the
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
    /// **Performance fix:** Saves are now handled by the caller
    /// (`applyEpisodeActionsCore` / `applyEpisodeActionsWithStats`) using cross-podcast
    /// batch saves. This reduces save count from O(podcasts) to O(total_episodes/500).
    ///
    /// **Crash fix:** Episode mutations happen inside autoreleasepools
    /// but saves happen outside — prevents `__CFStringEqual` signal crash from
    /// bridged NSString temporaries being drained before Core Data's column diff.
    private func applyActionsForPodcast(
        _ podcast: Podcast,
        strategy: SyncStrategy,
        cooperative: Bool = false
    ) -> (conflicts: [SyncConflict], updated: Int) {
        var updatedCount = 0
        var unresolvedConflicts: [SyncConflict] = []

        // A background step earlier in this same sync cycle can delete this podcast
        // out from under us — `SyncStore.deletePodcasts(urls:)` cascade-deletes the
        // Podcast and its Episodes on the subs-delta step while the main context is
        // still holding them. Reading any @Persisted property on a deleted model
        // traps in `_FullFutureBackingData.getValue` (an uncatchable
        // `_assertionFailure`, not a Swift error) — see `Podcast.effectiveSettings`,
        // which guards the identical hazard.
        guard podcast.modelContext != nil, !podcast.isDeleted else {
            logger.debug("Skipped deleted podcast during episode-action apply")
            return ([], 0)
        }

        let conflictThreshold = SyncThresholds.applyConflictGapSeconds
        let batchSize = 50
        let episodes = podcast.episodes

        for batchStart in stride(from: 0, to: episodes.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, episodes.count)

            // Mutate episode properties inside the autoreleasepool to contain
            // temporary Obj-C objects from SwiftData property access.
            autoreleasepool {
                for i in batchStart..<batchEnd {
                    let episode = episodes[i]

                    // Same hazard per-episode: the cascade can invalidate an
                    // individual Episode even when its Podcast survives.
                    guard episode.modelContext != nil, !episode.isDeleted else {
                        logger.debug("Skipped deleted episode during episode-action apply")
                        continue
                    }

                    let action = actionMap[episode.guid] ?? (episode.audioUrl.flatMap { actionMap[$0] })
                    guard let action else { continue }
                    
                    if let serverPosition = action.position, serverPosition > 0 {
                        let localPosition = episode.listenedSeconds
                        
                        switch strategy {
                        case .serverWins:
                            episode.setListenedSecondsIfChanged(serverPosition)
                            
                        case .deviceWins:
                            if localPosition == 0 {
                                episode.setListenedSecondsIfChanged(serverPosition)
                            }
                            // When localPosition > 0, device position is always kept
                            
                        case .ask:
                            if episode.isPlayed {
                                episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                            } else {
                                let total = episode.durationSeconds ?? 0
                                let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                                let completionThreshold = Self.effectiveCompletionThreshold(totalDuration: total, skipOutroSeconds: skipOutro)
                                let isEffectivelyComplete = total > 60 && (
                                    localPosition >= completionThreshold ||
                                    serverPosition >= completionThreshold
                                )
                                
                                if isEffectivelyComplete {
                                    episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                                } else if localPosition == 0 {
                                    episode.setListenedSecondsIfChanged(serverPosition)
                                } else if abs(serverPosition - localPosition) > conflictThreshold {
                                    // Same-device check: if the actionMap entry was written by
                                    // THIS device, the gap is a stale SwiftData disk save from
                                    // iOS background RunLoop throttling, not a real cross-device
                                    // conflict. Silently adopt max(local, server).
                                    if action.device != nil && action.device == deviceId {
                                        episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
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
                                    episode.setListenedSecondsIfChanged(max(localPosition, serverPosition))
                                }
                            }
                        }
                    }
                    
                    // Mark as played if position is at or past the completion threshold.
                    // Fall back to episode.durationSeconds when the server action
                    // doesn't include a `total` field (optional in gPodder spec).
                    // Skipped entirely when the server owns the flag (sync contract) — see
                    // `completionIsServerAuthoritative`.
                    let effectiveTotal = action.total ?? episode.durationSeconds
                    if !completionIsServerAuthoritative,
                       let position = action.position, let total = effectiveTotal, total > 60, position > 60 {
                        let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                        let completionThreshold = Self.effectiveCompletionThreshold(totalDuration: total, skipOutroSeconds: skipOutro)
                        if position >= completionThreshold {
                            episode.markPlayedIfNeeded()
                        }
                    }
                    
                    updatedCount += 1
                }
            }
        }
        
        return (unresolvedConflicts, updatedCount)
    }
    // MARK: - Skipped Action Application (Main Context)

    /// Apply a single episode action that was skipped by SyncStore because
    /// the episode was currently playing.
    ///
    /// Called on MainActor after SyncStore completes. Since the main actor owns
    /// the playback state, it can safely update the episode's listened position
    /// without racing with the progress timer.
    ///
    /// For `serverWins` and `deviceWins` (from 0), the server position is applied.
    /// For `ask`, only applies if the position doesn't create a conflict.
    private func applySkippedActionOnMain(guid: String, action: EpisodeAction, strategy: SyncStrategy) {
        guard let position = action.position, position > 0 else { return }

        for podcast in subscriptions {
            guard let episode = podcast.episodes.first(where: { $0.guid == guid }) else { continue }

            let localPosition = episode.listenedSeconds

            switch strategy {
            case .serverWins:
                episode.setListenedSecondsIfChanged(position)
            case .deviceWins:
                if localPosition == 0 {
                    episode.setListenedSecondsIfChanged(position)
                }
            case .ask:
                // For the playing episode, adopt max to avoid overwriting
                // the user's current position mid-listen
                episode.setListenedSecondsIfChanged(max(localPosition, position))
            }

            // Mark played at completion threshold — same contract exclusion as the main loop.
            let effectiveTotal = action.total ?? episode.durationSeconds
            if !completionIsServerAuthoritative, let total = effectiveTotal, total > 60, position > 60 {
                let skipOutro = podcast.effectiveSettings.skipOutroSeconds ?? 0
                let threshold = Self.effectiveCompletionThreshold(totalDuration: total, skipOutroSeconds: skipOutro)
                if position >= threshold {
                    episode.markPlayedIfNeeded()
                }
            }

            logger.info("Applied skipped playing-episode action for \(guid): position=\(position)")
            return
        }
    }

    // MARK: - Send / Get Actions
    
    /// Push a single episode action to the server and update local map.
    /// Uses the outbox for reliability — enqueues, then flushes.
    func sendEpisodeAction(_ action: EpisodeAction) async {
        enqueueOutboxAction(action)
        await flushOutbox()
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
        let index = buildEpisodeIndex()
        let key = canonicalActionKey(for: action, index: index)
        actionMap[key] = action
    }
    
    // MARK: - Outbox (Push Reliability)
    
    /// Enqueue an episode action for later upload.
    /// Updates actionMap immediately (local-first); if no sync client is configured
    /// (Vault mode), only the actionMap is updated.
    func enqueueOutboxAction(_ action: EpisodeAction) {
        let index = buildEpisodeIndex()
        let key = canonicalActionKey(for: action, index: index)
        actionMap[key] = action
        throttledPersistActionMap()
        
        // Vault mode: no sync client → no point enqueuing for upload
        guard syncClient != nil else { return }
        
        let entry = OutboxEntry(
            action: action,
            profileId: activeProfileId,
            enqueuedAt: Int(Date().timeIntervalSince1970)
        )
        outbox[key] = entry
        
        // Cap enforcement: drop oldest entries beyond the limit
        if outbox.count > Self.outboxMaxEntries {
            let sortedKeys = outbox.sorted {
                if $0.value.enqueuedAt != $1.value.enqueuedAt {
                    return $0.value.enqueuedAt < $1.value.enqueuedAt
                }
                return $0.value.action.timestamp < $1.value.action.timestamp
            }
            let excess = outbox.count - Self.outboxMaxEntries
            for (dropKey, _) in sortedKeys.prefix(excess) {
                outbox.removeValue(forKey: dropKey)
            }
        }
        
        persistOutbox()
    }
    
    /// Flush all outbox entries for the active profile to the server.
    /// On success, removes entries. On failure, entries remain for retry.
    func flushOutbox() async {
        _ = await flushOutboxReturningCount()
    }
    
    /// Flush outbox and return the number of actions successfully pushed.
    func flushOutboxReturningCount() async -> Int {
        guard !isFlushingOutbox else { return 0 }
        guard !Task.isCancelled else { return 0 }
        guard let client = syncClient else { return 0 }
        
        let currentProfileId = activeProfileId
        let snapshot = outbox.filter { $0.value.profileId == currentProfileId }
        guard !snapshot.isEmpty else { return 0 }
        
        isFlushingOutbox = true
        defer { isFlushingOutbox = false }
        
        let actions = snapshot.map(\.value.action)
        var totalPushed = 0
        
        // Upload in chunks of 50
        for chunkStart in stride(from: 0, to: actions.count, by: 50) {
            guard !Task.isCancelled else { break }
            
            let chunkEnd = min(chunkStart + 50, actions.count)
            let chunk = Array(actions[chunkStart..<chunkEnd])
            
            do {
                // Per the sync contract: these writes bump each row's `version`, so their acks
                // are the only thing keeping the per-episode baselines current during playback.
                // Dropping them made every later versioned push stale on arrival — and a
                // refusal is persisted as a `sync_conflicts` row, so the device raised a sheet
                // against its own progress reporting. See `PlaybackBaselineStore.advanceVersion`.
                let acks = try await client.uploadEpisodeActionsRecordingVersions(chunk)
                if let baselines = playbackBaselinesProvider?(), !acks.isEmpty {
                    for ack in acks {
                        baselines.advanceVersion(episodeUrl: ack.episodeUrl, version: ack.version)
                    }
                    baselines.persist()
                }
                totalPushed += chunk.count

                // Remove entries only if they haven't been replaced since the snapshot
                for action in chunk {
                    let key = action.guid ?? action.episode
                    if let current = outbox[key],
                       current.enqueuedAt == snapshot[key]?.enqueuedAt {
                        outbox.removeValue(forKey: key)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                logger.error("Outbox flush failed: \(error.localizedDescription)")
                break
            }
        }
        
        if totalPushed > 0 {
            persistOutbox()
            logger.info("Flushed \(totalPushed) outbox entries to server")
        }
        
        return totalPushed
    }
    
    /// Load outbox from disk.
    func loadOutbox() {
        guard FileManager.default.fileExists(atPath: outboxFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: outboxFileURL)
            outbox = try JSONDecoder().decode([String: OutboxEntry].self, from: data)
            let count = outbox.count
            logger.info("Loaded \(count) pending outbox entries from file")
        } catch {
            logger.error("Failed to load outbox: \(error.localizedDescription)")
        }
    }
    
    /// Persist outbox to disk.
    func persistOutbox() {
        do {
            let data = try JSONEncoder().encode(outbox)
            try FileManager.default.createDirectory(
                at: outboxFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outboxFileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist outbox: \(error.localizedDescription)")
        }
    }
    
    /// Remove all outbox entries for a specific profile (used during profile deletion).
    func removeOutboxEntries(forProfileId profileId: String) {
        let before = outbox.count
        outbox = outbox.filter { $0.value.profileId != profileId }
        let removed = before - outbox.count
        if removed > 0 {
            persistOutbox()
            logger.info("Removed \(removed) outbox entries for profile \(profileId)")
        }
    }

    // MARK: - Completion Outbox

    /// Enqueue a `completed: true` push for later delivery.
    ///
    /// Key: `episodeGuid ?? episodeUrl`. A second enqueue for the same episode
    /// overwrites the entry (idempotent — the server is the arbiter of completion).
    /// Persists to disk immediately so restarts don't lose the push.
    func enqueueCompletion(_ pending: PendingCompletion) {
        let key = pending.episodeGuid ?? pending.episodeUrl
        completionOutbox[key] = pending

        // Cap enforcement: drop oldest entries beyond the limit.
        if completionOutbox.count > Self.completionOutboxMaxEntries {
            let sorted = completionOutbox.sorted { $0.value.eventTime < $1.value.eventTime }
            let excess = completionOutbox.count - Self.completionOutboxMaxEntries
            for (dropKey, _) in sorted.prefix(excess) {
                completionOutbox.removeValue(forKey: dropKey)
            }
        }

        if pending.durationSec == nil {
            logger.debug("Enqueued completion for \(key) with nil durationSec — positionSec will be sent as 0")
        }
        persistCompletionOutbox()
        logger.debug("Enqueued completion for \(key) (outbox size: \(self.completionOutbox.count))")
    }

    /// Returns the set of GUIDs (or episode URLs for guid-less entries) that are
    /// waiting in the completion outbox. Used as a guard to skip applying
    /// a server-side un-complete for an episode we're about to re-complete.
    func pendingCompletionGuids() -> Set<String> {
        Set(completionOutbox.keys)
    }

    /// Drain all pending completions to the server.
    ///
    /// Each entry is pushed via `syncPlayback(... completed: true, clientUpdatedAt: eventTime)`.
    /// An entry is removed ONLY on success; on throw it stays for the next cycle.
    /// The drain is gated on `Task.isCancelled` at the top and between entries so
    /// a cancelled sync (BGTask expiration) cannot keep pushing after the deadline.
    ///
    /// - Parameter baselines: where to record the CAS version each push earns, per the sync
    ///   contract. `nil` for clients that have no version to report — gPodder, and tests
    ///   asserting on what went out rather than what came back. Not optional in spirit:
    ///   without it the device argues with its own completion on the next push (see the ack
    ///   handling below).
    func drainCompletionOutbox(using client: any SyncClient, baselines: PlaybackBaselineStore?) async {
        guard !Task.isCancelled else {
            logger.debug("drainCompletionOutbox: cancelled before start — skipping")
            return
        }
        guard !completionOutbox.isEmpty else { return }

        let snapshot = completionOutbox
        var successCount = 0
        var recordedBaseline = false

        for (key, pending) in snapshot {
            guard !Task.isCancelled else {
                logger.debug("drainCompletionOutbox: cancelled after \(successCount) pushes — stopping")
                break
            }

            do {
                let response = try await client.syncPlayback(
                    podcastUrl: pending.podcastUrl,
                    episodeUrl: pending.episodeUrl,
                    episodeGuid: pending.episodeGuid,
                    // The position that was actually observed when the episode was
                    // completed. `durationSec` is the fallback for entries written before
                    // `positionSec` existed — an episode marked played is at its end, so
                    // that keeps their behaviour — and `0` only when neither is known.
                    //
                    // `durationSec ?? 0` alone was the bug: a feed that declares no
                    // duration pushed a literal `positionSec: 0`, and the versionless
                    // merge writes it. The event-time predicate passes (this push is the
                    // newest) and `(EXCLUDED.now_playing OR NOT playback_states.now_playing)`
                    // holds for a paused row, so the `THEN EXCLUDED.position_sec` branch
                    // takes it: completing the episode erased where the user was in it.
                    positionSec: pending.positionSec ?? pending.durationSec ?? 0,
                    durationSec: pending.durationSec,
                    nowPlaying: false,
                    completed: true,
                    deviceId: deviceId,
                    clientUpdatedAt: pending.eventTime,
                    // Sync contract: still legacy last-write-wins on the way OUT. A completion must
                    // land unconditionally — it is a decision the user already made — and a
                    // baseline here would let it conflict instead. The answer is still worth
                    // keeping, which is what the ack below is for.
                    baseVersion: nil
                )

                // The push bumped the server's `version`, and this device has to keep it.
                // Discarding the ack is what made mark-as-played raise a sheet against its
                // own completion: the baseline stayed at the pre-completion version, the
                // next versioned push carried it, the server refused, and current server
                // releases persist a refusal as a `sync_conflicts` row. Reported as "I marked
                // an episode as played from ios and immediately got a sync conflict".
                //
                // Matched on `episodeUrl` rather than trusted positionally: the sync contract
                // has the server echo it byte-for-byte and `PlaybackBaselineStore` keys on it
                // verbatim, so an ack that does not match what this entry pushed did not
                // round-trip and there is no agreement to record. Same guard as
                // `PlaybackSyncCoordinator.apply`.
                //
                // The flag comes from the SERVER, not from what this push asserted. Because
                // the push is versionless it goes through the merge, where a strictly-older
                // event time keeps the stored flag — so a completion can be accepted and
                // still not land, and recording the asserted `true` would claim an
                // agreement this device never had. `syncedCompleted` is what attributes the
                // next completion divergence in the step (0) ladder, so a wrong flag
                // resolves a later conflict the wrong way (per the sync contract).
                //
                // `nil` means the server predates the field: fall back to what was
                // asserted, which is the behaviour before it existed and is correct against
                // the currently-deployed build.
                if let baselines, let response {
                    for ack in response.accepted where ack.episodeUrl == pending.episodeUrl {
                        baselines.recordAgreement(
                            episodeUrl: ack.episodeUrl,
                            version: ack.version,
                            completed: ack.completed ?? true
                        )
                        recordedBaseline = true
                    }
                }

                // Remove only on success — keep on throw for retry
                completionOutbox.removeValue(forKey: key)
                successCount += 1
            } catch is CancellationError {
                logger.debug("drainCompletionOutbox: CancellationError for \(key) — stopping drain")
                break
            } catch {
                logger.error("drainCompletionOutbox: failed for \(key): \(error.localizedDescription) — will retry next sync")
            }
        }

        if successCount > 0 {
            persistCompletionOutbox()
            logger.info("drainCompletionOutbox: pushed \(successCount) completion(s) (\(self.completionOutbox.count) remaining)")
        }
        // Once per drain, not per entry: a baseline that only lives in memory is worse than
        // none — the next cold start pushes the pre-completion version and re-raises the
        // sheet this fix exists to prevent, while looking correct for one session.
        if recordedBaseline {
            baselines?.persist()
        }
    }

    /// Load completion outbox from disk (call once during init/restore).
    func loadCompletionOutbox() {
        // One-time migration: a named profile adopts the pre-scoping global outbox file.
        if injectedCompletionOutboxFileURL == nil {
            migrateLegacyGlobalFileIfNeeded(
                legacy: Self.completionOutboxFileURL(forProfile: nil),
                scoped: completionOutboxFileURL, label: "completion outbox")
        }
        guard FileManager.default.fileExists(atPath: completionOutboxFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: completionOutboxFileURL)
            completionOutbox = try JSONDecoder().decode([String: PendingCompletion].self, from: data)
            logger.info("Loaded \(self.completionOutbox.count) pending completion(s) from disk")
        } catch {
            logger.error("Failed to load completion outbox: \(error.localizedDescription)")
        }
    }

    /// Persist completion outbox to disk (atomic write).
    private func persistCompletionOutbox() {
        do {
            let data = try JSONEncoder().encode(completionOutbox)
            try FileManager.default.createDirectory(
                at: completionOutboxFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: completionOutboxFileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist completion outbox: \(error.localizedDescription)")
        }
    }

    // MARK: - Conflict Resolution

    /// The identifier to send in the `episodeUrl` field when resolving a conflict.
    ///
    /// A `SyncConflict` carries an optional `audioUrl`, so reaching straight for the GUID
    /// whenever it was nil put a GUID in a field named for a URL — which matched no stored
    /// conflict row, 404'd, and wrote nothing. The episode is usually in the library even
    /// when the conflict record isn't, so look there before giving up on having a URL.
    /// The GUID is the last resort, not the default.
    nonisolated static func conflictResolutionIdentifier(
        conflictAudioUrl: String?,
        lookedUpAudioUrl: String?,
        episodeGuid: String
    ) -> String {
        if let url = conflictAudioUrl, !url.isEmpty { return url }
        if let url = lookedUpAudioUrl, !url.isEmpty { return url }
        return episodeGuid
    }

    /// Resolve a sync conflict by updating the local model, actionMap, and server.
    ///
    /// **Local first, deliberately.** The write is the user's statement about their own
    /// device and has to land whether or not the network does — resolving offline works
    /// today and must keep working. The return value is what the sheet needs in order to
    /// tell "that row is gone, re-read the list" from "that failed, try again": the two
    /// arrive as the same 409 and mean opposite things about retrying.
    @discardableResult
    func resolveConflict(_ conflict: SyncConflict, chosenPosition: Int) async -> ConflictResolveOutcome {
        // 1. Update local Episode.listenedSeconds
        updateEpisodeProgressByGuid(episodeGuid: conflict.episodeGuid, position: chosenPosition)

        // Recover whatever the conflict record didn't carry from the local library.
        let meta = lookupEpisodeMetadata(
            guid: conflict.episodeGuid,
            audioUrlFallback: conflict.audioUrl
        )
        let episodeUrl = Self.conflictResolutionIdentifier(
            conflictAudioUrl: conflict.audioUrl,
            lookedUpAudioUrl: meta.audioUrl,
            episodeGuid: conflict.episodeGuid
        )
        let podcastUrl = conflict.podcastUrl ?? meta.podcastUrl
        // nil, never `chosenPosition`. A duration equal to the position satisfies the
        // server's `position >= duration` auto-complete, so the old fallback turned
        // "we don't know how long this is" into "the user finished it".
        let totalDuration = conflict.totalDuration ?? meta.totalDuration

        // 2. Build an EpisodeAction with the resolved position
        let action = EpisodeAction(
            podcast: podcastUrl ?? "",
            episode: episodeUrl,
            guid: conflict.episodeGuid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: chosenPosition,
            started: 0,
            total: totalDuration,
            device: deviceId
        )

        // 3. Update actionMap so next sync won't re-detect this conflict
        actionMap[conflict.episodeGuid] = action
        persistActionMap()

        // 4. Clear conflict count since user resolved it
        clearConflictCount(for: conflict.episodeGuid)

        // 5. Upload to server
        guard let client = syncClient else { return .landed }
        do {
            _ = try await client.uploadEpisodeActions([action])
            logger.info("Uploaded conflict resolution for \(conflict.episodeGuid) at position \(chosenPosition)")
        } catch {
            logger.error("Failed to upload conflict resolution: \(error.localizedDescription)")
        }

        // 6. Resolve authoritatively (per the sync contract). Step 5 is a *report*: it goes
        //    through the merge, which may refuse a backwards resolution. This is the write
        //    that decides. It lands second and wins, and it runs whether or not the server
        //    recorded the conflict — the explicit-position shape needs no stored row, so a
        //    locally-detected conflict resolves the same way.
        guard let proClient = client as? YourPodsProClient else { return .landed }
        do {
            try await proClient.resolveConflict(
                episodeUrl: episodeUrl,
                podcastUrl: podcastUrl,
                position: chosenPosition,
                duration: totalDuration
            )
            logger.info("Resolved conflict for \(conflict.episodeGuid) authoritatively at \(chosenPosition)")
            return .landed
        } catch YourPodsProError.conflictStale {
            // The row was real a moment ago and describes state that has since moved on,
            // so the server pruned it rather than writing its snapshot over live values.
            // Retrying re-sends the same dead row; the answer is to re-read the list.
            logger.info("Conflict for \(conflict.episodeGuid) is stale — refreshing rather than retrying")
            return .stale
        } catch {
            logger.error("Failed to resolve conflict for \(conflict.episodeGuid): \(error.localizedDescription)")
            return .failed
        }
    }
    
    /// Update episode listened position by GUID (for conflict resolution).
    private func updateEpisodeProgressByGuid(episodeGuid: String, position: Int) {
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }) {
                episode.setListenedSecondsIfChanged(position)
                if storeHealthCheck() {
                    modelContext.safeSave()
                }
                return
            }
        }
    }
    
    // MARK: - Device Position Lookup
    
    /// Look up the actual device playback position from the Episode model.
    ///
    /// The actionMap's position may contain a server-originated value from a
    /// previous sync cycle (e.g., a web player position that was merged in).
    /// Using it as `localPosition` in a conflict would mislead the user — the
    /// "Device" label would show a server position instead of what they actually
    /// heard on this device.
    ///
    /// Falls back to `fallback` (the actionMap value) when no matching Episode
    /// is found in SwiftData (e.g., queue-only episodes).
    private func lookupDevicePosition(guid: String, audioUrlFallback: String? = nil, fallback: Int) -> Int {
        let guidLower = guid.lowercased()
        
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == guid }) {
                return episode.listenedSeconds
            }
            if let episode = podcast.episodes.first(where: { $0.guid.lowercased() == guidLower }) {
                return episode.listenedSeconds
            }
            if let episode = podcast.episodes.first(where: { $0.audioUrl == guid }) {
                return episode.listenedSeconds
            }
            if let fallbackUrl = audioUrlFallback, fallbackUrl != guid,
               let episode = podcast.episodes.first(where: { $0.audioUrl == fallbackUrl }) {
                return episode.listenedSeconds
            }
        }
        
        return fallback
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
        // Resolve which profile's state we're loading into memory (drives scoped paths).
        loadedProfileId = activeProfileId ?? "global"

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
        
        // 2. Load the resident profile's persisted map from disk.
        loadActionMapFromDisk()
    }

    /// Load the action map from the profile-scoped file (with one-time legacy migration
    /// and a `.bak` fallback). Uses the already-resolved `loadedProfileId` — it does NOT
    /// re-read the provider, so `switchProfile` can target a profile the provider hasn't
    /// caught up to yet.
    private func loadActionMapFromDisk() {
        // One-time migration: a named profile adopts the pre-scoping global file.
        migrateLegacyGlobalFileIfNeeded(
            legacy: Self.actionMapFileURL, scoped: currentActionMapFileURL, label: "action map")

        let fileURL = currentActionMapFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            self.actionMap = try JSONDecoder().decode([String: EpisodeAction].self, from: data)
            logger.info("Loaded \(self.actionMap.count) persisted episode actions from file")
        } catch {
            logger.error("Failed to load action map from file: \(error.localizedDescription)")
            // Fallback: try .bak file
            let bakURL = fileURL.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: bakURL.path) {
                do {
                    let bakData = try Data(contentsOf: bakURL)
                    self.actionMap = try JSONDecoder().decode([String: EpisodeAction].self, from: bakData)
                    logger.warning("Recovered \(self.actionMap.count) persisted episode actions from .bak file")
                } catch {
                    logger.error("Failed to recover action map from .bak: \(error.localizedDescription)")
                }
            }
        }
    }

    /// One-time migration: when a named profile has no scoped file yet but the legacy
    /// pre-scoping global file exists, adopt it (move the file and its `.bak`). Other
    /// profiles re-pull from `since=0`. No-op for the "global" profile (scoped == legacy).
    private func migrateLegacyGlobalFileIfNeeded(legacy: URL, scoped: URL, label: String) {
        guard scoped != legacy else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: scoped.path), fm.fileExists(atPath: legacy.path) else { return }
        do {
            try fm.createDirectory(at: scoped.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: scoped)
            let legacyBak = legacy.appendingPathExtension("bak")
            if fm.fileExists(atPath: legacyBak.path) {
                try? fm.moveItem(at: legacyBak, to: scoped.appendingPathExtension("bak"))
            }
            logger.info("Migrated legacy global \(label) to profile-scoped file for \(self.effectiveProfileId)")
        } catch {
            logger.error("Failed to migrate legacy global \(label): \(error.localizedDescription)")
        }
    }

    /// Persist the resident profile's state, swap in-memory to another profile, and load
    /// the target profile's persisted state. Prevents one profile's positions from
    /// leaking into another's conflict detection (and onward to its server).
    func switchProfile(to profileId: String?) {
        let newId = profileId ?? "global"
        guard newId != effectiveProfileId else { return }
        // Persist the OUTGOING profile's resident state to its scoped files.
        persistActionMap()
        persistCompletionOutbox()
        // Clear in-memory state so the incoming profile starts clean.
        actionMap.removeAll()
        conflictCounts.removeAll()
        completionOutbox.removeAll()
        // Switch the resident profile and load its persisted state from disk.
        loadedProfileId = newId
        loadActionMapFromDisk()
        loadCompletionOutbox()
        logger.info("Switched episode-action state to profile \(newId)")
    }

    /// Delete a profile's scoped action map + completion outbox files. If the profile is
    /// the resident one, also clear the in-memory state so nothing lingers for re-push.
    func deleteProfileFiles(forProfileId profileId: String) {
        let fm = FileManager.default
        let am = Self.actionMapFileURL(forProfile: profileId)
        try? fm.removeItem(at: am)
        try? fm.removeItem(at: am.appendingPathExtension("bak"))
        try? fm.removeItem(at: Self.completionOutboxFileURL(forProfile: profileId))
        if profileId == effectiveProfileId {
            actionMap.removeAll()
            conflictCounts.removeAll()
            completionOutbox.removeAll()
        }
        logger.info("Deleted episode-action files for profile \(profileId)")
    }

    /// Persist action map to a dedicated JSON file.
    /// Uses atomic writes to prevent partial-write corruption.
    func persistActionMap() {
        actionMapPersistCount += 1
        do {
            let data = try JSONEncoder().encode(actionMap)
            let fileURL = currentActionMapFileURL
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Create .bak from existing file before overwriting
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let bakURL = fileURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: bakURL)
                try? FileManager.default.copyItem(at: fileURL, to: bakURL)
            }
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
    ///
    /// Note: This method does NOT save. Callers are responsible for calling
    /// `modelContext.safeSave()` after mutations. For batch operations, use
    /// `applyHiddenChanges(_:)` which handles health check + save.
    /// Find the episode a side-channel change names.
    ///
    /// `parseRecentResponse` keys the completed / uncompleted / hidden channels as
    /// `episodeGuid ?? episodeUrl`, so the key is an **audio URL** for any row the server
    /// holds without a GUID — which is what web and the gPodder bridge write. Matching
    /// those against local GUIDs never succeeds, so those changes were dropped 100% of the
    /// time while the server counted them delivered.
    ///
    /// The ladder is the one `lookupDevicePosition` already uses, in the same order:
    ///
    /// 1. exact GUID — the common case, and the only one before this;
    /// 2. case-folded GUID — RFC 4122 says UUIDs are case-insensitive and some servers
    ///    return them in a different case than the feed wrote them;
    /// 3. audio URL — the documented fallback key.
    ///
    /// Exact and whole-value at every step. Widening matching is not the same as guessing:
    /// a key that names nothing must still change nothing.
    private func episodeForSideChannelKey(_ key: String) -> Episode? {
        let folded = key.lowercased()
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == key }) { return episode }
        }
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid.lowercased() == folded }) { return episode }
        }
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.audioUrl == key }) { return episode }
        }
        return nil
    }

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
        episodeForSideChannelKey(guid)?.isPlayed = hidden
    }
    
    /// Batch-apply hidden state changes with a single health check and save.
    ///
    /// Replaces the per-change setHidden + safeSave loop in ProSyncOrchestrator
    /// to prevent N rawWriteProbe opens during sync.
    func applyHiddenChanges(_ changes: [HiddenStateChange]) {
        guard !changes.isEmpty else { return }

        // Apply all in-memory mutations first
        for change in changes {
            setHidden(guid: change.guid, hidden: change.hidden)
        }

        // Cancellation gate: a cancelled sync must not open the write probe
        // or save (suspension-kill windows). The in-memory hidden state above
        // is persisted to UserDefaults below and re-saved on the next sync.
        if Task.isCancelled {
            logger.info("applyHiddenChanges cancelled — skipping probe + save (\(changes.count) changes kept in memory)")
        } else if storeHealthCheck() {
            // Single health check + save for the entire batch
            modelContext.safeSave()
        }

        persistHiddenGuids()
    }

    /// Batch-apply completed (finished) state changes with a single health check
    /// and save. Mirrors `applyHiddenChanges`: marks each episode `isPlayed = true`
    /// directly (no outbound `EpisodeAction`, so no echo back to the server).
    ///
    /// This honors the server's authoritative `completed` flag for cross-device
    /// completion, so a finished-on-web episode is reliably cleared from the iOS
    /// now-playing mini player instead of depending on the position heuristic.
    func applyCompletedChanges(_ changes: [CompletedStateChange]) {
        guard !changes.isEmpty else { return }

        // Apply all in-memory mutations first: mark each episode played.
        // Direct mutation (like `setHidden`) — no outbound `EpisodeAction`, so
        // this never echoes back to the server (the server is the source of the
        // completion we're applying).
        for change in changes {
            episodeForSideChannelKey(change.guid)?.markPlayedIfNeeded()
        }

        // Cancellation gate: a cancelled sync must not open the write probe or
        // save (suspension-kill windows). The in-memory mutations above are
        // re-saved on the next sync if this one is cancelled.
        if Task.isCancelled {
            logger.info("applyCompletedChanges cancelled — skipping probe + save (\(changes.count) changes kept in memory)")
        } else if storeHealthCheck() {
            // Single health check + save for the entire batch
            modelContext.safeSave()
        }
    }

    /// Apply authoritative server un-completes: mark each episode unplayed and reset
    /// its listen position so a re-add/relisten started on another device clears the
    /// played state here.
    ///
    /// Safety: Applying server `completed:false` is safe because the server NEVER
    /// spontaneously un-completes. Position pushes merge `completed` via GREATEST (stays
    /// true), and the only ways a stored `completed` flips true→false are (a) an explicit
    /// un-complete or (b) a `now_playing:true` push (another device started relistening) —
    /// both deliberate user intent, both bump `updated_at` so they appear in the delta.
    /// So `completed:false` in the delta is always authoritative.
    ///
    /// Guard: skips any guid present in the completion outbox (a locally just-finished
    /// episode whose `completed:true` push hasn't landed yet) so we don't revert it
    /// mid-cycle. The outbox is drained BEFORE this method is called by the orchestrator,
    /// so the pending-guid set is correct at call time.
    func applyUncompletedChanges(_ changes: [UncompletedStateChange]) {
        guard !changes.isEmpty else { return }

        let pending = pendingCompletionGuids()   // completion outbox
        for change in changes where !pending.contains(change.guid) {
            episodeForSideChannelKey(change.guid)?.markUnplayedIfNeeded()
        }

        // Cancellation gate: a cancelled sync must not open the write probe or
        // save (suspension-kill windows). The in-memory mutations above are
        // re-applied on the next sync if this one is cancelled.
        if Task.isCancelled {
            logger.info("applyUncompletedChanges cancelled — skipping save; mutations re-applied next sync (\(changes.count) change(s))")
        } else if storeHealthCheck() {
            modelContext.safeSave()
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

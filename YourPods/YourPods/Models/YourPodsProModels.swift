// ─── YourPods Pro ────────────────────────────────────────────────────────
// These models are used EXCLUSIVELY for YourPods Pro sync features
// (queue sync, settings sync, playback handoff). They are NOT required
// to build or run the app — Vault Mode and gPodder sync work without them.
//
// For up-to-date information on the app source and YourPods Pro
// spec/source, visit: https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Queue

/// Server response for GET /api/yourpods/queue
struct ProQueueResponse: Codable {
    let queue: [ProQueueItem]
    let updatedAt: String?
    let droppedItems: [ProQueueDroppedItem]?
    /// Server's current queue version. Absent/nil on a server that
    /// predates the version token — clients then fall back to no-CAS behavior.
    let version: Int64?
}

/// Information about a queue item that was explicitly dropped by the server
struct ProQueueDroppedItem: Codable {
    let episodeUrl: String
    let title: String?
    let guid: String?
    let reason: String
}

/// A single item in the YourPods Pro queue.
struct ProQueueItem: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let sortOrder: Int
    let title: String?
    let podcastTitle: String?
    let artworkUrl: String?
    let durationSec: Double?
    let positionSec: Double?
    let addedAt: String?
    
    /// Custom decoding to handle server key variations:
    /// - Server sends `artUrl` / `art_url` → model uses `artworkUrl`
    /// - Server sends `duration` → model uses `durationSec`
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexKeys.self)
        podcastUrl = try container.decode(String.self, forKey: .podcastUrl)
        episodeUrl = try container.decode(String.self, forKey: .episodeUrl)
        episodeGuid = try container.decodeIfPresent(String.self, forKey: .episodeGuid)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        podcastTitle = try container.decodeIfPresent(String.self, forKey: .podcastTitle)
        addedAt = try container.decodeIfPresent(String.self, forKey: .addedAt)
        
        // artworkUrl: try artworkUrl first, fall back to artUrl
        artworkUrl = try container.decodeIfPresent(String.self, forKey: .artworkUrl)
            ?? container.decodeIfPresent(String.self, forKey: .artUrl)
        
        // durationSec: try durationSec first, fall back to duration
        durationSec = try container.decodeIfPresent(Double.self, forKey: .durationSec)
            ?? container.decodeIfPresent(Double.self, forKey: .duration)
        
        // positionSec: try positionSec first, fall back to position
        positionSec = try container.decodeIfPresent(Double.self, forKey: .positionSec)
            ?? container.decodeIfPresent(Double.self, forKey: .position)
    }
    
    private enum FlexKeys: String, CodingKey {
        case podcastUrl, episodeUrl, episodeGuid, sortOrder
        case title, podcastTitle, addedAt
        case artworkUrl, artUrl     // server sends artUrl
        case durationSec, duration  // server sends duration
        case positionSec, position  // server may send position
    }
}

/// Request body for POST /api/yourpods/queue/sync
struct ProQueueSyncRequest: Codable {
    let items: [ProQueueSyncItem]
    /// Optimistic-concurrency base version. When non-nil, the server
    /// applies the replace only if it matches the current queue version, else 409.
    /// Synthesized `encode` uses `encodeIfPresent`, so `nil` is omitted entirely —
    /// a legacy/no-token push is byte-identical to today.
    let baseVersion: Int64?

    init(items: [ProQueueSyncItem], baseVersion: Int64? = nil) {
        self.items = items
        self.baseVersion = baseVersion
    }
}

/// A queue item for sync (upload) — includes metadata so the server/web has display info.
struct ProQueueSyncItem: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let sortOrder: Int
    let positionSec: Double?
    let title: String?
    let podcastTitle: String?
    let artworkUrl: String?
    let durationSec: Double?
}

/// Request body for POST /api/yourpods/queue/add
struct ProQueueAddRequest: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let title: String?
    let podcastTitle: String?
}

// MARK: - Playback

/// Server response for GET /api/yourpods/playback/current (wrapped in `{ "state": { ... } }`)
struct ProPlaybackState: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let positionSec: Double
    let durationSec: Double?
    let title: String?
    let podcastTitle: String?
    let artUrl: String?        // server field name (not artworkUrl)
    let updatedAt: String?
    let nowPlaying: Bool?
    let completed: Bool?
    let hidden: Bool?          // ← newer server field — episode is hidden from feed
}

extension ProPlaybackState {
    /// `updatedAt` parsed as a `Date`, or nil when absent/unparseable.
    ///
    /// The server emits RFC3339 with and without fractional seconds depending on the
    /// column, and `ISO8601DateFormatter` rejects the form it was not configured for,
    /// so both are tried. Note this is the server's **arrival** time — bumped
    /// unconditionally by `UpsertPlaybackState`, even when the merge rejects the
    /// incoming position — not the originating device's event time. Callers using it
    /// for event-time ordering are working with an upper bound; see the apply-side
    /// rule in the sync contract.
    var updatedAtDate: Date? {
        guard let updatedAt else { return nil }
        return Self.fractionalISO8601.date(from: updatedAt)
            ?? Self.plainISO8601.date(from: updatedAt)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISO8601 = ISO8601DateFormatter()
}

/// Request body for POST /api/yourpods/playback/sync
struct ProPlaybackSyncRequest: Codable {
    let podcastUrl: String
    let episodeUrl: String
    let episodeGuid: String?
    let positionSec: Double
    let durationSec: Double?
    let nowPlaying: Bool?
    /// Marks the episode as finished. Server auto-clears `nowPlaying` when set.
    /// `GET /playback/current` excludes completed episodes.
    let completed: Bool?
    /// Device identifier for cross-device now-playing handoff.
    /// Lets the server attribute playback state to a specific device.
    let deviceId: String?
    /// Client event time: the wall-clock instant this device's playback state last
    /// changed. Encoded as an RFC3339 / ISO8601 string. The server
    /// honors the newest event time, so a stale offline device cannot clobber newer
    /// cross-device state. Omitted when nil (legacy arrival-time behavior).
    let clientUpdatedAt: Date?
    /// CAS baseline — the `version` this client last **agreed** with the server on
    /// (per the sync contract). Tri-state, and it has to stay tri-state on the wire:
    ///
    /// - `nil`  → key omitted → legacy last-write-wins (gPodder bridge, older releases)
    /// - `0`    → "I believe no row exists" — conflicts against any existing row
    /// - `N`    → "I last agreed at N" — the write lands only if the row still carries N
    ///
    /// `0` and omitted are read as different things by the server (`*int64`), so
    /// collapsing them client-side would turn every legacy push into a fresh-install
    /// claim. `encodeIfPresent` preserves the distinction; a plain `encode` would not.
    let baseVersion: Int64?

    init(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool? = nil,
        completed: Bool? = nil,
        deviceId: String? = nil,
        clientUpdatedAt: Date? = nil,
        baseVersion: Int64? = nil
    ) {
        self.podcastUrl = podcastUrl
        self.episodeUrl = episodeUrl
        self.episodeGuid = episodeGuid
        self.positionSec = positionSec
        self.durationSec = durationSec
        self.nowPlaying = nowPlaying
        self.completed = completed
        self.deviceId = deviceId
        self.clientUpdatedAt = clientUpdatedAt
        self.baseVersion = baseVersion
    }

    /// Custom encoding that omits nil fields entirely (instead of sending `"key": null`).
    /// Some servers reject or crash on unexpected null fields.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(podcastUrl, forKey: .podcastUrl)
        try container.encode(episodeUrl, forKey: .episodeUrl)
        try container.encodeIfPresent(episodeGuid, forKey: .episodeGuid)
        try container.encode(positionSec, forKey: .positionSec)
        try container.encodeIfPresent(durationSec, forKey: .durationSec)
        try container.encodeIfPresent(nowPlaying, forKey: .nowPlaying)
        try container.encodeIfPresent(completed, forKey: .completed)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        // Encode the client event time as an RFC3339 / ISO8601 string
        // (with fractional seconds), omitted entirely when nil.
        if let clientUpdatedAt {
            try container.encode(Self.iso8601.string(from: clientUpdatedAt), forKey: .clientUpdatedAt)
        }
        // Per the sync contract: `encodeIfPresent`, never `encode(baseVersion ?? 0)`. Absent means legacy
        // last-write-wins; 0 is a positive claim that no row exists. A push that means
        // the former and says the latter conflicts on every episode it owns.
        try container.encodeIfPresent(baseVersion, forKey: .baseVersion)
    }

    /// ISO8601 formatter for the client event time. Fractional seconds give the
    /// server sub-second ordering precision between near-simultaneous device writes.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Response body for POST /api/yourpods/playback/sync (per the sync contract).
///
/// ```json
/// {"message":"synced","count":49,
///  "accepted":[{"episodeUrl":"…","version":42}],
///  "conflicts":[{"episodeUrl":"…","server":{"positionSec":2167.4,"completed":true,
///                                           "nowPlaying":false,"version":12}}]}
/// ```
///
/// Always **HTTP 200**, including an all-conflicts batch. Playback is per-episode partial
/// success — 50 items with one stale baseline commits 49 and reports one conflict — so a
/// conflict is an honest answer with work attached, not a failed request. (Queue CAS
/// answers 409 because it replaces the queue atomically. Different shape, different code.)
struct ProPlaybackSyncResponse: Codable, Equatable {
    /// Items **accepted** — `len(accepted)` server-side, not the size of the batch sent.
    /// A partial batch answers 200 with a short count; an all-conflict batch answers 200
    /// with `0`. Neither is an error, so this is a statistic and never a success test.
    let count: Int
    let accepted: [Accepted]
    let conflicts: [Conflict]

    struct Accepted: Codable, Equatable {
        /// Echoed byte-for-byte, as the sync contract requires. The client has no other key to map
        /// an ack back to the episode it pushed, so any normalization here — percent
        /// decoding, host case folding, a dropped query — leaves the row dirty forever.
        let episodeUrl: String
        /// The version the row now carries. `syncedVersion` advances to this **on the
        /// ack** — never on receipt of a conflict payload, which would claim agreement on
        /// a value the server does not hold.
        let version: Int64
        /// The `completed` flag the ROW ended up with, which is not always the one this
        /// push asserted (see the sync contract). A completion is pushed versionless by
        /// design — it carries a decision the user already made and must land rather than
        /// conflict — so it goes through the server's merge, where a strictly-older event
        /// time keeps the stored flag. `positionSec` cannot stand in for this: the two
        /// columns have separate predicates, and a completion for an episode with no known
        /// duration pushes position 0, which never lands.
        ///
        /// Optional because the deployed server predates the field. `nil` means "no
        /// opinion" and callers fall back to what they asserted — the behaviour before the
        /// field existed. It is NOT `false`: decoding absent as `false` would tell every
        /// client its completions are being discarded.
        let completed: Bool?

        init(episodeUrl: String, version: Int64, completed: Bool? = nil) {
            self.episodeUrl = episodeUrl
            self.version = version
            self.completed = completed
        }
    }

    struct Conflict: Codable, Equatable {
        let episodeUrl: String
        let server: ServerState

        /// The server's current state — the right-hand side of row 4 of the sync contract's table.
        struct ServerState: Codable, Equatable {
            let positionSec: Double
            let completed: Bool
            /// Required, not decorative: ladder steps (b) and (c) cannot be evaluated
            /// without it, and a dropped `false` is indistinguishable from a dropped `true`.
            let nowPlaying: Bool
            let version: Int64

            /// Bridge into `PlaybackReconciler`'s input type.
            var asPlaybackConflict: ServerPlaybackConflict {
                ServerPlaybackConflict(
                    positionSec: positionSec,
                    completed: completed,
                    nowPlaying: nowPlaying,
                    version: version
                )
            }
        }
    }

    /// Tolerant by design. An older deployment answers
    /// `{"message":"synced","count":1}` with no arrays at all; throwing there would break
    /// every push against an un-migrated server, turning a rollout ordering problem into
    /// total playback-sync loss. Absent arrays mean "this server has nothing to say about
    /// CAS", which is exactly an empty list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        accepted = try c.decodeIfPresent([Accepted].self, forKey: .accepted) ?? []
        conflicts = try c.decodeIfPresent([Conflict].self, forKey: .conflicts) ?? []
    }

    init(count: Int, accepted: [Accepted], conflicts: [Conflict]) {
        self.count = count
        self.accepted = accepted
        self.conflicts = conflicts
    }
}

// MARK: - Subscriptions

/// Request body for POST /api/yourpods/subscriptions/add
struct ProSubscriptionAddRequest: Codable {
    let podcastUrl: String
}

/// Request body for POST /api/yourpods/subscriptions/remove
struct ProSubscriptionRemoveRequest: Codable {
    let podcastUrl: String
}

// MARK: - Settings

// v1 `ProGlobalSettings` removed — global settings use v2 `ProProfileSettings`.

/// Server response for GET /api/yourpods/settings/profile (v2)
struct ProProfileSettings: Codable {
    let profileName: String
    let payload: [String: AnyCodableValue]?
    let updatedAt: String?

    /// Resolved payload dict — always non-optional for convenience.
    var resolvedPayload: [String: AnyCodableValue] { payload ?? [:] }
}

/// Entry in GET /api/yourpods/settings/profiles list
struct ProProfileInfo: Codable {
    let profileName: String
    let updatedAt: String?
}

/// Per-podcast settings from GET /api/yourpods/settings/profile/podcasts (v2)
struct ProPodcastSetting: Codable {
    let podcastUrl: String
    let payload: [String: AnyCodableValue]?
    // Fallback key — v2 responses use `payload`, but legacy responses may use `settings`.
    let settings: [String: AnyCodableValue]?
    let updatedAt: String?

    /// Resolved payload: prefer `payload`, fall back to `settings` for legacy responses.
    var resolvedPayload: [String: AnyCodableValue] {
        payload ?? settings ?? [:]
    }
}

// v1 `ProEpisodeSetting` removed — no v2 equivalent exists.
// Episode-level overrides (per-episode played/starred state) are handled
// by episode actions and queue sync, not a separate settings endpoint.

// MARK: - Hidden Episodes

/// Request body for POST /api/yourpods/episodes/hide.
/// Accepts single object or array of these.
struct ProHideEpisodeRequest: Codable {
    let episodeUrl: String
    let podcastUrl: String
}

/// Response from POST /api/yourpods/episodes/hide or /unhide.
struct ProHideResponse: Codable {
    let message: String
    let count: Int?
}

// MARK: - Sync Conflicts

/// A single position conflict from GET /api/yourpods/sync-conflicts.
///
/// Mirrors the position-conflict shape in the server's conflict handler field for field.
/// The previous shape could not decode a real response at all — it required an `id`
/// the server never sends, spelled the position `devicePosition` where the server
/// says `localPosition`, and typed the positions as `Int` where the server sends
/// floats. Any one of those throws, and the fetch site swallows the throw into a log
/// line, so the only symptom was a conflict sheet that never appeared.
///
/// Every field except `episodeUrl` is optional: `enrichSyncConflict` backfills the
/// metadata from RSS on the GET, so a row read before that fetch lands carries none.
struct ProServerConflict: Codable, Sendable {
    let episodeUrl: String
    let podcastUrl: String?
    /// Position asserted by `deviceId`. The server's key is `localPosition`; "local"
    /// means the device that authored the row, NOT necessarily the one reading it.
    let localPosition: Double?
    let serverPosition: Double?
    let duration: Double?
    /// Which device asserted `localPosition`. Nil for rows written by
    /// the gPodder bridge, where the local side is YourPods itself rather than a device.
    /// Compare against this device's own id before labelling a position "This Device".
    let deviceId: String?
    /// Whether the server holds this episode as finished.
    ///
    /// **Optional because the deployed server predates it.** A completed row stores
    /// `position_sec = duration`, so without this the sheet shows `1:00:00` and asks the
    /// user to compare a position against a number that is not one. Absent means "not
    /// known to be played" — never `true`.
    let serverCompleted: Bool?
    let occurrenceCount: Int?
    let updatedAt: String?
    let episodeTitle: String?
    let podcastTitle: String?
    let artUrl: String?
}

/// A single feed-URL rewrite from GET /api/yourpods/sync-conflicts.
///
/// A DIFFERENT wire shape from `ProServerConflict`, which is why it needs its own type:
/// the server strips the `url_rewrite:` row prefix itself and emits `{oldUrl, newUrl}`.
/// Decoding this array as `ProServerConflict` required an `episodeUrl` that is never
/// present, so a single rewrite made the whole response fail to decode and took the
/// position conflicts down with it.
struct ProServerURLRewrite: Codable, Sendable {
    let oldUrl: String
    let newUrl: String
    let occurrenceCount: Int?
    let updatedAt: String?
}

/// Response from GET /api/yourpods/sync-conflicts.
struct ProSyncConflictsResponse: Codable, Sendable {
    let conflicts: [ProServerConflict]
    let urlRewrites: [ProServerURLRewrite]
    let total: Int
}

/// Request body for POST /api/yourpods/sync-conflicts/resolve — the sync contract's
/// authoritative (explicit-position) shape.
///
/// The earlier shape was `{episodeUrl, resolution}`: a pointer to a number the server
/// had stored, rather than the number itself. It failed silently in both directions —
/// no stored row meant a 404 and no write, and a position the server could not read
/// decoded to 0 and erased the episode. Carrying the position removes the indirection,
/// so resolution works whether or not the server ever recorded the conflict.
///
/// `duration` is the server's only evidence that the position is short of the end, and
/// therefore the only thing that can clear a stale `completed`. Leave it nil when
/// unknown — never 0, which is not "missing" to a `position >= duration` comparison but
/// a duration every position exceeds.
struct ProResolveConflictRequest: Codable {
    let episodeUrl: String
    let podcastUrl: String?
    let position: Int
    let duration: Int?
}

/// Request body for POST /api/yourpods/sync-conflicts/resolve-all.
struct ProResolveAllConflictsRequest: Codable {
    let resolution: String  // "local" | "server"
}

/// Request body for POST /api/yourpods/sync-conflicts/resolve-url-rewrite.
struct ProResolveUrlRewriteRequest: Codable {
    let oldUrl: String
    let newUrl: String
    /// **Required, and it is not a formality.** The handler reads `Accept bool json:"accept"`
    /// and renames the subscription only when it is true. Go decodes an absent bool to its
    /// zero value, so omitting this field is not "unspecified" — it is an explicit reject.
    /// iOS omitted it entirely, which meant every Accept the user ever tapped reached the
    /// server as a Reject: the local library renamed the feed, the server kept the old URL,
    /// and current server releases also record a permanent rejection that stops the prompt ever
    /// being offered again.
    let accept: Bool
}

/// Response from POST /api/yourpods/sync-conflicts/resolve-url-rewrite.
///
/// **Every field is optional by design.** The success signal for this endpoint is the HTTP
/// status — `performPOST` throws on anything non-2xx — so nothing in the body is load-bearing
/// and a decode failure must never be able to turn a successful rename into a reported one.
/// This is not hypothetical: iOS shipped a required `affected` that **no deployment has ever
/// returned**, so a fully successful resolve threw on decode and was logged as a failure.
/// Current server releases return `updated` (rows moved) plus a `counts` breakdown.
struct ProResolveUrlRewriteResponse: Codable {
    let message: String?
    /// Rows actually moved. Informational — `0` is a real, successful outcome meaning the
    /// rename matched nothing, and is worth surfacing rather than hiding behind a 200.
    let updated: Int?
}

/// Event types for POST /api/yourpods/stats/events
enum ProStatsEventType: String, Codable {
    case listen       = "listen"
    case skipManual   = "skip_manual"
    case skipAuto     = "skip_auto"
    case skipChapter  = "skip_chapter"
}

/// A single listening or skip event buffered locally and uploaded in batch.
struct ProStatsEvent: Codable {
    /// Client-generated UUID v4 for server-side deduplication.
    let id: String
    /// ISO 8601 timestamp when the event occurred.
    let timestamp: String
    let podcastUrl: String?
    let episodeUrl: String
    let episodeGuid: String?
    let eventType: ProStatsEventType
    /// Start position of the segment (seconds).
    let fromPosSec: Double
    /// End position of the segment (seconds).
    let toPosSec: Double
    /// Wall clock time spent (seconds); 0 for instant skip events.
    let durationSec: Double
    /// Content time covered at any playback speed (seconds).
    let contentSec: Double
    /// Playback speed at time of event.
    let speed: Double
    let deviceId: String
    
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    init(
        podcastUrl: String?,
        episodeUrl: String,
        episodeGuid: String?,
        eventType: ProStatsEventType,
        fromPosSec: Double,
        toPosSec: Double,
        durationSec: Double,
        contentSec: Double,
        speed: Double,
        deviceId: String
    ) {
        self.id = UUID().uuidString
        self.timestamp = Self.isoFormatter.string(from: Date())
        self.podcastUrl = podcastUrl
        self.episodeUrl = episodeUrl
        self.episodeGuid = episodeGuid
        self.eventType = eventType
        self.fromPosSec = fromPosSec
        self.toPosSec = toPosSec
        self.durationSec = durationSec
        self.contentSec = contentSec
        self.speed = speed
        self.deviceId = deviceId
    }
    
    /// Custom encoding that omits nil fields entirely.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(podcastUrl, forKey: .podcastUrl)
        try container.encode(episodeUrl, forKey: .episodeUrl)
        try container.encodeIfPresent(episodeGuid, forKey: .episodeGuid)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(fromPosSec, forKey: .fromPosSec)
        try container.encode(toPosSec, forKey: .toPosSec)
        try container.encode(durationSec, forKey: .durationSec)
        try container.encode(contentSec, forKey: .contentSec)
        try container.encode(speed, forKey: .speed)
        try container.encode(deviceId, forKey: .deviceId)
    }
}

/// Top podcast entry in the stats response.
struct ProTopPodcastStat: Codable {
    let podcastUrl: String
    let listenTimeSec: Double
    let episodeCount: Int
}

/// Aggregated listening stats from GET /api/yourpods/stats.
///
/// Basic fields (`totalListenTimeSec`, `uniqueEpisodes`, `uniquePodcasts`)
/// are always present for both Sync and Pro tiers. Pro-only fields
/// (skip breakdowns, content time) are optional and absent in Sync-tier responses.
struct ProStats: Codable {
    let totalListenTimeSec: Double
    let totalContentTimeSec: Double?        // Pro only
    let totalSkippedSec: Double?            // Pro only
    let manualSkipsSec: Double?             // Pro only
    let autoSkipsSec: Double?               // Pro only
    let chapterSkipsSec: Double?            // Pro only
    let manualSkipCount: Int?               // Pro only
    let autoSkipCount: Int?                 // Pro only
    let chapterSkipCount: Int?              // Pro only
    let uniqueEpisodes: Int
    let uniquePodcasts: Int
}

/// A single day's aggregated listening data from the `dailyTrend` array (Pro only).
struct DailyTrendEntry: Codable, Identifiable {
    let date: String            // "2026-05-05"
    let listenTimeSec: Double
    let episodeCount: Int

    var id: String { date }
}

/// Full response for GET /api/yourpods/stats.
///
/// The `tier` field determines which UI to render:
/// - `"sync"` → basic stat cards (listen time, episodes, podcasts, streak)
/// - `"pro"` → full dashboard (+ skip breakdown, daily trend chart, top podcasts)
struct ProStatsResponse: Codable {
    let tier: String                        // "sync" or "pro"
    let since: String?
    let streak: Int?
    let stats: ProStats
    let topPodcasts: [ProTopPodcastStat]?   // nil for sync tier
    let dailyTrend: [DailyTrendEntry]?      // nil for sync tier
}

// MARK: - Session

/// Server response for POST /auth/session
struct ProSessionResponse: Codable {
    let user: ProUser
    let appPassword: ProAppPassword?
    let isNewUser: Bool?
    /// Account tier from the server: "pending", "sync", or "pro".
    /// Optional for backward compatibility with older servers that omit it.
    let accountTier: String?
    /// The durable early-adopter flag. Drives *pricing* eligibility, NOT entitlement —
    /// a lapsed early adopter keeps this flag but is no longer Pro. Never derive Pro
    /// from it locally (see `isProEntitled`).
    let isEarlyAdopter: Bool?
    /// The server's authoritative Pro verdict (POST /auth/session `isPro`). The server
    /// is the single source of truth; prefer this over any local re-derivation.
    /// Optional so a legacy server that omits it still decodes.
    let isPro: Bool?
    /// Whether to surface the `early_adopter` offering rather than the `default` one.
    /// A server pricing-window decision (`is_early_adopter` OR within the launch window)
    /// so web and app agree on who gets the early price. The prices themselves live in
    /// App Store Connect and reach the app through RevenueCat — never hardcoded here.
    /// Optional on legacy servers.
    let earlyAdopterPricingEligible: Bool?

    /// Whether this account is entitled to Pro features.
    /// Honors the server's authoritative `isPro` when present; otherwise falls back to
    /// the tier alone. The durable `isEarlyAdopter` flag is deliberately NOT consulted —
    /// pricing eligibility (`earlyAdopterPricingEligible`) is a separate concern, and
    /// treating the flag as entitlement leaves lapsed early adopters permanently "Pro".
    var isProEntitled: Bool {
        isPro ?? (accountTier == "pro")
    }
}

/// User info from session response.
struct ProUser: Codable {
    let id: String
    let email: String
    /// Firebase Auth UID — RevenueCat's `appUserID`. Ties a web purchase and an
    /// app (App Store) purchase to the same RevenueCat customer and server account.
    /// Optional so a legacy server response without it still decodes.
    let firebaseUid: String?
}

/// App password from session response (for legacy gPodder compat).
struct ProAppPassword: Codable {
    let id: String
    let password: String
    let server: String
    let username: String
}

// MARK: - Groups

/// A single podcast library group (folder).
/// UUIDs are client-generated and stable across renames and reorders.
struct ProGroup: Codable, Equatable {
    let id: String
    var name: String
    var sortOrder: Int
    var iconName: String?
    var colorHex: String?
}

/// A podcast→group assignment.
struct ProGroupAssignment: Codable, Equatable {
    let podcastUrl: String
    let groupId: String?
}

/// Server response for GET /api/yourpods/groups
struct ProGroupsResponse: Codable {
    let profileName: String
    let groups: [ProGroup]
    let timestamp: String?
}

/// Server response for GET /api/yourpods/groups/assignments
struct ProGroupAssignmentsResponse: Codable {
    let profileName: String
    let assignments: [ProGroupAssignment]
    let timestamp: String?
}

// MARK: - Migration (legacy)

/// Request body for POST /api/yourpods/migrate
struct ProMigrateRequest: Codable {
    let subscriptions: [String]
    let episodeActions: [ProMigrateAction]
}

/// Simplified episode action for migration upload.
struct ProMigrateAction: Codable {
    let podcast: String
    let episode: String
    let guid: String?
    let action: String
    let position: Int?
    let total: Int?
    let timestamp: Int?
}

/// Server response for POST /api/yourpods/migrate
struct ProMigrateResponse: Codable {
    let subscriptionsImported: Int
    let episodeActionsImported: Int
    let message: String?
}

// MARK: - Generic JSON Value

/// Type-erased Codable value for settings payloads that contain mixed types.
enum AnyCodableValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value type") }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Enriched 402 Response

/// Parsed body from a 402 Payment Required response.
///
/// Server returns this on Pro-gated **reads** for free-tier accounts.
/// Pro **writes** always succeed (data accumulates for upgrade).
struct PaymentRequiredInfo: Codable, Sendable, Equatable {
    /// The server action — e.g. "payment_required".
    let action: String?
    /// Account tier as reported by the server — e.g. "sync", "pro".
    let accountTier: String?
    /// URL to direct the user for upgrade.
    let upgradeUrl: String?
    /// Endpoints allowed at the current tier (everything else is gated).
    let allowedEndpoints: [String]?
}

// MARK: - Annotations (Notes) Sync

/// Request item for `POST /annotations/sync` — matches server push schema.
/// Server upserts by client UUID — safe to retry (idempotent).
struct SyncAnnotationItem: Codable, Sendable {
    let id: String
    let episodeUrl: String
    let podcastUrl: String
    var episodeGuid: String?
    var timestampSec: Double
    var noteText: String
    var chapterTitle: String?
    var chapterStartSec: Double?
    var transcriptText: String?
    var transcriptStartSec: Double?
    var transcriptEndSec: Double?
    var color: String?
    var tags: [String]
    var deleted: Bool
    var snapshot: AnnotationSnapshotInfo?
}

/// Episode metadata snapshot — sent on first annotation for an episode.
/// Server stores in `episode_snapshots` table (deduped by episodeUrl).
struct AnnotationSnapshotInfo: Codable, Sendable {
    let podcastTitle: String
    let episodeTitle: String
    var artUrl: String?
    var description: String?
    var durationSec: Double?
    var transcriptUrl: String?
}

/// Response from `POST /annotations/sync` AND `GET /annotations?since=`.
///
/// Shape differs slightly between endpoints:
/// - POST includes `synced`, `dropped`, and `syncedAt`.
/// - GET may omit `syncedAt` (and always omits `synced`/`dropped`).
/// All fields that may be absent are optional.
///
/// **POST response returns FULL state** (all user annotations), not delta-since.
/// The `syncedAt` cursor (when present) is for subsequent `GET ?since=` pulls.
struct AnnotationSyncResponse: Codable, Sendable {
    let synced: Int?
    let dropped: Int?
    let annotations: [AnnotationDeltaItem]
    let syncedAt: String?
}

/// A single item in the annotations delta array.
///
/// Two response shapes exist:
/// - **POST /annotations/sync**: body nested under `"annotation"` key.
/// - **GET /annotations**: body fields are flat at the item level.
///
/// The custom decoder tries the nested key first, then falls back to
/// decoding `AnnotationBody` directly from the same container.
struct AnnotationDeltaItem: Codable, Sendable {
    let id: String
    let deleted: Bool
    let updatedAt: String?
    let episodeUrl: String?
    let annotation: AnnotationBody?

    init(id: String, deleted: Bool, updatedAt: String?, episodeUrl: String?, annotation: AnnotationBody?) {
        self.id = id
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.episodeUrl = episodeUrl
        self.annotation = annotation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        episodeUrl = try c.decodeIfPresent(String.self, forKey: .episodeUrl)

        // POST nests body under "annotation"; GET puts fields flat
        if let nested = try c.decodeIfPresent(AnnotationBody.self, forKey: .annotation) {
            annotation = nested
        } else {
            // Try decoding AnnotationBody from the same level
            annotation = try? AnnotationBody(from: decoder)
        }
    }
}

/// Full annotation body (only present for live items, `nil` for tombstones).
struct AnnotationBody: Codable, Sendable {
    let id: String
    let timestampSec: Double
    let noteText: String
    var chapterTitle: String?
    var chapterStartSec: Double?
    var transcriptText: String?
    var transcriptStartSec: Double?
    var transcriptEndSec: Double?
    var color: String?
    var tags: [String]?
    let createdAt: String?
    let updatedAt: String?
    let episode: AnnotationEpisodeInfo?

    init(
        id: String, timestampSec: Double = 0, noteText: String = "",
        chapterTitle: String? = nil, chapterStartSec: Double? = nil,
        transcriptText: String? = nil, transcriptStartSec: Double? = nil, transcriptEndSec: Double? = nil,
        color: String? = nil, tags: [String]? = nil,
        createdAt: String? = nil, updatedAt: String? = nil,
        episode: AnnotationEpisodeInfo? = nil
    ) {
        self.id = id; self.timestampSec = timestampSec; self.noteText = noteText
        self.chapterTitle = chapterTitle; self.chapterStartSec = chapterStartSec
        self.transcriptText = transcriptText; self.transcriptStartSec = transcriptStartSec
        self.transcriptEndSec = transcriptEndSec; self.color = color; self.tags = tags
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.episode = episode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestampSec = try c.decodeIfPresent(Double.self, forKey: .timestampSec) ?? 0
        noteText = try c.decodeIfPresent(String.self, forKey: .noteText) ?? ""
        chapterTitle = try c.decodeIfPresent(String.self, forKey: .chapterTitle)
        chapterStartSec = try c.decodeIfPresent(Double.self, forKey: .chapterStartSec)
        transcriptText = try c.decodeIfPresent(String.self, forKey: .transcriptText)
        transcriptStartSec = try c.decodeIfPresent(Double.self, forKey: .transcriptStartSec)
        transcriptEndSec = try c.decodeIfPresent(Double.self, forKey: .transcriptEndSec)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        episode = try c.decodeIfPresent(AnnotationEpisodeInfo.self, forKey: .episode)
    }
}

/// Nested episode metadata in delta response — flattened into local model on apply.
struct AnnotationEpisodeInfo: Codable, Sendable {
    let episodeUrl: String?
    let podcastUrl: String?
    var episodeTitle: String?
    var podcastTitle: String?
    var artUrl: String?
    var durationSec: Double?
    var transcriptUrl: String?

    init(
        episodeUrl: String? = nil, podcastUrl: String? = nil,
        episodeTitle: String? = nil, podcastTitle: String? = nil,
        artUrl: String? = nil, durationSec: Double? = nil, transcriptUrl: String? = nil
    ) {
        self.episodeUrl = episodeUrl; self.podcastUrl = podcastUrl
        self.episodeTitle = episodeTitle; self.podcastTitle = podcastTitle
        self.artUrl = artUrl; self.durationSec = durationSec; self.transcriptUrl = transcriptUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeUrl = try c.decodeIfPresent(String.self, forKey: .episodeUrl)
        podcastUrl = try c.decodeIfPresent(String.self, forKey: .podcastUrl)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
        podcastTitle = try c.decodeIfPresent(String.self, forKey: .podcastTitle)
        artUrl = try c.decodeIfPresent(String.self, forKey: .artUrl)
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec)
        transcriptUrl = try c.decodeIfPresent(String.self, forKey: .transcriptUrl)
    }
}

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
    let hidden: Bool?          // ← NEW (Build 198) — episode is hidden from feed
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

// MARK: - Listening Stats

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
}

/// User info from session response.
struct ProUser: Codable {
    let id: String
    let email: String
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

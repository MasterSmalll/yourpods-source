import Foundation

/// Represents a user profile — either a gPodder server account or a local-only profile.
struct ServerProfile: Identifiable, Codable, Hashable {
    let id: String   // UUID string
    var name: String
    var baseUrl: String?
    var username: String?
    /// The device identifier sent to the gPodder server for sync. Defaults to "yourpods-ios".
    var deviceId: String
    /// Password stored in Keychain, not serialized here.
    var isLocal: Bool { baseUrl == nil }
    
    init(id: String = UUID().uuidString, name: String, baseUrl: String? = nil, username: String? = nil, deviceId: String = "yourpods-ios") {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.username = username
        self.deviceId = deviceId
    }
    
    /// Custom decoding to handle existing profiles that don't have a deviceId field yet.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? "yourpods-ios"
    }
}

/// Subscription delta returned by gPodder API.
struct SubscriptionDelta {
    let add: [String]
    let remove: [String]
    let timestamp: Int
}

/// Represents a sync conflict between local and server state.
struct SyncConflict: Identifiable {
    var id: String { episodeGuid }
    let episodeGuid: String
    let episodeTitle: String?
    let podcastTitle: String?
    let podcastUrl: String?
    let artworkUrl: String?
    let audioUrl: String?
    let localPosition: Int
    let serverPosition: Int
    let serverTimestamp: Int
    let totalDuration: Int?
    /// Number of times this conflict has been detected across sync cycles.
    let occurrenceCount: Int
}

/// Sync strategy for resolving conflicts.
enum SyncStrategy: String, Codable, CaseIterable {
    case serverWins
    case deviceWins
    case ask
}

/// Queue sync strategy.
enum QueueSyncStrategy: String, Codable, CaseIterable {
    case serverWins
    case deviceWins
    case ask
}

/// Represents a URL rewrite conflict from the server's `update_urls` response.
struct URLRewriteConflict: Identifiable {
    var id: String { oldUrl }
    let oldUrl: String
    let newUrl: String
    let podcastTitle: String?
    let artworkUrl: String?
}

/// Strategy for handling server URL rewrites.
enum URLRewriteStrategy: String, Codable, CaseIterable {
    case alwaysAccept
    case alwaysKeepLocal
    case ask
}

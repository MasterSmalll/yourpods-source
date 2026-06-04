import Foundation

// ─── YourPods Sync ───────────────────────────────────────────────────────
// ProfileType distinguishes sync backends. The app supports multiple sync
// modes: local-only (Vault), legacy gPodder, and YourPods Sync enhanced API.
// Firebase/Sync features are NOT required — see https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

/// The sync backend for a profile.
enum ProfileType: String, Codable, CaseIterable {
    /// Nextcloud gPodder sync or any self-hosted gPodder-compatible server.
    case gpodder
    /// gpodder.net — the free, public podcast sync service.
    case gpodderNet
    /// YourPods Sync enhanced sync API (queue, settings, playback handoff).
    case yourpodsPro
}

/// Represents a user profile — Vault Mode (on-device), gPodder sync, or YourPods Sync.
struct ServerProfile: Identifiable, Codable, Hashable {
    let id: String   // UUID string
    var name: String
    var baseUrl: String?
    var username: String?
    var deviceId: String
    /// The sync backend type. Defaults to `.gpodder` for backward compatibility.
    var profileType: ProfileType
    /// The YourPods Sync "Sync Profile Name" — shared across all devices that should
    /// sync the same settings, groups, and positions. Defaults to `"yourpodssync"`.
    ///
    /// Multiple devices with the same `proProfileName` share a common server profile.
    /// Changing this value forks the profile (a copy of the current settings is saved
    /// under the new name before switching).
    var proProfileName: String
    /// Password stored in Keychain, not serialized here.
    var isLocal: Bool { baseUrl == nil }

    init(
        id: String = UUID().uuidString,
        name: String,
        baseUrl: String? = nil,
        username: String? = nil,
        deviceId: String = "yourpods-ios",
        profileType: ProfileType = .gpodder,
        proProfileName: String = "yourpodssync"
    ) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.username = username
        self.deviceId = deviceId
        self.profileType = profileType
        self.proProfileName = proProfileName
    }

    /// Custom decoding to handle existing profiles saved before `proProfileName` was added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? "yourpods-ios"
        // Backward compat: profiles saved before YourPods Pro default to .gpodder
        profileType = try container.decodeIfPresent(ProfileType.self, forKey: .profileType) ?? .gpodder
        // Backward compat: profiles saved before proProfileName default to "yourpodssync"
        proProfileName = try container.decodeIfPresent(String.self, forKey: .proProfileName) ?? "yourpodssync"
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

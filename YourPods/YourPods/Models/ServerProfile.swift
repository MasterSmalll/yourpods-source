import Foundation

// ─── YourPods Sync ───────────────────────────────────────────────────────
// ProfileType distinguishes sync backends. The app supports multiple sync
// modes: local-only (Vault), legacy gPodder, and YourPods Sync enhanced API.
// Firebase/Sync features are NOT required — see https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

/// How a Nextcloud gPodder account was authenticated.
enum AuthMethod: String, Codable {
    /// User entered an app password manually.
    case manual
    /// Authenticated via Nextcloud Login Flow v2.
    case loginFlow
}

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
    /// How this account was authenticated. Optional for backward compatibility
    /// — existing profiles without this field decode as `nil`, and
    /// `resolvedAuthMethod` falls back to `.manual`.
    var storedAuthMethod: AuthMethod?
    /// Password stored in Keychain, not serialized here.
    var isLocal: Bool { baseUrl == nil }

    /// The effective auth method — falls back to `.manual` for pre-existing profiles.
    var resolvedAuthMethod: AuthMethod {
        storedAuthMethod ?? .manual
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        baseUrl: String? = nil,
        username: String? = nil,
        deviceId: String = "yourpods-ios",
        profileType: ProfileType = .gpodder,
        proProfileName: String = "yourpodssync",
        authMethod: AuthMethod? = nil
    ) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.username = username
        self.deviceId = deviceId
        self.profileType = profileType
        self.proProfileName = proProfileName
        self.storedAuthMethod = authMethod
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
        // Backward compat: profiles saved before Login Flow v2 have no authMethod
        storedAuthMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .storedAuthMethod)
    }
}

/// Subscription delta returned by gPodder API.
struct SubscriptionDelta {
    let add: [String]
    let remove: [String]
    let timestamp: Int
}

/// Represents a sync conflict between local and server state.
struct SyncConflict: Identifiable, Sendable, Codable {
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
    /// Whether the SERVER holds this episode as finished.
    ///
    /// A completed row stores `position_sec = duration`, so `serverPosition` alone cannot
    /// tell "finished" from "paused one second short" — the sheet renders both as the same
    /// timestamp and asks the user to choose between two numbers when one of them is not a
    /// position at all. Defaults to `false`: locally-detected conflicts never carry the
    /// flag, and the deployed server does not send it yet.
    let serverCompleted: Bool
    /// Which device authored `localPosition`.
    ///
    /// "Local" means the device that wrote the row, **not** the one reading it. Null for
    /// bridge-written rows (no device authored those: the local side is YourPods' own
    /// stored position facing a remote gPodder host) and for conflicts this device
    /// detected itself, which the server has never seen.
    let deviceId: String?
    /// Server conflict record ID for resolving via POST /sync-conflicts/resolve.
    /// Nil for locally-detected conflicts that haven't been sent to the server.
    let serverConflictId: Int?

    init(
        episodeGuid: String,
        episodeTitle: String?,
        podcastTitle: String?,
        podcastUrl: String?,
        artworkUrl: String?,
        audioUrl: String?,
        localPosition: Int,
        serverPosition: Int,
        serverTimestamp: Int,
        totalDuration: Int?,
        occurrenceCount: Int,
        serverCompleted: Bool = false,
        deviceId: String? = nil,
        serverConflictId: Int? = nil
    ) {
        self.episodeGuid = episodeGuid
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.podcastUrl = podcastUrl
        self.artworkUrl = artworkUrl
        self.audioUrl = audioUrl
        self.localPosition = localPosition
        self.serverPosition = serverPosition
        self.serverTimestamp = serverTimestamp
        self.totalDuration = totalDuration
        self.occurrenceCount = occurrenceCount
        self.serverCompleted = serverCompleted
        self.deviceId = deviceId
        self.serverConflictId = serverConflictId
    }
}

/// Sync strategy for resolving conflicts.
enum SyncStrategy: String, Codable, CaseIterable, Sendable {
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
struct URLRewriteConflict: Identifiable, Sendable {
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

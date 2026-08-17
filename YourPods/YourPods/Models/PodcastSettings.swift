import Foundation

/// Controls how new episodes are auto-added to the queue (AutoPilot).
enum AutoQueueMode: String, Codable, CaseIterable {
    /// Don't auto-add new episodes to Up Next.
    case off
    /// Add new episodes to the bottom of Up Next.
    case normal
    /// Add new episodes to the top of Up Next (play next).
    case priority
    
    /// Human-readable label for the UI.
    var displayName: String {
        switch self {
        case .off:      return "Off"
        case .normal:   return "Add to Queue"
        case .priority: return "Play Next"
        }
    }
    
    /// Short description explaining the behavior.
    var subtitle: String {
        switch self {
        case .off:      return "Don't auto-add new episodes"
        case .normal:   return "New episodes are added to the bottom of Up Next"
        case .priority: return "New episodes are added to the top of Up Next"
        }
    }
    
    /// Server API value (differs from rawValue).
    var serverValue: String {
        switch self {
        case .off:      return "off"
        case .normal:   return "addToQueue"
        case .priority: return "playNext"
        }
    }
    
    /// Create from server API value.
    static func fromServerValue(_ value: String) -> AutoQueueMode? {
        switch value {
        case "off":         return .off
        case "addToQueue":  return .normal
        case "playNext":    return .priority
        default:            return nil
        }
    }
}

/// Controls when downloaded episode files are automatically cleaned up.
enum DownloadCleanupPolicy: String, Codable, CaseIterable {
    /// Delete the download immediately when the episode finishes playing.
    case oncePlayed
    /// Delete the download 7 days after the episode finishes playing.
    case afterOneWeek
    /// Delete the download 30 days after the episode finishes playing.
    case afterOneMonth
    /// Never automatically delete downloads.
    case never
    
    var displayName: String {
        switch self {
        case .oncePlayed: "Once Played"
        case .afterOneWeek: "After 1 Week"
        case .afterOneMonth: "After 1 Month"
        case .never: "Never"
        }
    }
    
    /// Server API value.
    var serverValue: String {
        switch self {
        case .oncePlayed:   return "oncePlayed"
        case .afterOneWeek: return "1week"
        case .afterOneMonth: return "1month"
        case .never:        return "never"
        }
    }
    
    /// Create from server API value.
    static func fromServerValue(_ value: String) -> DownloadCleanupPolicy? {
        switch value {
        case "oncePlayed":  return .oncePlayed
        case "1week":       return .afterOneWeek
        case "1month":      return .afterOneMonth
        case "never":       return .never
        default:            return nil
        }
    }
}

/// Listening Profile — per-podcast settings that override global defaults.
/// Any nil field means "use the global default from SettingsManager".
struct PodcastSettings: Codable, Hashable {
    var autoQueueMode: AutoQueueMode? = nil
    var skipIntroSeconds: Int? = nil
    var skipOutroSeconds: Int? = nil
    var archiveOnComplete: Bool? = nil
    var playbackSpeed: Double? = nil
    var autoDownloadNewEpisodes: Bool? = nil
    var downloadCleanupPolicy: DownloadCleanupPolicy? = nil
    var autoDownloadEpisodeLimit: Int? = nil
    var markedPlayedBefore: Date? = nil
    /// P3 — Privacy Preserving Playback override. nil = use global default.
    var privacyMode: Bool? = nil
    /// Per-podcast notification override. nil/false = don't notify, true = notify.
    /// Opt-in model: users must explicitly enable per podcast.
    var notificationsEnabled: Bool? = nil
    /// Per-podcast auto-hide override. nil = use global, 0 = disabled, N = custom days.
    var autoHideUnplayedDays: Int? = nil
    
    /// Whether any setting is overridden from defaults.
    var hasOverrides: Bool {
        autoQueueMode != nil ||
        skipIntroSeconds != nil ||
        skipOutroSeconds != nil ||
        archiveOnComplete != nil ||
        playbackSpeed != nil ||
        autoDownloadNewEpisodes != nil ||
        downloadCleanupPolicy != nil ||
        autoDownloadEpisodeLimit != nil ||
        markedPlayedBefore != nil ||
        privacyMode != nil ||
        notificationsEnabled != nil ||
        autoHideUnplayedDays != nil
    }
    
    static let useDefaults = PodcastSettings()
    
    // MARK: - Migration from removeDownloadAfterPlay Bool
    
    enum CodingKeys: String, CodingKey {
        case autoQueueMode, skipIntroSeconds, skipOutroSeconds, archiveOnComplete
        case playbackSpeed, autoDownloadNewEpisodes, downloadCleanupPolicy
        case autoDownloadEpisodeLimit, markedPlayedBefore
        case privacyMode, notificationsEnabled, autoHideUnplayedDays
        case serverExtras
        case removeDownloadAfterPlay // legacy key for migration
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoQueueMode = try container.decodeIfPresent(AutoQueueMode.self, forKey: .autoQueueMode)
        skipIntroSeconds = try container.decodeIfPresent(Int.self, forKey: .skipIntroSeconds)
        skipOutroSeconds = try container.decodeIfPresent(Int.self, forKey: .skipOutroSeconds)
        archiveOnComplete = try container.decodeIfPresent(Bool.self, forKey: .archiveOnComplete)
        playbackSpeed = try container.decodeIfPresent(Double.self, forKey: .playbackSpeed)
        autoDownloadNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .autoDownloadNewEpisodes)
        autoDownloadEpisodeLimit = try container.decodeIfPresent(Int.self, forKey: .autoDownloadEpisodeLimit)
        markedPlayedBefore = try container.decodeIfPresent(Date.self, forKey: .markedPlayedBefore)
        privacyMode = try container.decodeIfPresent(Bool.self, forKey: .privacyMode)
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
        autoHideUnplayedDays = try container.decodeIfPresent(Int.self, forKey: .autoHideUnplayedDays)
        serverExtras = (try container.decodeIfPresent([String: AnyCodableValue].self, forKey: .serverExtras)) ?? [:]
        
        // Try new key first, fall back to legacy Bool
        if let policy = try container.decodeIfPresent(DownloadCleanupPolicy.self, forKey: .downloadCleanupPolicy) {
            downloadCleanupPolicy = policy
        } else if let legacyBool = try container.decodeIfPresent(Bool.self, forKey: .removeDownloadAfterPlay) {
            downloadCleanupPolicy = legacyBool ? .oncePlayed : nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(autoQueueMode, forKey: .autoQueueMode)
        try container.encodeIfPresent(skipIntroSeconds, forKey: .skipIntroSeconds)
        try container.encodeIfPresent(skipOutroSeconds, forKey: .skipOutroSeconds)
        try container.encodeIfPresent(archiveOnComplete, forKey: .archiveOnComplete)
        try container.encodeIfPresent(playbackSpeed, forKey: .playbackSpeed)
        try container.encodeIfPresent(autoDownloadNewEpisodes, forKey: .autoDownloadNewEpisodes)
        try container.encodeIfPresent(downloadCleanupPolicy, forKey: .downloadCleanupPolicy)
        try container.encodeIfPresent(autoDownloadEpisodeLimit, forKey: .autoDownloadEpisodeLimit)
        try container.encodeIfPresent(markedPlayedBefore, forKey: .markedPlayedBefore)
        try container.encodeIfPresent(privacyMode, forKey: .privacyMode)
        try container.encodeIfPresent(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encodeIfPresent(autoHideUnplayedDays, forKey: .autoHideUnplayedDays)
        if !serverExtras.isEmpty {
            try container.encode(serverExtras, forKey: .serverExtras)
        }
        // Do NOT encode legacy removeDownloadAfterPlay — new data uses downloadCleanupPolicy
    }
    
    init() {}
    
    // MARK: - Server Sync Mapping
    
    /// Extra keys from the server that don't map to a local property.
    /// Preserved for round-tripping so other platforms don't lose data.
    var serverExtras: [String: AnyCodableValue] = [:]
    
    /// Convert local settings to the server's payload format.
    /// Only includes non-nil overrides. Unknown keys from `serverExtras` are merged.
    func toServerPayload() -> [String: AnyCodableValue] {
        var payload: [String: AnyCodableValue] = [:]
        
        if let skipIntroSeconds { payload["skipIntroSec"] = .int(skipIntroSeconds) }
        if let skipOutroSeconds { payload["skipOutroSec"] = .int(skipOutroSeconds) }
        if let autoQueueMode { payload["autopilot"] = .string(autoQueueMode.serverValue) }
        if let playbackSpeed { payload["playbackSpeed"] = .double(playbackSpeed) }
        if let autoDownloadNewEpisodes { payload["autoDownload"] = .bool(autoDownloadNewEpisodes) }
        if let downloadCleanupPolicy { payload["downloadCleanup"] = .string(downloadCleanupPolicy.serverValue) }
        if let autoDownloadEpisodeLimit { payload["autoDownloadEpisodeLimit"] = .int(autoDownloadEpisodeLimit) }
        if let archiveOnComplete { payload["archiveOnComplete"] = .bool(archiveOnComplete) }
        if let privacyMode { payload["privacyMode"] = .bool(privacyMode) }
        if let notificationsEnabled { payload["notifications"] = .bool(notificationsEnabled) }
        if let autoHideUnplayedDays { payload["autoHideUnplayedDays"] = .int(autoHideUnplayedDays) }
        
        // Merge unknown keys for round-tripping
        for (key, value) in serverExtras {
            payload[key] = value
        }
        
        return payload
    }
    
    /// Create a PodcastSettings from a server payload dictionary.
    /// Known keys are mapped to local properties; unknown keys are stored in `serverExtras`.
    static func fromServerPayload(_ payload: [String: AnyCodableValue]) -> PodcastSettings {
        let knownKeys: Set<String> = [
            "skipIntroSec", "skipOutroSec", "autopilot", "playbackSpeed",
            "autoDownload", "downloadCleanup", "autoDownloadEpisodeLimit",
            "archiveOnComplete", "privacyMode", "notifications", "autoHideUnplayedDays"
        ]
        
        var settings = PodcastSettings()
        
        // Skip intro/outro: accept both .int and .double (server may send 15 or 15.0)
        if case .int(let v) = payload["skipIntroSec"] { settings.skipIntroSeconds = v }
        else if case .double(let v) = payload["skipIntroSec"] { settings.skipIntroSeconds = Int(v) }
        if case .int(let v) = payload["skipOutroSec"] { settings.skipOutroSeconds = v }
        else if case .double(let v) = payload["skipOutroSec"] { settings.skipOutroSeconds = Int(v) }
        if case .string(let v) = payload["autopilot"] { settings.autoQueueMode = AutoQueueMode.fromServerValue(v) }
        // Playback speed: accept both .double and .int (server may send 2 or 2.0)
        if case .double(let v) = payload["playbackSpeed"] { settings.playbackSpeed = v }
        else if case .int(let v) = payload["playbackSpeed"] { settings.playbackSpeed = Double(v) }
        if case .bool(let v) = payload["autoDownload"] { settings.autoDownloadNewEpisodes = v }
        if case .string(let v) = payload["downloadCleanup"] { settings.downloadCleanupPolicy = DownloadCleanupPolicy.fromServerValue(v) }
        if case .int(let v) = payload["autoDownloadEpisodeLimit"] { settings.autoDownloadEpisodeLimit = v }
        if case .bool(let v) = payload["archiveOnComplete"] { settings.archiveOnComplete = v }
        if case .bool(let v) = payload["privacyMode"] { settings.privacyMode = v }
        if case .bool(let v) = payload["notifications"] { settings.notificationsEnabled = v }
        if case .int(let v) = payload["autoHideUnplayedDays"] { settings.autoHideUnplayedDays = v }
        
        // Preserve unknown keys for round-tripping
        for (key, value) in payload where !knownKeys.contains(key) {
            settings.serverExtras[key] = value
        }
        
        return settings
    }
    
    // MARK: - Field-Level Merge
    
    /// Merge server settings with local settings at the field level.
    /// Local non-nil fields take priority (they were just pushed to the server).
    /// Server values fill in fields that are nil locally (cross-device adoption).
    /// Server extras are merged with local extras taking priority.
    func merging(serverSettings: PodcastSettings) -> PodcastSettings {
        var result = self
        
        // For each field: keep local if non-nil, otherwise adopt server value
        if result.autoQueueMode == nil { result.autoQueueMode = serverSettings.autoQueueMode }
        if result.skipIntroSeconds == nil { result.skipIntroSeconds = serverSettings.skipIntroSeconds }
        if result.skipOutroSeconds == nil { result.skipOutroSeconds = serverSettings.skipOutroSeconds }
        if result.archiveOnComplete == nil { result.archiveOnComplete = serverSettings.archiveOnComplete }
        if result.playbackSpeed == nil { result.playbackSpeed = serverSettings.playbackSpeed }
        if result.autoDownloadNewEpisodes == nil { result.autoDownloadNewEpisodes = serverSettings.autoDownloadNewEpisodes }
        if result.downloadCleanupPolicy == nil { result.downloadCleanupPolicy = serverSettings.downloadCleanupPolicy }
        if result.autoDownloadEpisodeLimit == nil { result.autoDownloadEpisodeLimit = serverSettings.autoDownloadEpisodeLimit }
        if result.privacyMode == nil { result.privacyMode = serverSettings.privacyMode }
        if result.notificationsEnabled == nil { result.notificationsEnabled = serverSettings.notificationsEnabled }
        if result.autoHideUnplayedDays == nil { result.autoHideUnplayedDays = serverSettings.autoHideUnplayedDays }
        // markedPlayedBefore is local-only (not synced) — don't merge
        
        // Merge server extras: server values fill gaps, local extras take priority
        for (key, value) in serverSettings.serverExtras where result.serverExtras[key] == nil {
            result.serverExtras[key] = value
        }
        
        return result
    }
}

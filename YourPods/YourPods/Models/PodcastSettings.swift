import Foundation

/// Controls how new episodes are auto-added to the queue.
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
}

/// Per-podcast settings that override global defaults.
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
        markedPlayedBefore != nil
    }
    
    static let useDefaults = PodcastSettings()
    
    // MARK: - Migration from removeDownloadAfterPlay Bool
    
    enum CodingKeys: String, CodingKey {
        case autoQueueMode, skipIntroSeconds, skipOutroSeconds, archiveOnComplete
        case playbackSpeed, autoDownloadNewEpisodes, downloadCleanupPolicy
        case autoDownloadEpisodeLimit, markedPlayedBefore
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
        // Do NOT encode legacy removeDownloadAfterPlay — new data uses downloadCleanupPolicy
    }
    
    init() {}
}

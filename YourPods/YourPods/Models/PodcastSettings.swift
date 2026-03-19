import Foundation

/// Controls how new episodes are auto-added to the queue.
enum AutoQueueMode: String, Codable, CaseIterable {
    /// Don't auto-queue episodes for this podcast.
    case off
    /// Add new episodes to the end of the queue.
    case normal
    /// Add new episodes to the top of the queue (play next).
    case priority
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
    var removeDownloadAfterPlay: Bool? = nil
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
        removeDownloadAfterPlay != nil ||
        autoDownloadEpisodeLimit != nil ||
        markedPlayedBefore != nil
    }
    
    static let useDefaults = PodcastSettings()
}

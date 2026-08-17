import Foundation

// MARK: - Queue Item

/// Lightweight value type representing an item in the playback queue.
/// Separate from the SwiftData Episode model to avoid threading issues with AVFoundation.
struct QueueItem: Identifiable, Equatable, Codable {
    let id: String          // Episode GUID
    let title: String
    let podcastTitle: String
    let audioUrl: String
    let artworkUrl: String?
    /// Podcast logo used as Now Playing artwork fallback when the episode
    /// image can't be loaded (offline with a cold cache). The logo is far more
    /// likely to be disk-cached — it's the thumbnail shown across the app.
    var fallbackArtworkUrl: String? = nil
    let durationSeconds: Int?
    var positionSeconds: Int = 0
    let podcastUrl: String
    let pubDate: Date?
    var podcastAuthor: String? = nil
    var chaptersUrl: String? = nil
    var transcriptUrl: String? = nil
    /// MIME type declared by the feed for `transcriptUrl`.
    var transcriptType: String? = nil
    var episodeDescription: String? = nil
    var chaptersJSON: String? = nil

    // Per-episode playback settings (resolved at enqueue time)
    var skipIntroSeconds: Int = 0
    var skipOutroSeconds: Int = 0
    var playbackSpeed: Float = 1.0
    
    /// P3 — Privacy Preserving Playback. When true, tracking/DAI prefixes are
    /// stripped from audioUrl before playback. Resolved at enqueue time from
    /// per-podcast settings with global fallback.
    var privacyMode: Bool = false
    
    /// Whether this episode has been marked as played (runtime-only, not serialized).
    /// Used by AudioManager.playEpisode(preserveCurrent:) to skip re-queuing played episodes.
    var isPlayed: Bool = false
    
    /// Local file URL for downloaded episodes (not serialized — device-specific).
    /// When set, AudioManager skips URL resolution and plays directly from disk.
    var localFileUrl: URL? = nil
    
    /// Auth headers for protected feeds (not serialized)
    var authHeaders: [String: String]? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, title, podcastTitle, audioUrl, artworkUrl, fallbackArtworkUrl, durationSeconds, positionSeconds, podcastUrl, pubDate, podcastAuthor, chaptersUrl, transcriptUrl, transcriptType, episodeDescription, chaptersJSON
        case skipIntroSeconds, skipOutroSeconds, playbackSpeed
        case privacyMode
    }
    
    /// Custom decoder with backward-compatible defaults for new fields.
    /// Queues persisted before this change won't have skip/speed keys — they decode as 0/1.0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        podcastTitle = try c.decode(String.self, forKey: .podcastTitle)
        audioUrl = try c.decode(String.self, forKey: .audioUrl)
        artworkUrl = try c.decodeIfPresent(String.self, forKey: .artworkUrl)
        fallbackArtworkUrl = try c.decodeIfPresent(String.self, forKey: .fallbackArtworkUrl)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        positionSeconds = try c.decodeIfPresent(Int.self, forKey: .positionSeconds) ?? 0
        podcastUrl = try c.decode(String.self, forKey: .podcastUrl)
        pubDate = try c.decodeIfPresent(Date.self, forKey: .pubDate)
        podcastAuthor = try c.decodeIfPresent(String.self, forKey: .podcastAuthor)
        chaptersUrl = try c.decodeIfPresent(String.self, forKey: .chaptersUrl)
        transcriptUrl = try c.decodeIfPresent(String.self, forKey: .transcriptUrl)
        transcriptType = try c.decodeIfPresent(String.self, forKey: .transcriptType)
        episodeDescription = try c.decodeIfPresent(String.self, forKey: .episodeDescription)
        chaptersJSON = try c.decodeIfPresent(String.self, forKey: .chaptersJSON)
        skipIntroSeconds = try c.decodeIfPresent(Int.self, forKey: .skipIntroSeconds) ?? 0
        skipOutroSeconds = try c.decodeIfPresent(Int.self, forKey: .skipOutroSeconds) ?? 0
        playbackSpeed = try c.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? 1.0
        privacyMode = try c.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? false
    }
    
    /// Memberwise init (used in code and tests)
    init(
        id: String,
        title: String,
        podcastTitle: String,
        audioUrl: String,
        artworkUrl: String?,
        durationSeconds: Int?,
        positionSeconds: Int = 0,
        podcastUrl: String,
        pubDate: Date?,
        podcastAuthor: String? = nil,
        chaptersUrl: String? = nil,
        transcriptUrl: String? = nil,
        transcriptType: String? = nil,
        episodeDescription: String? = nil,
        chaptersJSON: String? = nil,
        skipIntroSeconds: Int = 0,
        skipOutroSeconds: Int = 0,
        playbackSpeed: Float = 1.0,
        privacyMode: Bool = false,
        fallbackArtworkUrl: String? = nil
    ) {
        self.id = id
        self.title = title
        self.podcastTitle = podcastTitle
        self.audioUrl = audioUrl
        self.artworkUrl = artworkUrl
        self.durationSeconds = durationSeconds
        self.positionSeconds = positionSeconds
        self.podcastUrl = podcastUrl
        self.pubDate = pubDate
        self.podcastAuthor = podcastAuthor
        self.chaptersUrl = chaptersUrl
        self.transcriptUrl = transcriptUrl
        self.transcriptType = transcriptType
        self.episodeDescription = episodeDescription
        self.chaptersJSON = chaptersJSON
        self.skipIntroSeconds = skipIntroSeconds
        self.skipOutroSeconds = skipOutroSeconds
        self.playbackSpeed = playbackSpeed
        self.privacyMode = privacyMode
        self.fallbackArtworkUrl = fallbackArtworkUrl
    }
    
    /// Convert from SwiftData Episode model, resolving per-podcast settings.
    static func from(episode: Episode, positionSeconds: Int? = nil) -> QueueItem? {
        guard let audioUrl = episode.audioUrl else { return nil }
        
        // Resolve per-podcast skip/speed settings
        let settings = episode.podcast?.effectiveSettings
        
        var item = QueueItem(
            id: episode.guid,
            title: episode.title,
            podcastTitle: episode.podcastTitle ?? "",
            audioUrl: audioUrl,
            artworkUrl: episode.imageUrl ?? episode.podcast?.logoUrl,
            durationSeconds: episode.durationSeconds,
            positionSeconds: positionSeconds ?? (episode.isPlayed ? 0 : episode.listenedSeconds),
            podcastUrl: episode.podcastUrl ?? "",
            pubDate: episode.pubDate,
            podcastAuthor: episode.podcast?.author,
            chaptersUrl: episode.chaptersUrl,
            transcriptUrl: episode.transcriptUrl,
            transcriptType: episode.transcriptType,
            episodeDescription: episode.episodeDescription,
            chaptersJSON: episode.chaptersJSON,
            skipIntroSeconds: settings?.skipIntroSeconds ?? 0,
            skipOutroSeconds: settings?.skipOutroSeconds ?? 0,
            playbackSpeed: Float(settings?.playbackSpeed ?? 1.0)
        )
        // Podcast logo as Now Playing artwork fallback — episode-specific art
        // is rarely in the disk cache; the logo almost always is.
        item.fallbackArtworkUrl = episode.podcast?.logoUrl
        // Attach auth headers for protected feeds
        if let podcast = episode.podcast, podcast.requiresAuth,
           let header = KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: podcast.url) {
            item.authHeaders = ["Authorization": header]
        }
        return item
    }
}

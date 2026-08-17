import Foundation
import SwiftData

@Model
final class Episode {
    var guid: String
    var title: String
    var episodeDescription: String?
    var audioUrl: String?
    var pubDate: Date?
    var imageUrl: String?
    /// Duration in seconds
    var durationSeconds: Int?
    var link: String?
    var chaptersUrl: String?
    var transcriptUrl: String?
    /// MIME type declared by `<podcast:transcript type="...">`.
    ///
    /// Persisted so the parser never has to re-guess the format from the URL —
    /// presigned CDN URLs carry query strings and often no extension at all.
    var transcriptType: String?
    /// Inline Podlove Simple Chapters, serialized as JSON for persistence
    var chaptersJSON: String?
    
    // MARK: - Apple itunes: 1.x / Podcasting 2.0 metadata
    
    /// Season number from <itunes:season> or <podcast:season>
    var seasonNumber: Int?
    /// Season name from <podcast:season name="...">
    var seasonName: String?
    /// Episode number from <itunes:episode> or <podcast:episode>
    var episodeNumber: Double?
    /// Episode display string from <podcast:episode display="...">
    var episodeDisplay: String?
    /// Episode type: "full", "trailer", or "bonus" (itunes:episodeType)
    var episodeType: String?
    /// Position of this episode in the RSS feed's document order (0-based).
    /// Used as a tie-breaker when pubDates are nil or equal.
    var feedItemIndex: Int?
    /// Whether the episode contains explicit content (itunes:explicit)
    var explicit: Bool?
    
    /// Playback position in seconds (synced from server or local playback)
    var listenedSeconds: Int = 0
    /// Whether the episode has been fully played
    var isPlayed: Bool = false
    
    /// Whether the user has interacted with this episode (played or queued).
    /// Used to remove episodes from "Recently Updated" immediately on action.
    var isInteracted: Bool = false
    
    /// Whether this episode is no longer present in the podcast's RSS feed.
    /// Stale episodes are excluded from episode counts and the default episode list,
    /// but retained if the user has downloads or playback progress.
    var isStale: Bool = false
    
    /// Relationship to parent podcast
    var podcast: Podcast?
    
    /// Convenience to get the podcast URL without loading the full object
    var podcastUrl: String? { podcast?.url }
    var podcastTitle: String? { podcast?.title }
    
    /// Computed listen progress (0.0 to 1.0)
    var listenProgress: Double {
        guard let total = durationSeconds, total > 0 else { return 0 }
        return min(1.0, Double(listenedSeconds) / Double(total))
    }
    
    /// Computed duration as TimeInterval
    var duration: TimeInterval? {
        guard let s = durationSeconds else { return nil }
        return TimeInterval(s)
    }
    
    init(
        guid: String,
        title: String,
        episodeDescription: String? = nil,
        audioUrl: String? = nil,
        pubDate: Date? = nil,
        imageUrl: String? = nil,
        durationSeconds: Int? = nil,
        link: String? = nil,
        chaptersUrl: String? = nil,
        transcriptUrl: String? = nil,
        transcriptType: String? = nil,
        podcast: Podcast? = nil
    ) {
        self.guid = guid
        self.title = title
        self.episodeDescription = episodeDescription
        self.audioUrl = audioUrl
        self.pubDate = pubDate
        self.imageUrl = imageUrl
        self.durationSeconds = durationSeconds
        self.link = link
        self.chaptersUrl = chaptersUrl
        self.transcriptUrl = transcriptUrl
        self.transcriptType = transcriptType
        self.podcast = podcast
    }
}

extension Episode {
    /// Assign `listenedSeconds` only when the value differs.
    ///
    /// Core Data marks a row dirty on ANY setter call — even an
    /// identical-value assignment whose `changedValues()` is empty — and
    /// re-writes it (Z_OPT version bump ≈ 2 WAL pages). The
    /// episode-actions apply re-assigns the server position for every episode
    /// that has an action; under a `since=0` full re-pull that is the whole
    /// library, so without this guard a no-change sync re-writes ~1488 rows.
    func setListenedSecondsIfChanged(_ value: Int) {
        if listenedSeconds != value { listenedSeconds = value }
    }

    /// Mark played only when not already played — same no-churn guard.
    func markPlayedIfNeeded() {
        if !isPlayed { isPlayed = true }
    }

    /// Mark unplayed only when currently played — churn guard mirror of markPlayedIfNeeded.
    /// Resets the listen position so a re-add/relisten starts clean.
    /// Safe to call unconditionally: no-ops when already unplayed.
    func markUnplayedIfNeeded() {
        if isPlayed { isPlayed = false }
        if listenedSeconds != 0 { listenedSeconds = 0 }
    }
}

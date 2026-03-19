import Foundation
import SwiftData

@Model
final class Episode {
    @Attribute(.unique) var guid: String
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
    
    /// Playback position in seconds (synced from server or local playback)
    var listenedSeconds: Int = 0
    /// Whether the episode has been fully played
    var isPlayed: Bool = false
    
    /// Whether the user has interacted with this episode (played or queued).
    /// Used to remove episodes from "Recently Updated" immediately on action.
    var isInteracted: Bool = false
    
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
        self.podcast = podcast
    }
}

import Foundation
import SwiftData

@Model
final class Podcast {
    @Attribute(.unique) var url: String
    var title: String
    var podcastDescription: String?
    var logoUrl: String?
    var website: String?
    var author: String?
    var requiresAuth: Bool
    var feedUsername: String?
    
    /// Inverse relationship — episodes belonging to this podcast
    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []
    
    // MARK: - RSS 2.0 / Apple itunes: 1.x metadata
    
    /// Feed language (e.g. "en-us") from <language>
    var language: String?
    /// Feed copyright notice from <copyright>
    var copyright: String?
    /// Categories from <itunes:category> (may have multiple)
    var categories: [String] = []
    /// Subcategory from nested <itunes:category>
    var subcategory: String?
    /// Whether the podcast contains explicit content (itunes:explicit)
    var explicit: Bool?
    /// Show type: "episodic" (default) or "serial" (itunes:type)
    var showType: String?
    /// Whether the show is complete / no new episodes (itunes:complete)
    var isComplete: Bool = false
    /// Feed URL migration target (itunes:new-feed-url)
    var newFeedUrl: String?
    
    // MARK: - Podcasting 2.0 metadata
    
    /// Unique podcast GUID from <podcast:guid>
    var podcastGuid: String?
    /// Support/funding URL from <podcast:funding>
    var fundingUrl: String?
    /// Support/funding label from <podcast:funding>
    var fundingLabel: String?
    /// Publisher name from <podcast:publisher>
    var publisher: String?
    /// Whether feed declares <podcast:value> (V4V support)
    var supportsValue4Value: Bool = false
    /// Whether feed contains <podcast:liveItem>
    var hasLiveItem: Bool = false
    /// Live item status (pending/live/ended) from <podcast:liveItem>
    var liveItemStatus: String?
    /// Live item start time from <podcast:liveItem>
    var liveItemStart: Date?
    /// Live item content link from <podcast:contentLink> inside liveItem
    var liveItemContentLink: String?
    
    /// Per-podcast settings (stored inline, optional for backward compatibility
    /// with older SwiftData stores that may have NULL for this column).
    var settings: PodcastSettings?
    
    /// Safe accessor that returns settings or defaults.
    var effectiveSettings: PodcastSettings {
        get { settings ?? PodcastSettings() }
        set { settings = newValue }
    }
    
    /// User-defined sort order in the library
    var sortOrder: Int = 0
    
    init(
        url: String,
        title: String,
        podcastDescription: String? = nil,
        logoUrl: String? = nil,
        website: String? = nil,
        author: String? = nil,
        requiresAuth: Bool = false
    ) {
        self.url = url
        self.title = title
        self.podcastDescription = podcastDescription
        self.logoUrl = logoUrl
        self.website = website
        self.author = author
        self.requiresAuth = requiresAuth
        self.settings = PodcastSettings()
    }
}

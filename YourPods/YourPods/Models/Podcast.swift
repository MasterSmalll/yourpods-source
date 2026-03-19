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
    
    /// Inverse relationship — episodes belonging to this podcast
    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []
    
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

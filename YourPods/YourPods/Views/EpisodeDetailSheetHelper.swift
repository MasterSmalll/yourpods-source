import Foundation

/// Testable helper for EpisodeDetailSheet logic.
/// Extracted to allow unit testing without SwiftUI view dependencies.
enum EpisodeDetailSheetHelper {
    
    /// Resolve a podcast URL for the "Mark as Played" action.
    /// Falls back through: episode.podcastUrl → currentItem.podcastUrl → subscription search.
    ///
    /// - Parameters:
    ///   - episodePodcastUrl: The episode's podcast?.url (may be nil from SwiftData lazy loading)
    ///   - currentItemPodcastUrl: The currently playing QueueItem's podcastUrl (non-optional on QueueItem)
    ///   - episodeGuid: The episode GUID for subscription search fallback
    ///   - subscriptions: All subscribed podcasts to search through
    /// - Returns: A resolved podcast URL, or nil if all sources fail
    static func resolvePodcastUrl(
        episodePodcastUrl: String?,
        currentItemPodcastUrl: String?,
        episodeGuid: String,
        subscriptions: [Podcast]
    ) -> String? {
        // 1. Prefer the episode's own podcast URL (most common path)
        if let episodePodcastUrl, !episodePodcastUrl.isEmpty {
            return episodePodcastUrl
        }
        
        // 2. Fall back to the currently playing QueueItem's podcastUrl
        if let currentItemPodcastUrl, !currentItemPodcastUrl.isEmpty {
            return currentItemPodcastUrl
        }
        
        // 3. Search subscriptions by episode GUID
        for podcast in subscriptions {
            if podcast.episodes.contains(where: { $0.guid == episodeGuid }) {
                return podcast.url
            }
        }
        
        return nil
    }
}

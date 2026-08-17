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
    
    /// Determines whether marking an episode as played should route through PlayerManager
    /// (which advances to the next Up Next episode, stopping only when Up Next is empty)
    /// vs. PodcastManager only (data-layer update).
    ///
    /// - Parameters:
    ///   - episodeGuid: The GUID of the episode being marked as played
    ///   - currentEpisodeGuid: The GUID of the currently playing episode (nil if nothing playing)
    /// - Returns: true if the episode is currently playing and PlayerManager should handle it
    static func shouldUsePlayerManager(
        episodeGuid: String,
        currentEpisodeGuid: String?
    ) -> Bool {
        guard let currentEpisodeGuid else { return false }
        return episodeGuid == currentEpisodeGuid
    }
    
    /// Find the subscribed podcast matching the given URL.
    /// Returns nil if the podcast is not in the user's subscriptions.
    ///
    /// - Parameters:
    ///   - podcastUrl: The podcast feed URL to search for
    ///   - subscriptions: All subscribed podcasts to search through
    /// - Returns: The matching Podcast, or nil if not found
    static func findSubscribedPodcast(
        podcastUrl: String?,
        subscriptions: [Podcast]
    ) -> Podcast? {
        guard let podcastUrl, !podcastUrl.isEmpty else { return nil }
        return subscriptions.first(where: { $0.url == podcastUrl })
    }
    
    /// Resolve an Episode for display in the detail sheet.
    ///
    /// First searches subscribed podcasts for a matching episode (by GUID).
    /// If not found and a `fallbackQueueItem` is provided, creates a transient
    /// (non-persisted) Episode from the QueueItem's data so the full detail sheet
    /// can be shown even for episodes not in the user's library.
    ///
    /// - Parameters:
    ///   - guid: The episode GUID to search for
    ///   - subscriptions: All subscribed podcasts to search through
    ///   - fallbackQueueItem: The currently playing or queued QueueItem to use as fallback data
    /// - Returns: An Episode (either from subscriptions or synthesized from QueueItem), or nil
    static func resolveEpisodeForDisplay(
        guid: String,
        subscriptions: [Podcast],
        fallbackQueueItem: QueueItem?
    ) -> Episode? {
        // 1. Search subscribed podcasts for the episode (preferred — has full podcast relationship)
        for podcast in subscriptions {
            if let ep = podcast.episodes.first(where: { $0.guid == guid }) {
                return ep
            }
        }
        
        // 2. Fall back to creating a transient Episode from QueueItem data.
        //    This allows non-subscribed episodes (e.g. from search) to show the
        //    full detail sheet with chapters, transcript, description, etc.
        guard let item = fallbackQueueItem, item.id == guid else { return nil }
        
        // Create a transient Podcast to carry the title and URL.
        // Episode.podcastTitle and .podcastUrl are computed from podcast?.title / podcast?.url,
        // so without this the detail sheet would miss the podcast name row.
        let transientPodcast = Podcast(
            url: item.podcastUrl,
            title: item.podcastTitle,
            logoUrl: item.artworkUrl,
            author: item.podcastAuthor
        )
        
        let episode = Episode(
            guid: item.id,
            title: item.title,
            episodeDescription: item.episodeDescription,
            audioUrl: item.audioUrl,
            pubDate: item.pubDate,
            imageUrl: item.artworkUrl,
            durationSeconds: item.durationSeconds,
            chaptersUrl: item.chaptersUrl,
            transcriptUrl: item.transcriptUrl,
            podcast: transientPodcast
        )
        episode.listenedSeconds = item.positionSeconds
        episode.chaptersJSON = item.chaptersJSON
        // Note: The transient podcast is NOT in subscriptions, so EpisodeDetailSheet's
        // findSubscribedPodcast will return nil — the podcast title shows as plain text
        // (not a navigation link), which is correct for non-subscribed podcasts.
        return episode
    }
}

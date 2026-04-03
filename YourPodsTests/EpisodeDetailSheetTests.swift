import XCTest
@testable import YourPods

/// Tests for the podcast URL resolution logic used by EpisodeDetailSheet's "Mark as Played" button.
/// The button must always resolve a valid podcastUrl — even when the Episode's
/// podcast relationship is nil (SwiftData lazy loading edge case).
final class EpisodeDetailSheetTests: XCTestCase {
    
    // MARK: - resolvePodcastUrl Tests
    
    func test_resolvePodcastUrl_returnsEpisodePodcastUrl_whenAvailable() {
        // Given: an episode whose podcast relationship provides a URL
        let podcastUrl = "https://example.com/feed"
        let result = EpisodeDetailSheetHelper.resolvePodcastUrl(
            episodePodcastUrl: podcastUrl,
            currentItemPodcastUrl: "https://other.com/feed",
            episodeGuid: "ep-1",
            subscriptions: []
        )
        
        // Then: should use the episode's own podcastUrl
        XCTAssertEqual(result, podcastUrl)
    }
    
    func test_resolvePodcastUrl_fallsBackToCurrentItem_whenEpisodePodcastUrlIsNil() {
        // Given: episode.podcastUrl is nil, but the currently playing item has a podcastUrl
        let currentUrl = "https://example.com/current-feed"
        let result = EpisodeDetailSheetHelper.resolvePodcastUrl(
            episodePodcastUrl: nil,
            currentItemPodcastUrl: currentUrl,
            episodeGuid: "ep-1",
            subscriptions: []
        )
        
        // Then: should fall back to the current item's podcastUrl
        XCTAssertEqual(result, currentUrl)
    }
    
    func test_resolvePodcastUrl_returnsNil_whenAllSourcesUnavailable() {
        // Given: no podcast URL from any source
        let result = EpisodeDetailSheetHelper.resolvePodcastUrl(
            episodePodcastUrl: nil,
            currentItemPodcastUrl: nil,
            episodeGuid: "ep-1",
            subscriptions: []
        )
        
        // Then: should return nil
        XCTAssertNil(result)
    }
}

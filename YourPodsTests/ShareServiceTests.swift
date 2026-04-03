import XCTest
@testable import YourPods

/// Tests for ShareService's content-building logic.
final class ShareServiceTests: XCTestCase {
    
    // MARK: - Share Episode
    
    func test_shareEpisode_usesEpisodeLinkWhenAvailable() {
        let items = ShareService.shareEpisode(
            title: "My Episode",
            podcastTitle: "My Podcast",
            link: "https://example.com/ep1",
            audioUrl: "https://cdn.example.com/ep1.mp3"
        )
        
        XCTAssertFalse(items.isEmpty, "Share items should not be empty")
        
        let text = items.compactMap { $0 as? String }.joined(separator: " ")
        XCTAssertTrue(text.contains("My Episode"), "Share text should contain episode title")
        
        let urls = items.compactMap { $0 as? URL }
        XCTAssertTrue(urls.contains(URL(string: "https://example.com/ep1")!),
                       "Should prefer episode link URL over audioUrl")
    }
    
    func test_shareEpisode_fallsBackToAudioUrl() {
        let items = ShareService.shareEpisode(
            title: "No Link Episode",
            podcastTitle: "My Podcast",
            link: nil,
            audioUrl: "https://cdn.example.com/ep1.mp3"
        )
        
        XCTAssertFalse(items.isEmpty, "Share items should not be empty")
        
        let urls = items.compactMap { $0 as? URL }
        XCTAssertTrue(urls.contains(URL(string: "https://cdn.example.com/ep1.mp3")!),
                       "Should fall back to audioUrl when link is nil")
    }
    
    func test_shareEpisode_missingAllUrls() {
        let items = ShareService.shareEpisode(
            title: "Orphan Episode",
            podcastTitle: "My Podcast",
            link: nil,
            audioUrl: nil
        )
        
        // Should still return text content even without URLs
        XCTAssertFalse(items.isEmpty, "Share items should contain at least the text even without URLs")
        let text = items.compactMap { $0 as? String }.joined(separator: " ")
        XCTAssertTrue(text.contains("Orphan Episode"), "Share text should still contain the episode title")
    }
    
    // MARK: - Share Podcast
    
    func test_sharePodcast_usesWebsiteWhenAvailable() {
        let items = ShareService.sharePodcast(
            title: "My Podcast",
            website: "https://mypodcast.com",
            feedUrl: "https://feeds.example.com/mypodcast"
        )
        
        XCTAssertFalse(items.isEmpty, "Share items should not be empty")
        
        let urls = items.compactMap { $0 as? URL }
        XCTAssertTrue(urls.contains(URL(string: "https://mypodcast.com")!),
                       "Should prefer website URL over feed URL")
    }
    
    func test_sharePodcast_fallsBackToFeedUrl() {
        let items = ShareService.sharePodcast(
            title: "My Podcast",
            website: nil,
            feedUrl: "https://feeds.example.com/mypodcast"
        )
        
        XCTAssertFalse(items.isEmpty, "Share items should not be empty")
        
        let urls = items.compactMap { $0 as? URL }
        XCTAssertTrue(urls.contains(URL(string: "https://feeds.example.com/mypodcast")!),
                       "Should fall back to feed URL when website is nil")
    }
    
    // MARK: - Share Position
    
    func test_sharePosition_includesFormattedTimestamp() {
        let items = ShareService.sharePosition(
            episodeTitle: "Deep Dive",
            podcastTitle: "Tech Talk",
            position: 754, // 12:34
            link: "https://example.com/ep1",
            audioUrl: nil
        )
        
        XCTAssertFalse(items.isEmpty, "Share items should not be empty")
        
        let text = items.compactMap { $0 as? String }.joined(separator: " ")
        XCTAssertTrue(text.contains("12:34"), "Share text should contain formatted timestamp 12:34")
        XCTAssertTrue(text.contains("Deep Dive"), "Share text should contain episode title")
    }
    
    func test_sharePosition_includesEpisodeLink() {
        let items = ShareService.sharePosition(
            episodeTitle: "Deep Dive",
            podcastTitle: "Tech Talk",
            position: 60,
            link: "https://example.com/ep1",
            audioUrl: nil
        )
        
        let urls = items.compactMap { $0 as? URL }
        XCTAssertTrue(urls.contains(URL(string: "https://example.com/ep1")!),
                       "Position share should include episode link URL")
    }
}

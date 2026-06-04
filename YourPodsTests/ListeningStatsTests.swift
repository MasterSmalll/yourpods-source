import XCTest
@testable import YourPods

// MARK: - Listening Stats Tests

/// Tests ListeningStatsService.computeStats — pure logic, no side effects.
final class ListeningStatsTests: XCTestCase {
    
    func test_computeStats_emptyActions_returnsEmpty() {
        let stats = ListeningStatsService.computeStats(actions: [], subscriptions: [])
        XCTAssertEqual(stats.totalListeningSeconds, 0)
        XCTAssertEqual(stats.episodesCompleted, 0)
    }
    
    func test_computeStats_singleEpisode_calculatesListeningTime() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 600,
            started: 0,
            total: 3600,
            device: "test"
        )
        
        let stats = ListeningStatsService.computeStats(actions: [action], subscriptions: [])
        XCTAssertEqual(stats.totalListeningSeconds, 600,
                       "Should compute 600s of listening (position 600 - started 0)")
    }
    
    func test_computeStats_completedEpisode_incrementsCount() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 3500,  // >= 95% of 3600
            started: 0,
            total: 3600,
            device: "test"
        )
        
        let stats = ListeningStatsService.computeStats(actions: [action], subscriptions: [])
        XCTAssertEqual(stats.episodesCompleted, 1,
                       "Episode at >=95% should count as completed")
    }
    
    func test_computeStats_partialEpisode_notCompleted() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1800,  // 50% of 3600
            started: 0,
            total: 3600,
            device: "test"
        )
        
        let stats = ListeningStatsService.computeStats(actions: [action], subscriptions: [])
        XCTAssertEqual(stats.episodesCompleted, 0,
                       "Episode at 50% should not count as completed")
    }
    
    func test_computeStats_topPodcasts_sortedByTime() {
        let actions = [
            EpisodeAction(podcast: "feed-a", episode: "ep1", guid: "g1", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 100, started: 0, total: 300, device: "t"),
            EpisodeAction(podcast: "feed-b", episode: "ep2", guid: "g2", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 500, started: 0, total: 600, device: "t"),
        ]
        
        let stats = ListeningStatsService.computeStats(actions: actions, subscriptions: [])
        XCTAssertEqual(stats.topPodcasts.first?.podcastUrl, "feed-b",
                       "Top podcast should be the one with most listening time")
    }
    
    // MARK: - Unknown Podcast Bug (gPodder sync)
    
    func test_computeStats_excludesActionsFromUnsubscribedPodcasts() {
        // Simulate gPodder sync: actionMap contains actions from podcasts the user
        // is no longer subscribed to. These should NOT appear in stats.
        let subscribedUrl = "https://example.com/subscribed-feed"
        let unsubscribedUrl = "https://example.com/unsubscribed-feed"
        
        let actions = [
            // Action from a podcast the user IS subscribed to
            EpisodeAction(podcast: subscribedUrl, episode: "ep1.mp3", guid: "sub-ep1", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 1200, started: 0, total: 3600, device: "t"),
            // Action from a podcast the user is NOT subscribed to (e.g., unsubscribed or from another device)
            EpisodeAction(podcast: unsubscribedUrl, episode: "ep2.mp3", guid: "unsub-ep1", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 900, started: 0, total: 3600, device: "t"),
        ]
        
        let subscribedPodcast = Podcast(url: subscribedUrl, title: "My Subscribed Podcast", logoUrl: "https://example.com/logo.jpg")
        
        let stats = ListeningStatsService.computeStats(actions: actions, subscriptions: [subscribedPodcast])
        
        // Only the subscribed podcast should appear
        XCTAssertEqual(stats.topPodcasts.count, 1,
                       "Only subscribed podcasts should appear in stats")
        XCTAssertEqual(stats.topPodcasts.first?.podcastTitle, "My Subscribed Podcast",
                       "Stats should show the subscribed podcast title, not 'Unknown Podcast'")
        XCTAssertNil(stats.podcastBreakdowns[unsubscribedUrl],
                     "Unsubscribed podcast should not appear in breakdowns")
        
        // Total listening time should only count the subscribed podcast
        XCTAssertEqual(stats.totalListeningSeconds, 1200,
                       "Total listening should only count subscribed podcast (1200s), not include unsubscribed (900s)")
    }
    
    func test_computeStats_noSubscriptions_returnsEmpty() {
        // When subscriptions are provided but none match the actions,
        // stats should be empty (not "Unknown Podcast" entries)
        let actions = [
            EpisodeAction(podcast: "https://orphaned-feed.com/rss", episode: "ep1.mp3", guid: "orphan1", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 600, started: 0, total: 3600, device: "t"),
        ]
        
        let subscribedPodcast = Podcast(url: "https://different-feed.com/rss", title: "Different Podcast")
        let stats = ListeningStatsService.computeStats(actions: actions, subscriptions: [subscribedPodcast])
        
        XCTAssertEqual(stats.topPodcasts.count, 0,
                       "No podcasts should appear when no actions match subscriptions")
        XCTAssertEqual(stats.totalListeningSeconds, 0,
                       "Listening time should be zero when no actions match subscriptions")
    }
}

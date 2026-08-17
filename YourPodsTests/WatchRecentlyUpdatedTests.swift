import XCTest
import SwiftData
import WatchConnectivity
@testable import YourPods

/// Tests for the Recently Updated watch feature — verifies the iOS→Watch data pipeline
/// sends correct episode data for the watch's Recently Updated section.
@MainActor
final class WatchRecentlyUpdatedTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var watchService: WatchService!
    private var mockSession: MockWatchSession!
    
    private let testProfileId = "test-profile-watch-recent"
    
    override func setUp() {
        super.setUp()
        clearTestDefaults()
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        
        manager = PodcastManager(modelContext: context)
        
        watchService = WatchService.shared
        mockSession = MockWatchSession()
        watchService.session = mockSession
        watchService.podcastManager = manager
    }
    
    override func tearDown() {
        clearTestDefaults()
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    // MARK: - Helpers
    
    @discardableResult
    private func insertPodcast(
        url: String = "https://example.com/feed",
        title: String = "Test Podcast",
        logoUrl: String? = nil,
        episodes: [(guid: String, title: String, pubDate: Date?, isPlayed: Bool, isInteracted: Bool, audioUrl: String?)] = []
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title, logoUrl: logoUrl)
        context.insert(podcast)
        
        for ep in episodes {
            let episode = Episode(
                guid: ep.guid,
                title: ep.title,
                audioUrl: ep.audioUrl ?? "https://example.com/\(ep.guid).mp3",
                pubDate: ep.pubDate,
                durationSeconds: 3600,
                podcast: podcast
            )
            episode.isPlayed = ep.isPlayed
            episode.isInteracted = ep.isInteracted
            context.insert(episode)
        }
        
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        
        return podcast
    }
    
    // MARK: - Tests
    
    func test_sendRecentEpisodes_sendsMaximum10Episodes() {
        // GIVEN: A podcast with 15 unplayed episodes
        var episodes: [(guid: String, title: String, pubDate: Date?, isPlayed: Bool, isInteracted: Bool, audioUrl: String?)] = []
        for i in 1...15 {
            episodes.append((
                guid: "ep-\(i)",
                title: "Episode \(i)",
                pubDate: Date().addingTimeInterval(TimeInterval(-i * 3600)),
                isPlayed: false,
                isInteracted: false,
                audioUrl: "https://example.com/\(i).mp3"
            ))
        }
        insertPodcast(episodes: episodes)
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN
        guard let recentEpisodes = mockSession.lastSentMessage?["recent_episodes"] as? [[String: Any]] else {
            XCTFail("recent_episodes key missing from sent message")
            return
        }
        
        XCTAssertEqual(recentEpisodes.count, 10, "Should limit to 10 episodes for watch resource constraints")
    }
    
    func test_sendRecentEpisodes_sortedByPubDateDescending() {
        // GIVEN: Episodes with known dates
        insertPodcast(episodes: [
            (guid: "old", title: "Old Episode", pubDate: Date().addingTimeInterval(-86400), isPlayed: false, isInteracted: false, audioUrl: nil),
            (guid: "new", title: "New Episode", pubDate: Date().addingTimeInterval(-3600), isPlayed: false, isInteracted: false, audioUrl: nil),
            (guid: "mid", title: "Mid Episode", pubDate: Date().addingTimeInterval(-43200), isPlayed: false, isInteracted: false, audioUrl: nil),
        ])
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN: Newest first
        guard let recentEpisodes = mockSession.lastSentMessage?["recent_episodes"] as? [[String: Any]] else {
            XCTFail("recent_episodes key missing from sent message")
            return
        }
        
        XCTAssertEqual(recentEpisodes.count, 3)
        XCTAssertEqual(recentEpisodes[0]["guid"] as? String, "new")
        XCTAssertEqual(recentEpisodes[1]["guid"] as? String, "mid")
        XCTAssertEqual(recentEpisodes[2]["guid"] as? String, "old")
    }
    
    func test_sendRecentEpisodes_excludesPlayedEpisodes() {
        // GIVEN: A mix of played and unplayed episodes
        insertPodcast(episodes: [
            (guid: "played", title: "Played Episode", pubDate: Date(), isPlayed: true, isInteracted: false, audioUrl: nil),
            (guid: "unplayed", title: "Unplayed Episode", pubDate: Date(), isPlayed: false, isInteracted: false, audioUrl: nil),
        ])
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN: Only unplayed episodes
        guard let recentEpisodes = mockSession.lastSentMessage?["recent_episodes"] as? [[String: Any]] else {
            XCTFail("recent_episodes key missing from sent message")
            return
        }
        
        XCTAssertEqual(recentEpisodes.count, 1)
        XCTAssertEqual(recentEpisodes[0]["guid"] as? String, "unplayed")
    }
    
    func test_sendRecentEpisodes_excludesInteractedEpisodes() {
        // GIVEN: An interacted episode
        insertPodcast(episodes: [
            (guid: "interacted", title: "Interacted Episode", pubDate: Date(), isPlayed: false, isInteracted: true, audioUrl: nil),
            (guid: "fresh", title: "Fresh Episode", pubDate: Date(), isPlayed: false, isInteracted: false, audioUrl: nil),
        ])
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN
        guard let recentEpisodes = mockSession.lastSentMessage?["recent_episodes"] as? [[String: Any]] else {
            XCTFail("recent_episodes key missing from sent message")
            return
        }
        
        XCTAssertEqual(recentEpisodes.count, 1)
        XCTAssertEqual(recentEpisodes[0]["guid"] as? String, "fresh")
    }
    
    func test_sendRecentEpisodes_includesPodcastMetadata() {
        // GIVEN: An episode from a podcast with artwork
        insertPodcast(
            title: "Metadata Pod",
            logoUrl: "https://example.com/podcast-art.jpg",
            episodes: [
                (guid: "meta-ep", title: "Meta Episode", pubDate: Date(), isPlayed: false, isInteracted: false, audioUrl: "https://example.com/meta.mp3"),
            ]
        )
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN: Contains podcast metadata
        guard let recentEpisodes = mockSession.lastSentMessage?["recent_episodes"] as? [[String: Any]],
              let first = recentEpisodes.first else {
            XCTFail("recent_episodes key missing from sent message")
            return
        }
        
        XCTAssertEqual(first["podcastTitle"] as? String, "Metadata Pod")
        XCTAssertEqual(first["podcastArtUri"] as? String, "https://example.com/podcast-art.jpg")
        XCTAssertNotNil(first["pubDate"] as? String, "pubDate should be included as ISO8601 string")
    }
    
    func test_sendRecentEpisodes_crossPodcast() {
        // GIVEN: Episodes from multiple podcasts
        insertPodcast(
            url: "https://example.com/a",
            title: "Podcast A",
            episodes: [
                (guid: "a-ep", title: "Episode from A", pubDate: Date().addingTimeInterval(-3600), isPlayed: false, isInteracted: false, audioUrl: nil),
            ]
        )
        insertPodcast(
            url: "https://example.com/b",
            title: "Podcast B",
            episodes: [
                (guid: "b-ep", title: "Episode from B", pubDate: Date(), isPlayed: false, isInteracted: false, audioUrl: nil),
            ]
        )
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN: Contains episodes from both podcasts, sorted by date
        guard let recentEpisodes = mockSession.lastSentMessage?["recent_episodes"] as? [[String: Any]] else {
            XCTFail("recent_episodes key missing from sent message")
            return
        }
        
        XCTAssertEqual(recentEpisodes.count, 2)
        XCTAssertEqual(recentEpisodes[0]["guid"] as? String, "b-ep", "Newest episode should be first")
        XCTAssertEqual(recentEpisodes[0]["podcastTitle"] as? String, "Podcast B")
        XCTAssertEqual(recentEpisodes[1]["guid"] as? String, "a-ep")
        XCTAssertEqual(recentEpisodes[1]["podcastTitle"] as? String, "Podcast A")
    }
    
    func test_sendRecentEpisodes_notSentWhenUnpaired() {
        // GIVEN: Watch is not paired
        mockSession.isPaired = false
        
        insertPodcast(episodes: [
            (guid: "ep", title: "Episode", pubDate: Date(), isPlayed: false, isInteracted: false, audioUrl: nil),
        ])
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN: No message sent
        XCTAssertNil(mockSession.lastSentMessage, "Should not send when watch is unpaired")
    }
    
    func test_sendRecentEpisodes_notSentWhenUnreachable() {
        // GIVEN: Watch is not reachable
        mockSession.isReachable = false
        
        insertPodcast(episodes: [
            (guid: "ep", title: "Episode", pubDate: Date(), isPlayed: false, isInteracted: false, audioUrl: nil),
        ])
        
        // WHEN
        watchService.sendRecentEpisodes()
        
        // THEN: No message sent
        XCTAssertNil(mockSession.lastSentMessage, "Should not send when watch is unreachable")
    }
}

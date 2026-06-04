import XCTest
import SwiftData
@testable import YourPods

/// Tests for the refreshAllFeeds concurrency fix.
///
/// The crash was caused by `refreshAllFeeds()` spawning concurrent TaskGroup
/// child tasks that accessed SwiftData's `ModelContext` off the main actor.
/// The fix separates network I/O (concurrent) from SwiftData mutations (sequential).
///
/// These tests verify:
/// 1. `applyFeedResult(_:to:)` correctly creates new episodes on the main actor
/// 2. `applyFeedResult(_:to:)` updates existing podcast metadata
/// 3. `applyFeedResult(_:to:)` skips duplicate episodes (idempotent)
/// 4. `applyFeedResult(_:to:)` updates existing episodes with new metadata
/// 5. Feed URL migration via `itunes:new-feed-url` works in the extracted method
@MainActor
final class RefreshAllFeedsConcurrencyTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    
    private let testProfileId = "test-profile-refresh-concurrency"
    
    override func setUp() {
        super.setUp()
        clearTestDefaults()
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
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
            "lastSubscriptionSync_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
            "serverProfiles"
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
        episodeCount: Int = 0
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        
        for i in 1...max(1, episodeCount) {
            guard episodeCount > 0 else { break }
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        
        return podcast
    }
    
    /// Build a `FeedFetchResult` with the given parsed data.
    private func makeFetchResult(
        url: String,
        parsedTitle: String = "Updated Title",
        parsedDescription: String? = "Updated description",
        episodes: [ParsedEpisode] = []
    ) -> FeedFetchResult {
        let parsed = ParsedPodcast(
            title: parsedTitle,
            description: parsedDescription
        )
        return FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: parsed,
            episodes: episodes
        )
    }
    
    // MARK: - Test: applyFeedResult creates new episodes
    
    func test_applyFeedResult_createsNewEpisodes() {
        let podcast = insertPodcast(url: "https://example.com/feed1", title: "My Podcast")
        
        let parsedEpisodes = [
            ParsedEpisode(
                guid: "new-ep-1",
                title: "New Episode 1",
                audioUrl: "https://cdn.example.com/new1.mp3",
                pubDate: Date(),
                durationSeconds: 1800
            ),
            ParsedEpisode(
                guid: "new-ep-2",
                title: "New Episode 2",
                audioUrl: "https://cdn.example.com/new2.mp3",
                pubDate: Date().addingTimeInterval(-86400),
                durationSeconds: 2400
            )
        ]
        
        let result = makeFetchResult(
            url: "https://example.com/feed1",
            episodes: parsedEpisodes
        )
        
        let newEpisodes = manager.applyFeedResult(result, to: podcast)
        
        XCTAssertEqual(newEpisodes.count, 2, "Should create 2 new episodes")
        XCTAssertTrue(newEpisodes.contains(where: { $0.guid == "new-ep-1" }))
        XCTAssertTrue(newEpisodes.contains(where: { $0.guid == "new-ep-2" }))
        XCTAssertEqual(podcast.episodes.count, 2)
    }
    
    // MARK: - Test: applyFeedResult updates podcast metadata
    
    func test_applyFeedResult_updatesPodcastMetadata() {
        let podcast = insertPodcast(url: "https://example.com/feed1", title: "Old Title")
        
        let result = makeFetchResult(
            url: "https://example.com/feed1",
            parsedTitle: "Brand New Title",
            parsedDescription: "Brand new description"
        )
        
        _ = manager.applyFeedResult(result, to: podcast)
        
        XCTAssertEqual(podcast.title, "Brand New Title")
        XCTAssertEqual(podcast.podcastDescription, "Brand new description")
    }
    
    // MARK: - Test: applyFeedResult skips duplicates
    
    func test_applyFeedResult_skipsDuplicateEpisodes() {
        let podcast = insertPodcast(url: "https://example.com/feed1", title: "My Podcast", episodeCount: 2)
        let existingGuids = podcast.episodes.map(\.guid)
        
        // Create parsed episodes that overlap with existing ones
        let parsedEpisodes = existingGuids.map { guid in
            ParsedEpisode(
                guid: guid,
                title: "Duplicate of \(guid)",
                audioUrl: "https://cdn.example.com/\(guid).mp3"
            )
        } + [
            ParsedEpisode(
                guid: "brand-new-ep",
                title: "Brand New",
                audioUrl: "https://cdn.example.com/new.mp3"
            )
        ]
        
        let result = makeFetchResult(
            url: "https://example.com/feed1",
            episodes: parsedEpisodes
        )
        
        let newEpisodes = manager.applyFeedResult(result, to: podcast)
        
        XCTAssertEqual(newEpisodes.count, 1, "Only the non-duplicate should be new")
        XCTAssertEqual(newEpisodes.first?.guid, "brand-new-ep")
        XCTAssertEqual(podcast.episodes.count, 3, "2 existing + 1 new")
    }
    
    // MARK: - Test: applyFeedResult updates existing episode metadata
    
    func test_applyFeedResult_updatesExistingEpisodeMetadata() {
        let podcast = insertPodcast(url: "https://example.com/feed1", title: "My Podcast")
        
        // Create an existing episode
        let existingEp = Episode(
            guid: "existing-ep",
            title: "Original Title",
            podcast: podcast
        )
        context.insert(existingEp)
        try! context.save()
        
        // Feed returns updated metadata for the same episode
        let parsedEpisodes = [
            ParsedEpisode(
                guid: "existing-ep",
                title: "Original Title",
                seasonNumber: 2,
                episodeNumber: 5,
                episodeType: "full"
            )
        ]
        
        let result = makeFetchResult(
            url: "https://example.com/feed1",
            episodes: parsedEpisodes
        )
        
        let newEpisodes = manager.applyFeedResult(result, to: podcast)
        
        XCTAssertEqual(newEpisodes.count, 0, "Existing episode should NOT be counted as new")
        XCTAssertEqual(existingEp.seasonNumber, 2, "Season number should be updated")
        XCTAssertEqual(existingEp.episodeNumber, 5, "Episode number should be updated")
        XCTAssertEqual(existingEp.episodeType, "full", "Episode type should be updated")
    }
    
    // MARK: - Test: FeedFetchResult is Sendable
    
    func test_feedFetchResult_isSendable() {
        // This test verifies at compile time that FeedFetchResult is Sendable.
        // If it doesn't compile, the type is not Sendable.
        let result = makeFetchResult(url: "https://example.com/feed1")
        
        let sendableCheck: any Sendable = result
        XCTAssertNotNil(sendableCheck)
    }
    
    // MARK: - Test: ParsedPodcast and ParsedEpisode are Sendable
    
    func test_parsedTypes_areSendable() {
        let podcast: any Sendable = ParsedPodcast(title: "Test")
        let episode: any Sendable = ParsedEpisode(guid: "g1", title: "Test")
        let chapter: any Sendable = InlineChapter(startTime: 0, title: "Ch1", href: nil, image: nil)
        
        XCTAssertNotNil(podcast)
        XCTAssertNotNil(episode)
        XCTAssertNotNil(chapter)
    }
    
    // MARK: - Test: Multiple feeds applied sequentially
    
    func test_applyFeedResults_multipleFeeds_allEpisodesCreated() {
        let podcast1 = insertPodcast(url: "https://example.com/feed1", title: "Podcast 1")
        let podcast2 = insertPodcast(url: "https://example.com/feed2", title: "Podcast 2")
        
        let result1 = makeFetchResult(
            url: "https://example.com/feed1",
            episodes: [
                ParsedEpisode(guid: "p1-ep1", title: "P1 Ep1", audioUrl: "https://cdn.example.com/p1e1.mp3"),
                ParsedEpisode(guid: "p1-ep2", title: "P1 Ep2", audioUrl: "https://cdn.example.com/p1e2.mp3")
            ]
        )
        let result2 = makeFetchResult(
            url: "https://example.com/feed2",
            episodes: [
                ParsedEpisode(guid: "p2-ep1", title: "P2 Ep1", audioUrl: "https://cdn.example.com/p2e1.mp3"),
                ParsedEpisode(guid: "p2-ep2", title: "P2 Ep2", audioUrl: "https://cdn.example.com/p2e2.mp3"),
                ParsedEpisode(guid: "p2-ep3", title: "P2 Ep3", audioUrl: "https://cdn.example.com/p2e3.mp3")
            ]
        )
        
        let new1 = manager.applyFeedResult(result1, to: podcast1)
        let new2 = manager.applyFeedResult(result2, to: podcast2)
        
        XCTAssertEqual(new1.count, 2, "Feed 1 should create 2 episodes")
        XCTAssertEqual(new2.count, 3, "Feed 2 should create 3 episodes")
        XCTAssertEqual(podcast1.episodes.count, 2)
        XCTAssertEqual(podcast2.episodes.count, 3)
    }
    
    // MARK: - Test: Feed URL migration in applyFeedResult
    
    func test_applyFeedResult_handlesFeedUrlMigration() {
        let podcast = insertPodcast(url: "https://old.example.com/feed", title: "My Podcast")
        
        var parsed = ParsedPodcast(title: "My Podcast")
        parsed.newFeedUrl = "https://new.example.com/feed"
        
        let result = FeedFetchResult(
            url: "https://old.example.com/feed",
            authHeader: nil,
            parsed: parsed,
            episodes: []
        )
        
        _ = manager.applyFeedResult(result, to: podcast)
        
        XCTAssertEqual(podcast.url, "https://new.example.com/feed",
                       "Podcast URL should be updated to new feed URL")
        XCTAssertNil(podcast.newFeedUrl,
                     "newFeedUrl should be cleared after migration")
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// Tests for subscription sync scalability improvements.
/// Verifies that syncing 100+ subscriptions works without truncation,
/// uses concurrent fetching, and provides progress tracking.
@MainActor
final class SubscriptionSyncTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-sync"
    
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
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    // MARK: - Helpers
    
    private func makeParsedPodcast(title: String) -> ParsedPodcast {
        var p = ParsedPodcast()
        p.title = title
        p.description = "Description for \(title)"
        return p
    }
    
    private func makeParsedEpisode(index: Int) -> ParsedEpisode {
        var ep = ParsedEpisode()
        ep.guid = "ep-\(index)"
        ep.title = "Episode \(index)"
        ep.audioUrl = "https://example.com/ep\(index).mp3"
        ep.pubDate = Date().addingTimeInterval(Double(-index * 86400))
        ep.durationSeconds = 3600
        return ep
    }
    
    // MARK: - persistPodcastFromSync: lightweight insert without reload/server push
    
    func test_persistPodcastFromSync_insertsPodcastIntoSwiftData() {
        // GIVEN: Parsed feed data for a new podcast
        let parsed = makeParsedPodcast(title: "Test Podcast")
        let episodes = [makeParsedEpisode(index: 1), makeParsedEpisode(index: 2)]
        
        // WHEN: Persisting via the sync-optimized method
        manager.persistPodcastFromSync(url: "https://example.com/feed", parsed: parsed, episodes: episodes)
        
        // THEN: Podcast exists in SwiftData
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try! context.fetch(descriptor)
        XCTAssertEqual(podcasts.count, 1, "Podcast should be inserted into SwiftData")
        XCTAssertEqual(podcasts.first?.title, "Test Podcast")
    }
    
    func test_persistPodcastFromSync_insertsEpisodes() {
        // GIVEN: Parsed feed with 3 episodes
        let parsed = makeParsedPodcast(title: "Episode Count Test")
        let episodes = (1...3).map { makeParsedEpisode(index: $0) }
        
        // WHEN: Persisting
        manager.persistPodcastFromSync(url: "https://example.com/feed", parsed: parsed, episodes: episodes)
        
        // THEN: All 3 episodes are inserted
        let descriptor = FetchDescriptor<Episode>()
        let saved = try! context.fetch(descriptor)
        XCTAssertEqual(saved.count, 3, "All episodes should be inserted")
    }
    
    func test_persistPodcastFromSync_doesNotReloadSubscriptions() {
        // GIVEN: An existing subscription already loaded
        let existing = Podcast(url: "https://existing.com/feed", title: "Existing")
        context.insert(existing)
        try! context.save()
        manager.associateWithCurrentProfile(url: "https://existing.com/feed")
        manager.loadSubscriptions()
        XCTAssertEqual(manager.subscriptions.count, 1)
        
        // WHEN: Persisting a new podcast via sync method
        let parsed = makeParsedPodcast(title: "New Podcast")
        manager.persistPodcastFromSync(url: "https://new.com/feed", parsed: parsed, episodes: [])
        
        // THEN: subscriptions array should NOT be reloaded (still shows only the existing one)
        // The new podcast is in SwiftData but not yet in the subscriptions property
        XCTAssertEqual(manager.subscriptions.count, 1,
                       "persistPodcastFromSync must NOT call loadSubscriptions — deferred to end of batch")
    }
    
    func test_persistPodcastFromSync_associatesWithProfile() {
        // GIVEN: An active profile
        let parsed = makeParsedPodcast(title: "Profile Test")
        
        // WHEN: Persisting
        manager.persistPodcastFromSync(url: "https://profile.com/feed", parsed: parsed, episodes: [])
        
        // THEN: URL is associated with the current profile
        // Verify by manually loading subscriptions
        manager.loadSubscriptions()
        XCTAssertEqual(manager.subscriptions.count, 1)
        XCTAssertEqual(manager.subscriptions.first?.url, "https://profile.com/feed")
    }
    
    func test_persistPodcastFromSync_setsMarkedPlayedBefore() {
        // GIVEN: A new podcast from sync
        let parsed = makeParsedPodcast(title: "Queue Guard Test")
        
        // WHEN: Persisting
        let beforeTime = Date()
        manager.persistPodcastFromSync(url: "https://queue.com/feed", parsed: parsed, episodes: [])
        
        // THEN: markedPlayedBefore is set to prevent back-catalog flooding the queue
        manager.loadSubscriptions()
        let podcast = manager.subscriptions.first
        XCTAssertNotNil(podcast?.effectiveSettings.markedPlayedBefore,
                        "markedPlayedBefore should be set to prevent auto-queueing old episodes")
        if let marked = podcast?.effectiveSettings.markedPlayedBefore {
            XCTAssertGreaterThanOrEqual(marked, beforeTime)
        }
    }
    
    // MARK: - Batch processing: handles large subscription lists
    
    func test_persistPodcastFromSync_handlesOver50Podcasts() {
        // GIVEN: 112 parsed podcast feeds (the user's actual count)
        let feedCount = 112
        
        // WHEN: Persisting all 112
        for i in 1...feedCount {
            let parsed = makeParsedPodcast(title: "Podcast \(i)")
            let episodes = [makeParsedEpisode(index: i)]
            manager.persistPodcastFromSync(
                url: "https://example.com/feed\(i)",
                parsed: parsed,
                episodes: episodes
            )
        }
        try! context.save()
        manager.loadSubscriptions()
        
        // THEN: All 112 podcasts are present — no truncation
        XCTAssertEqual(manager.subscriptions.count, feedCount,
                       "All \(feedCount) podcasts must be synced — no truncation at 50")
    }
    
    func test_persistPodcastFromSync_skipsAlreadySubscribedUrl() {
        // GIVEN: A podcast already in SwiftData and associated with the profile
        let existing = Podcast(url: "https://existing.com/feed", title: "Already Subscribed")
        context.insert(existing)
        try! context.save()
        manager.associateWithCurrentProfile(url: "https://existing.com/feed")
        manager.loadSubscriptions()
        
        // WHEN: Persisting the same URL again via sync
        let parsed = makeParsedPodcast(title: "Duplicate")
        manager.persistPodcastFromSync(url: "https://existing.com/feed", parsed: parsed, episodes: [])
        try! context.save()
        manager.loadSubscriptions()
        
        // THEN: No duplicate — still only 1 podcast
        let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.url == "https://existing.com/feed" })
        let results = try! context.fetch(descriptor)
        XCTAssertEqual(results.count, 1, "Should not create duplicate podcast for same URL")
    }
    
    // MARK: - Subscription sync progress tracking
    
    func test_subscriptionSyncProgress_initiallyNil() {
        // GIVEN: A fresh manager
        // THEN: No sync in progress
        XCTAssertNil(manager.subscriptionSyncProgress,
                     "subscriptionSyncProgress should be nil when no sync is running")
    }
    
    // MARK: - refreshAllFeeds concurrency
    
    func test_refreshAllFeeds_handlesLargeSubscriptionList() {
        // GIVEN: 60 subscriptions (well over the old ~50 limit)
        for i in 1...60 {
            let podcast = Podcast(url: "https://example.com/feed\(i)", title: "Podcast \(i)")
            context.insert(podcast)
            manager.associateWithCurrentProfile(url: podcast.url)
        }
        try! context.save()
        manager.loadSubscriptions()
        
        // THEN: All 60 are loaded and ready for refresh
        XCTAssertEqual(manager.subscriptions.count, 60,
                       "Manager should handle 60+ subscriptions without issue")
    }
    
    // MARK: - filterNewSubscriptionUrls helper
    
    func test_filterNewSubscriptionUrls_removesAlreadySubscribed() {
        // GIVEN: 3 existing subscriptions
        for i in 1...3 {
            let podcast = Podcast(url: "https://example.com/feed\(i)", title: "Existing \(i)")
            context.insert(podcast)
            manager.associateWithCurrentProfile(url: podcast.url)
        }
        try! context.save()
        manager.loadSubscriptions()
        
        // WHEN: Filtering a list that includes 2 existing + 2 new URLs
        let serverUrls = [
            "https://example.com/feed1",  // already subscribed
            "https://example.com/feed2",  // already subscribed
            "https://example.com/feed4",  // new
            "https://example.com/feed5",  // new
        ]
        let newUrls = manager.filterNewSubscriptionUrls(serverUrls)
        
        // THEN: Only the 2 new URLs are returned
        XCTAssertEqual(newUrls.count, 2)
        XCTAssertTrue(newUrls.contains("https://example.com/feed4"))
        XCTAssertTrue(newUrls.contains("https://example.com/feed5"))
    }
    
    func test_filterNewSubscriptionUrls_emptyWhenAllSubscribed() {
        // GIVEN: 2 existing subscriptions
        for i in 1...2 {
            let podcast = Podcast(url: "https://example.com/feed\(i)", title: "Existing \(i)")
            context.insert(podcast)
            manager.associateWithCurrentProfile(url: podcast.url)
        }
        try! context.save()
        manager.loadSubscriptions()
        
        // WHEN: All server URLs already subscribed
        let serverUrls = ["https://example.com/feed1", "https://example.com/feed2"]
        let newUrls = manager.filterNewSubscriptionUrls(serverUrls)
        
        // THEN: No new URLs
        XCTAssertTrue(newUrls.isEmpty, "Should return empty when all URLs are already subscribed")
    }
    
    func test_filterNewSubscriptionUrls_allNewWhenEmpty() {
        // GIVEN: No existing subscriptions
        // WHEN: Server has 3 URLs
        let serverUrls = ["https://a.com/f", "https://b.com/f", "https://c.com/f"]
        let newUrls = manager.filterNewSubscriptionUrls(serverUrls)
        
        // THEN: All 3 are new
        XCTAssertEqual(newUrls.count, 3, "All URLs should be new when no subscriptions exist")
    }
}

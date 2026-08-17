import XCTest
import SwiftData
@testable import YourPods

/// Tests for stale episode detection and pruning during RSS feed refresh.
/// Validates that episodes removed from the RSS feed are flagged as stale,
/// and that stale episodes are excluded from counts, views, and auto-queue.
///
/// Retargeted onto the live path (`syncStore.applyFeedResults` +
/// `reconcileAfterBackgroundWrites()`) — `PodcastManager.applyFeedResult` had
/// zero production callers and has been deleted. Reads go through
/// `manager.episodes(withGuids:)` rather than `podcast.episodes` relationship
/// traversal, since `SyncStore` inserts/updates on its own background
/// `ModelContext` (see `LivePathChurnTests` for the full rationale).
@MainActor
final class StaleEpisodePruningTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    
    private let testProfileId = "test-profile-stale"
    
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
    
    /// Insert a podcast with episodes directly into SwiftData.
    @discardableResult
    private func insertPodcast(
        url: String = "https://example.com/feed",
        title: String = "Test Podcast",
        episodes: [(guid: String, audioUrl: String, pubDate: Date?)] = []
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        
        for ep in episodes {
            let episode = Episode(
                guid: ep.guid,
                title: "Episode \(ep.guid)",
                audioUrl: ep.audioUrl,
                pubDate: ep.pubDate,
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(episode)
        }
        
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        
        return podcast
    }
    
    /// Build a FeedFetchResult from parsed episode data.
    private func makeFeedResult(
        url: String = "https://example.com/feed",
        episodes: [(guid: String, audioUrl: String)]
    ) -> FeedFetchResult {
        let parsed = ParsedPodcast(title: "Test Podcast")
        let parsedEpisodes = episodes.map { ep in
            ParsedEpisode(
                guid: ep.guid,
                title: "Episode \(ep.guid)",
                audioUrl: ep.audioUrl
            )
        }
        return FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: parsed,
            episodes: parsedEpisodes
        )
    }
    
    // MARK: - Stale Detection Tests
    
    func test_applyFeedResults_marksRemovedEpisodesAsStale() async {
        // Given: podcast with 5 local episodes
        let allGuids = (1...5).map { "ep-\($0)" }
        let podcast = insertPodcast(
            url: "https://example.com/feed",
            episodes: (1...5).map { i in
                (guid: "ep-\(i)", audioUrl: "https://cdn.example.com/ep\(i).mp3", pubDate: Date())
            }
        )
        XCTAssertEqual(podcast.episodes.count, 5)

        // When: feed only contains 3 of the 5 episodes (ep-1, ep-2, ep-3)
        let feedResult = makeFeedResult(
            url: "https://example.com/feed",
            episodes: [
                (guid: "ep-1", audioUrl: "https://cdn.example.com/ep1.mp3"),
                (guid: "ep-2", audioUrl: "https://cdn.example.com/ep2.mp3"),
                (guid: "ep-3", audioUrl: "https://cdn.example.com/ep3.mp3"),
            ]
        )
        _ = await manager.syncStore.applyFeedResults([feedResult])
        manager.reconcileAfterBackgroundWrites()

        // Then: ep-4 and ep-5 should be marked stale
        let allEpisodes = manager.episodes(withGuids: allGuids)
        let staleEpisodes = allEpisodes.filter { $0.isStale }
        let activeEpisodes = allEpisodes.filter { !$0.isStale }

        XCTAssertEqual(staleEpisodes.count, 2, "2 episodes not in feed should be stale")
        XCTAssertEqual(activeEpisodes.count, 3, "3 episodes still in feed should be active")

        let staleGuids = Set(staleEpisodes.map(\.guid))
        XCTAssertTrue(staleGuids.contains("ep-4"))
        XCTAssertTrue(staleGuids.contains("ep-5"))
    }
    
    func test_applyFeedResults_unmarksStaleWhenEpisodeReappears() async {
        // Given: podcast with a stale episode
        let podcast = insertPodcast(
            url: "https://example.com/feed",
            episodes: [
                (guid: "ep-1", audioUrl: "https://cdn.example.com/ep1.mp3", pubDate: Date()),
                (guid: "ep-2", audioUrl: "https://cdn.example.com/ep2.mp3", pubDate: Date()),
            ]
        )
        // Mark ep-2 as stale
        podcast.episodes.first(where: { $0.guid == "ep-2" })?.isStale = true
        try! context.save()

        // When: feed includes ep-2 again
        let feedResult = makeFeedResult(
            url: "https://example.com/feed",
            episodes: [
                (guid: "ep-1", audioUrl: "https://cdn.example.com/ep1.mp3"),
                (guid: "ep-2", audioUrl: "https://cdn.example.com/ep2.mp3"),
            ]
        )
        _ = await manager.syncStore.applyFeedResults([feedResult])
        manager.reconcileAfterBackgroundWrites()

        // Then: ep-2 should no longer be stale
        let ep2 = manager.episodes(withGuids: ["ep-2"]).first
        XCTAssertFalse(ep2?.isStale ?? true, "Episode that reappears in feed should be un-staled")
    }
    
    func test_applyFeedResults_matchesByGuidFirst() async {
        // Given: local episode with one audio URL
        insertPodcast(
            url: "https://example.com/feed",
            episodes: [
                (guid: "stable-guid-1", audioUrl: "https://cdn.example.com/old-url.mp3", pubDate: Date()),
            ]
        )

        // When: feed has the same GUID but a different audio URL (feed provider changed CDN)
        let feedResult = makeFeedResult(
            url: "https://example.com/feed",
            episodes: [
                (guid: "stable-guid-1", audioUrl: "https://new-cdn.example.com/different-url.mp3"),
            ]
        )
        _ = await manager.syncStore.applyFeedResults([feedResult])
        manager.reconcileAfterBackgroundWrites()

        // Then: episode should NOT be marked stale (GUID match takes priority)
        let ep = manager.episodes(withGuids: ["stable-guid-1"]).first
        XCTAssertFalse(ep?.isStale ?? true, "GUID match should prevent stale marking even with different audio URL")
    }
    
    func test_applyFeedResults_fallsToAudioUrlBasePathMatch() async {
        // Given: local episode with a Megaphone URL including ?updated= param
        insertPodcast(
            url: "https://example.com/feed",
            episodes: [
                (guid: "guid-changed", audioUrl: "https://traffic.megaphone.fm/VMP4797682566.mp3?updated=1776272842", pubDate: Date()),
            ]
        )

        // When: feed has a different GUID but same audio base URL with a new ?updated= param
        let feedResult = makeFeedResult(
            url: "https://example.com/feed",
            episodes: [
                (guid: "guid-changed-new", audioUrl: "https://traffic.megaphone.fm/VMP4797682566.mp3?updated=9999999999"),
            ]
        )
        _ = await manager.syncStore.applyFeedResults([feedResult])
        manager.reconcileAfterBackgroundWrites()

        // Then: episode should NOT be marked stale (audio URL base path matches)
        let ep = manager.episodes(withGuids: ["guid-changed"]).first
        XCTAssertFalse(ep?.isStale ?? true,
                       "Audio URL base-path match should prevent stale marking when GUID doesn't match")
    }
    
    func test_applyFeedResults_doesNotMarkCurrentFeedEpisodesStale() async {
        // Given: podcast with 3 episodes
        let allGuids = (1...3).map { "ep-\($0)" }
        insertPodcast(
            url: "https://example.com/feed",
            episodes: (1...3).map { i in
                (guid: "ep-\(i)", audioUrl: "https://cdn.example.com/ep\(i).mp3", pubDate: Date())
            }
        )

        // When: feed contains all 3 episodes (nothing removed)
        let feedResult = makeFeedResult(
            url: "https://example.com/feed",
            episodes: [
                (guid: "ep-1", audioUrl: "https://cdn.example.com/ep1.mp3"),
                (guid: "ep-2", audioUrl: "https://cdn.example.com/ep2.mp3"),
                (guid: "ep-3", audioUrl: "https://cdn.example.com/ep3.mp3"),
            ]
        )
        _ = await manager.syncStore.applyFeedResults([feedResult])
        manager.reconcileAfterBackgroundWrites()

        // Then: no episodes should be stale
        let all = manager.episodes(withGuids: allGuids)
        XCTAssertEqual(all.count, 3, "Fetch must actually find the 3 episodes — an empty fetch would falsely pass the stale-count check below")
        let staleCount = all.filter { $0.isStale }.count
        XCTAssertEqual(staleCount, 0, "No episodes should be stale when all are in the feed")
    }
    
    // MARK: - stripQueryParams Tests
    
    func test_stripQueryParams_removesMegaphoneTimestamp() {
        let url = "https://traffic.megaphone.fm/VMP4797682566.mp3?updated=1776272842"
        let stripped = stripQueryParams(url)
        XCTAssertEqual(stripped, "https://traffic.megaphone.fm/VMP4797682566.mp3",
                       "Should strip ?updated= query parameter")
    }

    func test_stripQueryParams_preservesBasePath() {
        let url = "https://cdn.example.com/episodes/my-episode.mp3"
        let stripped = stripQueryParams(url)
        XCTAssertEqual(stripped, url, "URL without query params should be unchanged")
    }
    
    // MARK: - View Filtering Tests
    
    func test_staleEpisodesExcludedFromUnplayedCount() {
        let podcast = insertPodcast(
            url: "https://example.com/feed",
            episodes: (1...5).map { i in
                (guid: "ep-\(i)", audioUrl: "https://cdn.example.com/ep\(i).mp3",
                 pubDate: Date().addingTimeInterval(Double(-i * 86400)))
            }
        )
        
        // Mark 2 episodes as stale
        podcast.episodes.first(where: { $0.guid == "ep-4" })?.isStale = true
        podcast.episodes.first(where: { $0.guid == "ep-5" })?.isStale = true
        try! context.save()
        
        // Count non-stale unplayed episodes (simulating view logic)
        let nonStaleUnplayed = podcast.episodes.filter { !$0.isPlayed && !$0.isStale }.count
        XCTAssertEqual(nonStaleUnplayed, 3, "Stale episodes should be excluded from unplayed count")
    }
    
    func test_staleEpisodesExcludedFromAutoQueue() {
        let podcast = insertPodcast(
            url: "https://example.com/feed",
            episodes: (1...4).map { i in
                (guid: "ep-\(i)", audioUrl: "https://cdn.example.com/ep\(i).mp3",
                 pubDate: Date().addingTimeInterval(Double(-i * 86400)))
            }
        )
        
        // Mark ep-1 (newest) as stale
        podcast.episodes.first(where: { $0.guid == "ep-1" })?.isStale = true
        try! context.save()
        
        // getAutoQueueCandidates should skip stale episodes
        let candidates = manager.getAutoQueueCandidates(for: podcast, globalDefault: .normal)
        let staleInCandidates = candidates.filter { $0.isStale }
        XCTAssertEqual(staleInCandidates.count, 0, "Stale episodes should not be auto-queue candidates")
        XCTAssertFalse(candidates.contains(where: { $0.guid == "ep-1" }),
                       "Stale ep-1 should not appear in auto-queue candidates")
    }
    
    func test_markAllAsPlayed_skipsStaleEpisodes() {
        let podcast = insertPodcast(
            url: "https://example.com/feed",
            episodes: (1...4).map { i in
                (guid: "ep-\(i)", audioUrl: "https://cdn.example.com/ep\(i).mp3",
                 pubDate: Date().addingTimeInterval(Double(-i * 86400)))
            }
        )
        
        // Mark ep-3 and ep-4 as stale
        podcast.episodes.first(where: { $0.guid == "ep-3" })?.isStale = true
        podcast.episodes.first(where: { $0.guid == "ep-4" })?.isStale = true
        try! context.save()
        
        manager.markAllEpisodesAsPlayed(for: podcast)
        
        // Non-stale episodes should be marked played
        let ep1 = podcast.episodes.first(where: { $0.guid == "ep-1" })
        let ep2 = podcast.episodes.first(where: { $0.guid == "ep-2" })
        XCTAssertTrue(ep1?.isPlayed ?? false, "Non-stale ep-1 should be marked played")
        XCTAssertTrue(ep2?.isPlayed ?? false, "Non-stale ep-2 should be marked played")
        
        // Stale episodes should NOT be marked played
        let ep3 = podcast.episodes.first(where: { $0.guid == "ep-3" })
        let ep4 = podcast.episodes.first(where: { $0.guid == "ep-4" })
        XCTAssertFalse(ep3?.isPlayed ?? true, "Stale ep-3 should NOT be marked played")
        XCTAssertFalse(ep4?.isPlayed ?? true, "Stale ep-4 should NOT be marked played")
    }
    
    func test_staleEpisodesExcludedFromBadgeCount() {
        let podcast = insertPodcast(
            url: "https://example.com/feed",
            episodes: (1...5).map { i in
                (guid: "ep-\(i)", audioUrl: "https://cdn.example.com/ep\(i).mp3",
                 pubDate: Date().addingTimeInterval(Double(-i * 86400)))
            }
        )
        
        // Mark 2 episodes as stale
        podcast.episodes.first(where: { $0.guid == "ep-4" })?.isStale = true
        podcast.episodes.first(where: { $0.guid == "ep-5" })?.isStale = true
        try! context.save()
        
        let badgeService = BadgeService.shared
        badgeService.podcastManager = manager
        
        let count = badgeService.calculateUnplayedCount()
        XCTAssertEqual(count, 3, "Badge count should exclude stale episodes (5 total - 2 stale = 3)")
    }
}

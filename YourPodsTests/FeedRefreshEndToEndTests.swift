import XCTest
import SwiftData
@testable import YourPods

/// End-to-end test: calls `PodcastManager.refreshAllFeeds()` with a fake
/// FeedFetching implementation and verifies that new episodes are visible
/// to the main context — both via `episodes(withGuids:)` AND via the
/// `podcast.episodes` relationship traversal that the UI uses.
///
/// This catches the real-world scenario the user reports: tapping "Refresh
/// & Sync" doesn't surface new episodes.
@MainActor
final class FeedRefreshEndToEndTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var fakeFetcher: FakeFeedFetcher!

    private let testProfileId = "test-profile-e2e-refresh"

    override func setUp() {
        super.setUp()
        clearTestDefaults()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")

        fakeFetcher = FakeFeedFetcher()
        manager = PodcastManager(modelContext: context, feedFetcher: fakeFetcher)
    }

    override func tearDown() {
        clearTestDefaults()
        manager = nil
        fakeFetcher = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "subscriptionUrls_\(testProfileId)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Pod") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - Test: refreshAllFeeds surfaces new episodes to UI

    /// The full pipeline test: refreshAllFeeds → SyncStore background insert →
    /// reconcile → main context. After this, the UI (which reads
    /// `podcast.episodes`) must see the new episode.
    func test_refreshAllFeeds_newEpisodeVisibleViaRelationship() async {
        let feedUrl = "https://example.com/e2e-test-feed"
        let podcast = insertPodcast(url: feedUrl, title: "E2E Pod")

        // Configure the fake to return one new episode
        fakeFetcher.stubbedResults[feedUrl] = (
            podcast: ParsedPodcast(title: "E2E Pod"),
            episodes: [
                ParsedEpisode(
                    guid: "e2e-new-ep-1",
                    title: "Brand New Episode",
                    audioUrl: "https://example.com/e2e1.mp3"
                )
            ]
        )

        // Materialize the relationship (simulates what the UI does)
        _ = podcast.episodes.count

        // Act: the full pipeline
        let newEpisodes = await manager.refreshAllFeeds()

        // Assert: refreshAllFeeds returns the new episode
        XCTAssertEqual(newEpisodes.count, 1,
                       "refreshAllFeeds should return 1 new episode")
        XCTAssertEqual(newEpisodes.first?.guid, "e2e-new-ep-1")

        // Assert: podcast.episodes relationship sees it (this is what the UI uses)
        let relationshipGuids = podcast.episodes.map(\.guid)
        XCTAssertTrue(relationshipGuids.contains("e2e-new-ep-1"),
                      "podcast.episodes relationship must see the new episode — " +
                      "this is what PodcastDetailView uses")

        // Assert: subscriptions.flatMap { $0.episodes } sees it (HomeView path)
        let homeViewGuids = manager.subscriptions
            .flatMap { $0.episodes }
            .map(\.guid)
        XCTAssertTrue(homeViewGuids.contains("e2e-new-ep-1"),
                      "subscriptions.flatMap{$0.episodes} must see the new episode — " +
                      "this is what HomeView uses")
    }

    /// Subsequent refresh with NO new episodes (304 / nil) should not lose
    /// existing episodes.
    func test_refreshAllFeeds_304_preservesExistingEpisodes() async {
        let feedUrl = "https://example.com/e2e-304-feed"
        let podcast = insertPodcast(url: feedUrl, title: "304 Pod")

        // First refresh: add an episode
        fakeFetcher.stubbedResults[feedUrl] = (
            podcast: ParsedPodcast(title: "304 Pod"),
            episodes: [
                ParsedEpisode(guid: "existing-ep", title: "Existing",
                              audioUrl: "https://example.com/existing.mp3")
            ]
        )
        _ = await manager.refreshAllFeeds()

        XCTAssertEqual(podcast.episodes.count, 1, "Precondition: 1 episode after first refresh")

        // Second refresh: 304 Not Modified (nil result)
        fakeFetcher.stubbedResults[feedUrl] = nil

        let newEpisodes = await manager.refreshAllFeeds()

        XCTAssertEqual(newEpisodes.count, 0, "No new episodes on 304")
        XCTAssertEqual(podcast.episodes.count, 1, "Existing episode must survive a 304 refresh")
    }

    /// Multiple podcasts all get refreshed.
    func test_refreshAllFeeds_multipleFeeds() async {
        let feedA = "https://example.com/e2e-multi-a"
        let feedB = "https://example.com/e2e-multi-b"
        insertPodcast(url: feedA, title: "Pod A")
        insertPodcast(url: feedB, title: "Pod B")

        fakeFetcher.stubbedResults[feedA] = (
            podcast: ParsedPodcast(title: "Pod A"),
            episodes: [
                ParsedEpisode(guid: "a-ep-1", title: "A Episode 1",
                              audioUrl: "https://example.com/a1.mp3")
            ]
        )
        fakeFetcher.stubbedResults[feedB] = (
            podcast: ParsedPodcast(title: "Pod B"),
            episodes: [
                ParsedEpisode(guid: "b-ep-1", title: "B Episode 1",
                              audioUrl: "https://example.com/b1.mp3"),
                ParsedEpisode(guid: "b-ep-2", title: "B Episode 2",
                              audioUrl: "https://example.com/b2.mp3")
            ]
        )

        let newEpisodes = await manager.refreshAllFeeds()

        XCTAssertEqual(newEpisodes.count, 3,
                       "All 3 new episodes across 2 feeds should be found")

        let guids = Set(newEpisodes.map(\.guid))
        XCTAssertTrue(guids.contains("a-ep-1"))
        XCTAssertTrue(guids.contains("b-ep-1"))
        XCTAssertTrue(guids.contains("b-ep-2"))
    }
}

// MARK: - Fake FeedFetching

/// Controllable fake for RSSService. Returns stubbed results by URL.
/// `nil` in stubbedResults simulates a 304 Not Modified response.
private final class FakeFeedFetcher: FeedFetching, @unchecked Sendable {
    var stubbedResults: [String: (podcast: ParsedPodcast, episodes: [ParsedEpisode])?] = [:]
    var fetchedURLs: [String] = []

    func fetchFeed(
        url feedUrl: String,
        authHeader: String?
    ) async throws -> (podcast: ParsedPodcast, episodes: [ParsedEpisode])? {
        fetchedURLs.append(feedUrl)
        // If key doesn't exist, return nil (simulates 304)
        guard let entry = stubbedResults[feedUrl] else { return nil }
        return entry
    }
}

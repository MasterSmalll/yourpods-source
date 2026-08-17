import XCTest
import SwiftData
@testable import YourPods

// MARK: - OPML Import Serialization Tests

/// Regression tests for crash stack #4: concurrent OPML import.
///
/// `SettingsView.handleOPMLImport` previously spawned one unstructured `Task {}`
/// per feed URL, each inserting a podcast + episodes and saving the shared
/// `@MainActor` `ModelContext`. The interleaved inserts/saves raced Core Data's
/// INSERT bind-variable cleanup (`_clearBindVariablesForInsertedRow` →
/// `objc_msgSend` EXC_BAD_ACCESS).
///
/// `PodcastManager.importSubscriptions(_:onEach:)` is the serialized replacement:
/// it awaits each `addSubscription` fully before starting the next, so at most
/// one feed fetch + save is ever in flight.
@MainActor
final class OPMLImportSerializationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        // OPML import always runs under an active profile in production; set one
        // so loadSubscriptions surfaces the imported podcasts (it shows empty
        // when activeProfileId is nil).
        UserDefaults.standard.set("global", forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_global")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_global")
        context = nil
        container = nil
        try await super.tearDown()
    }

    /// A fake feed fetcher that returns a canned feed and records how many
    /// `fetchFeed` calls overlap in flight. Sequential imports never overlap
    /// (`maxInFlight == 1`); a concurrent fan-out would push it above 1.
    actor FakeFeedFetcher: FeedFetching {
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0
        private(set) var fetchedUrls: [String] = []

        func fetchFeed(
            url feedUrl: String,
            authHeader: String?
        ) async throws -> (podcast: ParsedPodcast, episodes: [ParsedEpisode])? {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            fetchedUrls.append(feedUrl)
            // Yield so any concurrently-started fetch has a chance to overlap
            // before this one completes — makes a non-sequential impl observable.
            await Task.yield()
            defer { inFlight -= 1 }
            let podcast = ParsedPodcast(title: feedUrl)
            let episodes = [
                ParsedEpisode(guid: feedUrl + "#1", title: "Ep 1", audioUrl: feedUrl + "/1.mp3"),
                ParsedEpisode(guid: feedUrl + "#2", title: "Ep 2", audioUrl: feedUrl + "/2.mp3"),
            ]
            return (podcast, episodes)
        }
    }

    func test_importSubscriptions_addsEveryFeed() async {
        let fake = FakeFeedFetcher()
        let manager = PodcastManager(modelContext: context, feedFetcher: fake)
        let urls = [
            "https://a.example.com/feed",
            "https://b.example.com/feed",
            "https://c.example.com/feed",
        ]

        await manager.importSubscriptions(urls)

        XCTAssertEqual(
            Set(manager.subscriptions.map(\.url)), Set(urls),
            "every imported feed should be subscribed"
        )
    }

    func test_importSubscriptions_runsSequentially_neverOverlappingFetches() async {
        let fake = FakeFeedFetcher()
        let manager = PodcastManager(modelContext: context, feedFetcher: fake)
        let urls = [
            "https://a.example.com/feed",
            "https://b.example.com/feed",
            "https://c.example.com/feed",
        ]

        await manager.importSubscriptions(urls)

        let maxInFlight = await fake.maxInFlight
        XCTAssertEqual(
            maxInFlight, 1,
            "OPML import must serialize subscriptions — concurrent fetches risk the Core Data INSERT race (crash stack #4)"
        )
    }

    func test_importSubscriptions_invokesOnEachPerFeedInOrder() async {
        let fake = FakeFeedFetcher()
        let manager = PodcastManager(modelContext: context, feedFetcher: fake)
        let urls = [
            "https://a.example.com/feed",
            "https://b.example.com/feed",
        ]

        var seen: [String] = []
        await manager.importSubscriptions(urls) { seen.append($0) }

        XCTAssertEqual(seen, urls, "onEach should fire once per URL, in import order")
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// Tests for Bug 1: Library disappearance when profile URL filtering produces
/// zero results but SwiftData store still has podcasts.
///
/// Covers:
///   - Re-adoption safety net when profileUrls → filter produces empty results
///   - Stale URL sets where URLs have changed (e.g., feed migration)
@MainActor
final class SubscriptionLoadingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-sub-loading"

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
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func profileUrls() -> Set<String> {
        let key = "subscriptionUrls_\(testProfileId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let urls = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return urls
    }

    // MARK: - Re-adoption safety net

    /// When profile URL filter produces zero results but store has podcasts,
    /// loadSubscriptions should re-adopt all podcasts instead of showing empty.
    /// This prevents library disappearance when URLs have drifted.
    func test_loadSubscriptions_reAdoptsFromStore_whenProfileFilterReturnsEmpty() {
        // GIVEN: 3 podcasts in SwiftData, associated with profile
        insertPodcast(url: "https://example.com/podcast-1", title: "Podcast 1")
        insertPodcast(url: "https://example.com/podcast-2", title: "Podcast 2")
        insertPodcast(url: "https://example.com/podcast-3", title: "Podcast 3")
        XCTAssertEqual(manager.subscriptions.count, 3, "Precondition: 3 subscriptions loaded")

        // Simulate URL drift: write stale URLs that match NONE of the store's podcasts
        let staleUrls: Set<String> = [
            "https://old.example.com/podcast-1",  // Different domain
            "https://old.example.com/podcast-2",
        ]
        let data = try! JSONEncoder().encode(staleUrls)
        UserDefaults.standard.set(data, forKey: "subscriptionUrls_\(testProfileId)")

        // Verify the stale URLs are actually set
        let writtenUrls = profileUrls()
        XCTAssertEqual(writtenUrls.count, 2, "Stale URLs should be written")
        XCTAssertTrue(writtenUrls.contains("https://old.example.com/podcast-1"))

        // WHEN: loadSubscriptions with stale profile URLs
        manager.loadSubscriptions()

        // THEN: Should re-adopt all podcasts, not show empty
        // This is the fix we need to implement — without the fix, subscriptions.count would be 0
        XCTAssertEqual(manager.subscriptions.count, 3,
                       "Library must not disappear — should re-adopt from store when filter produces zero results")
    }

    /// When profile URLs partially match (some valid, some stale), the filter
    /// should NOT trigger re-adoption — only the matching podcasts are shown.
    /// This ensures normal filtering still works when URLs partially diverge.
    func test_loadSubscriptions_showsPartialMatch_whenSomeUrlsAreStale() {
        // GIVEN: 3 podcasts in SwiftData
        insertPodcast(url: "https://example.com/podcast-a", title: "Podcast A")
        insertPodcast(url: "https://example.com/podcast-b", title: "Podcast B")
        insertPodcast(url: "https://example.com/podcast-c", title: "Podcast C")

        // Profile URLs contain only 2 of the 3 store URLs (1 stale)
        let partialUrls: Set<String> = [
            "https://example.com/podcast-a",  // matches
            "https://example.com/podcast-b",  // matches
            "https://old.example.com/stale",   // stale — no match
        ]
        let data = try! JSONEncoder().encode(partialUrls)
        UserDefaults.standard.set(data, forKey: "subscriptionUrls_\(testProfileId)")

        // WHEN: loadSubscriptions
        manager.loadSubscriptions()

        // THEN: Should show only the 2 matching podcasts (normal filter behavior)
        XCTAssertEqual(manager.subscriptions.count, 2,
                       "Partial match should filter normally — 2 of 3 match")
    }
}

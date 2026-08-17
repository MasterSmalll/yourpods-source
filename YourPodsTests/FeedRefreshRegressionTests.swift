import XCTest
import SwiftData
@testable import YourPods

/// Regression test: refreshAllFeeds delegates to SyncStore (background actor)
/// which inserts new episodes on a separate ModelContext. The main actor must
/// see those episodes after reconcile — both via direct FetchDescriptor AND
/// via the `episodes(withGuids:)` helper that `processNewEpisodes` depends on.
///
/// Bug: `episodes(withGuids:)` traversed `subscriptions.flatMap(\.episodes)`
/// which uses the Podcast.episodes relationship cache. After cross-context
/// background writes, this cache is stale — the method returns [] even though
/// the episodes exist in the store. This broke auto-queue, auto-download,
/// and new-episode notifications for ALL users.
@MainActor
final class FeedRefreshRegressionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!

    private let testProfileId = "test-profile-feed-regression"

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
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Pod") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - Test: episodes(withGuids:) finds episodes inserted by SyncStore

    /// This is the core regression test. SyncStore inserts episodes on a
    /// background context. After `reconcileAfterBackgroundWrites()`, the
    /// `episodes(withGuids:)` method must find them — it must NOT rely on
    /// the Podcast.episodes relationship cache.
    func test_episodesWithGuids_findsBackgroundInsertedEpisodes() async {
        let url = "https://example.com/regression-feed"
        insertPodcast(url: url, title: "Regression Pod")

        // Simulate what refreshAllFeeds Phase 2 does:
        // SyncStore inserts episodes on background context
        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(title: "Regression Pod"),
            episodes: [
                ParsedEpisode(guid: "new-ep-1", title: "New Episode 1",
                              audioUrl: "https://example.com/ep1.mp3"),
                ParsedEpisode(guid: "new-ep-2", title: "New Episode 2",
                              audioUrl: "https://example.com/ep2.mp3"),
            ]
        )

        let outcome = await manager.syncStore.applyFeedResults([feedResult])

        // SyncStore should report 2 new GUIDs
        XCTAssertEqual(outcome.newEpisodeGuids.count, 2,
                       "SyncStore should report 2 new episode GUIDs")

        // Reconcile main context (this is what refreshAllFeeds does)
        manager.reconcileAfterBackgroundWrites()

        // THE REGRESSION: episodes(withGuids:) must find the episodes
        let found = manager.episodes(withGuids: outcome.newEpisodeGuids)
        XCTAssertEqual(found.count, 2,
                       "episodes(withGuids:) must find episodes inserted by SyncStore — " +
                       "relationship cache must not hide them")
    }

    /// Verify that the returned episodes have the correct data.
    func test_episodesWithGuids_returnsCorrectData() async {
        let url = "https://example.com/data-check-feed"
        insertPodcast(url: url, title: "Data Check Pod")

        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(title: "Data Check Pod"),
            episodes: [
                ParsedEpisode(guid: "dc-ep-1", title: "Data Episode",
                              audioUrl: "https://example.com/dc1.mp3",
                              durationSeconds: 1800),
            ]
        )

        let outcome = await manager.syncStore.applyFeedResults([feedResult])
        manager.reconcileAfterBackgroundWrites()

        let found = manager.episodes(withGuids: outcome.newEpisodeGuids)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.guid, "dc-ep-1")
        XCTAssertEqual(found.first?.title, "Data Episode")
    }

    /// Empty GUIDs should return empty (baseline sanity check).
    func test_episodesWithGuids_emptyGuidsReturnsEmpty() {
        let found = manager.episodes(withGuids: [])
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - DIAGNOSTIC: does the UI relationship path see new episodes?

    /// Scenario: the user-visible episode lists (HomeView, PodcastDetailView,
    /// LibraryView, etc.) read episodes by traversing the `Podcast.episodes`
    /// relationship — e.g. HomeView uses `subscriptions.flatMap { $0.episodes }`,
    /// the EXACT expression the buggy `episodes(withGuids:)` used.
    ///
    /// This test materializes the relationship first (as the UI would when it
    /// shows the list), then performs a background SyncStore insert + reconcile,
    /// then checks whether the relationship traversal sees the new episode.
    ///
    /// If this FAILS while `test_episodesWithGuids_findsBackgroundInsertedEpisodes`
    /// PASSES, the uncommitted fix is INCOMPLETE: the visible feeds remain stale.
    func test_relationshipTraversal_seesNewEpisodes_afterReconcile() async {
        let url = "https://example.com/ui-relationship-feed"
        let podcast = insertPodcast(url: url, title: "UI Relationship Pod")

        // Materialize the relationship now — simulates the UI having shown the
        // episode list before the refresh (the realistic, stale-cache case).
        _ = podcast.episodes.count
        _ = manager.subscriptions.flatMap { $0.episodes }.count

        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(title: "UI Relationship Pod"),
            episodes: [
                ParsedEpisode(guid: "ui-rel-1", title: "UI Rel Episode 1",
                              audioUrl: "https://example.com/uir1.mp3"),
            ]
        )

        let outcome = await manager.syncStore.applyFeedResults([feedResult])
        XCTAssertEqual(outcome.newEpisodeGuids, ["ui-rel-1"],
                       "SyncStore should report the new GUID")

        manager.reconcileAfterBackgroundWrites()

        // Control: the FetchDescriptor path (the applied fix) MUST find it.
        let viaFetch = manager.episodes(withGuids: ["ui-rel-1"]).map(\.guid)
        XCTAssertEqual(viaFetch, ["ui-rel-1"],
                       "CONTROL: FetchDescriptor path must find the new episode")

        // The actual UI path: subscriptions.flatMap { $0.episodes } (HomeView.swift:18)
        let viaSubscriptionsRel = manager.subscriptions
            .flatMap { $0.episodes }
            .map(\.guid)
        // And the per-podcast relationship (PodcastDetailView.swift:24)
        let viaPodcastRel = podcast.episodes.map(\.guid)

        XCTAssertTrue(viaSubscriptionsRel.contains("ui-rel-1"),
                      "UI PATH (subscriptions.flatMap{$0.episodes} — HomeView): new episode is INVISIBLE → feeds appear stale")
        XCTAssertTrue(viaPodcastRel.contains("ui-rel-1"),
                      "UI PATH (podcast.episodes — PodcastDetailView): new episode is INVISIBLE → episode list appears stale")
    }

    /// Hardening guard: episodes(withGuids:) must return ALL matches for a large GUID
    /// set (the realistic first-sync case) — exercises the SwiftData Set-membership
    /// predicate at scale. If the predicate ever fails to translate on some OS, the
    /// in-memory fallback keeps this green rather than silently returning [].
    func test_episodesWithGuids_largeSet_returnsAllMatches() async {
        let url = "https://example.com/large-feed"
        insertPodcast(url: url, title: "Large Pod")

        let parsed = (0..<200).map { i in
            ParsedEpisode(guid: "big-\(i)", title: "Ep \(i)",
                          audioUrl: "https://example.com/big\(i).mp3")
        }
        let feedResult = FeedFetchResult(
            url: url, authHeader: nil,
            parsed: ParsedPodcast(title: "Large Pod"), episodes: parsed
        )
        let outcome = await manager.syncStore.applyFeedResults([feedResult])
        XCTAssertEqual(outcome.newEpisodeGuids.count, 200)

        manager.reconcileAfterBackgroundWrites()

        let found = manager.episodes(withGuids: outcome.newEpisodeGuids)
        XCTAssertEqual(found.count, 200,
                       "all 200 episodes must be found by GUID — no silent [] from a predicate failure")
    }

    // MARK: - Re-applying identical feed metadata must not re-write rows
    //
    // The no-churn guarantee and the genuine-change-still-updates guard used to
    // be pinned here via PodcastManager.applyFeedResult (zero production
    // callers). That coverage is superseded by LivePathChurnTests, which pins
    // the same guarantees on the path refreshAllFeeds actually uses
    // (syncStore.applyFeedResults) — see LivePathChurnTests.swift for why
    // `context.hasChanges` on the MAIN context can never fail for a SyncStore
    // write and would not have caught anything here.
}

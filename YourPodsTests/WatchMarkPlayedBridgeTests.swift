import XCTest
import SwiftData
@testable import YourPods

/// The phone-side watch bridge must resolve a watch-supplied episode
/// guid to its persisted `Episode` and route through the SAME mark-played
/// pipeline used everywhere else (`PodcastDetailView`, `QueueView`) — never
/// reimplement completion/sync semantics in the bridge itself.
///
/// Mirrors the seeding pattern used by `PodcastManagerLogicTests` (profile
/// association + `loadSubscriptions()`), since `markEpisodeAsPlayed(podcastUrl:episodeGuid:)`
/// resolves its podcast via `PodcastManager.subscriptions`, not a raw context fetch.
@MainActor
final class WatchMarkPlayedBridgeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!

    private let testProfileId = "test-profile-watch-bridge"

    override func setUp() {
        super.setUp()
        clearTestDefaults()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        podcastManager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        clearTestDefaults()
        podcastManager = nil
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

    /// Insert a podcast + one unplayed episode directly into SwiftData (bypasses RSS fetch),
    /// then associate it with the active test profile and load subscriptions — matching how
    /// `PodcastManager.subscriptions` is actually populated at runtime.
    @discardableResult
    private func insertPodcastWithEpisode(
        url: String = "https://example.com/feed",
        title: String = "Pod",
        episodeGuid: String = "watch-guid-1"
    ) -> (Podcast, Episode) {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)

        let episode = Episode(guid: episodeGuid, title: "Ep", podcast: podcast)
        context.insert(episode)

        try! context.save()

        podcastManager.associateWithCurrentProfile(url: url)
        podcastManager.loadSubscriptions()

        return (podcast, episode)
    }

    // MARK: - markEpisodeAsPlayedByGuid

    func test_markEpisodeAsPlayedByGuid_marksThePersistedEpisode() {
        // GIVEN: a subscribed podcast with one unplayed episode
        let (_, episode) = insertPodcastWithEpisode(episodeGuid: "watch-guid-1")
        XCTAssertFalse(episode.isPlayed)

        // WHEN: the watch bridge resolves the episode by guid only (no podcastUrl)
        let handled = podcastManager.markEpisodeAsPlayedByGuid("watch-guid-1")

        // THEN: it delegates to the standard mark-played pipeline
        XCTAssertTrue(handled)
        XCTAssertTrue(episode.isPlayed)
    }

    func test_markEpisodeAsPlayedByGuid_unknownGuid_returnsFalse() {
        // EDGE: no episode exists for the given guid — must not crash, must report unhandled
        XCTAssertFalse(podcastManager.markEpisodeAsPlayedByGuid("nope"))
    }

    // MARK: - markEpisodeAsPlayed — survives an unloaded Podcast.episodes relationship

    /// `markEpisodeAsPlayed(podcastUrl:episodeGuid:)` used to resolve
    /// its episode via `subscriptions.first{...}.episodes.first{...}` — the
    /// `Podcast.episodes` relationship, which is stale-prone after a background-context
    /// write (`SyncStore` inserts on its own actor context) until the main context is
    /// explicitly reconciled (`reconcileAfterBackgroundWrites()` → `refreshAllFromStore()`
    /// + `loadSubscriptions()`). A watch `mark_as_played` command can be handled WHILE a
    /// background refresh is still in flight — i.e. exactly in the window before that
    /// reconcile call — which is what this test reproduces: insert the podcast,
    /// materialize its (empty) `episodes` relationship the way the UI would, write the
    /// new episode via `SyncStore` (a genuinely separate context/actor), and — critically
    /// — do NOT reconcile before calling `markEpisodeAsPlayed`. (Calling
    /// `reconcileAfterBackgroundWrites()` first was tried and made the relationship
    /// traversal NOT stale, since `loadSubscriptions()` rebuilds `subscriptions` from a
    /// fresh fetch — that would no longer exercise the mid-sync race this guards.)
    /// `episodes(withGuids:)` is a fresh `FetchDescriptor` query, so — unlike the
    /// already-faulted relationship — it sees the background write immediately.
    func test_markEpisodeAsPlayed_survivesUnloadedRelationship_viaFetchLookup() async {
        let url = "https://example.com/unloaded-relationship-feed"
        let podcast = Podcast(url: url, title: "Unloaded Relationship Pod")
        context.insert(podcast)
        try! context.save()
        podcastManager.associateWithCurrentProfile(url: url)
        podcastManager.loadSubscriptions()

        // Materialize the relationship BEFORE the episode exists — simulates the UI
        // having shown an (empty) episode list.
        _ = podcast.episodes.count

        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(title: "Unloaded Relationship Pod"),
            episodes: [
                ParsedEpisode(guid: "watch-guid-unloaded", title: "Ep",
                              audioUrl: "https://example.com/unloaded.mp3"),
            ]
        )
        let outcome = await podcastManager.syncStore.applyFeedResults([feedResult])
        XCTAssertEqual(outcome.newEpisodeGuids, ["watch-guid-unloaded"])
        // Deliberately NOT calling reconcileAfterBackgroundWrites() — see doc comment.

        // CONTROL: the relationship cache is genuinely stale in this window — this is
        // the exact condition that made the pre-fix traversal silently no-op.
        XCTAssertFalse(podcast.episodes.contains { $0.guid == "watch-guid-unloaded" },
                       "CONTROL: unreconciled relationship cache should NOT see the new episode")

        // WHEN: mark as played via the manager, exactly as the watch bridge does
        podcastManager.markEpisodeAsPlayed(podcastUrl: url, episodeGuid: "watch-guid-unloaded")

        // THEN: the persisted flag is set — no crash, no silent no-op.
        let persisted = podcastManager.episodes(withGuids: ["watch-guid-unloaded"]).first
        XCTAssertEqual(persisted?.isPlayed, true,
                       "markEpisodeAsPlayed must find and mark the episode even when " +
                       "the Podcast.episodes relationship is stale")
    }
}

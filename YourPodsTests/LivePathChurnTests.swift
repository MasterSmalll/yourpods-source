import XCTest
import SwiftData
import CoreData
@testable import YourPods

/// The no-churn guarantee and feedItemIndex, asserted on the path that
/// actually runs: refreshAllFeeds -> syncStore.applyFeedResults.
///
/// The pre-existing equivalents in FeedRefreshRegressionTests drive
/// PodcastManager.applyFeedResult, which has zero production callers.
///
/// **Why not `context.hasChanges`:** `SyncStore` writes on its own private
/// background `ModelContext(container)` (`SyncStore.swift:43`) and saves there.
/// The main context never stages those writes — `reconcileAfterBackgroundWrites()`
/// calls `refreshAllFromStore()`, which DISCARDS cache rather than staging — so
/// `hasChanges` on the main context reads false whether the mapper is guarded or
/// not. It cannot fail, so it cannot prove anything. Count dirty rows at the
/// background context's own flush instead.
///
/// **Why content-scoped, not `object: nil`:** `SyncApplyChurnTests`' equivalent
/// observes `.NSManagedObjectContextWillSave` with `object: nil` and gets away
/// with it because its work closure is synchronous with no suspension point —
/// nothing else in the process can interleave while it runs. Ours awaits an
/// actor call (`syncStore.applyFeedResults`), which suspends; during that
/// suspension any sibling `NSManagedObjectContext` in the process (main-context
/// autosave, another test's fixture, ...) can flush and get counted too. That
/// contamination inflated a measured 2 dirty rows (isolated run) into 55 under
/// a full class-level run. The `max` accumulator means contamination can only
/// inflate the reading, never mask a bug into a false green — but it CAN fail a
/// correct fix under the exact class-level command the merge gate runs.
///
/// The obvious fix — resolve `SyncStore`'s own background
/// `NSManagedObjectContext` once and match flushes by identity — does not work
/// on this SDK (verified empirically, not assumed): `ModelContext` no longer
/// stores a raw `NSManagedObjectContext` reachable via reflection at all.
/// `Mirror(reflecting:)` on `SyncStore.testContext` was dumped live and its
/// children are entirely SwiftData's own `PersistentIdentifier`/
/// `AnyPersistentObject` bookkeeping (`_container`, `_insertedObjects: Set<AnyPersistentObject>`,
/// `_hasChanges: Bool`, ...) — no `_nsContext` label and no
/// `NSManagedObjectContext`-typed property anywhere. Both
/// `ModelContext+SafeSave.swift`'s `underlyingNSContext` (which falls back to
/// that same `_nsContext` Mirror label off-main-thread) and
/// `SyncStore.backgroundNSContext()` (`SyncStoreMergePolicyTests.swift`, which
/// wraps it) reliably return nil for `SyncStore`'s context on this SDK —
/// confirmed by running the resolution inside a real test and observing the
/// nil.
///
/// Instead: `.NSManagedObjectContextWillSave` still fires with a genuine Core
/// Data `NSManagedObjectContext` — SwiftData still persists through Core Data
/// under the hood even though `ModelContext` no longer exposes it — and its
/// `insertedObjects`/`updatedObjects`/`deletedObjects` are raw
/// `NSManagedObject`s whose KVC-accessible attributes match the SwiftData
/// model's property names 1:1 (confirmed empirically for `Podcast.url` and
/// `Episode.guid`). The observer below filters every firing context's touched
/// rows down to ones whose `url`/`guid` match THIS test's own fixture values
/// (`live-churn-*` URLs, guid `"live-churn-ep1"`). Those values are chosen
/// specifically to be unique to this class — not because "sibling tests use a
/// distinct fixture URL/GUID" is some repo-wide guarantee it isn't: plenty of
/// other test files reuse plain guids like `"ep1"` freely, and this filter
/// would happily count their writes too if this class's fixtures collided
/// with them. The uniqueness is a property we maintain here, on purpose, so
/// the claim holds — not something the test suite enforces for us. It also
/// cannot distinguish this test's own main-context `Podcast` copy (same url)
/// flushing on its own from the background context's write; that's inflation
/// only, same as the cross-test case, and the `max` accumulator means it can
/// never mask a bug into a false green. A first-apply sanity assertion (known
/// to genuinely dirty rows) proves the KVC match actually fires, so a broken
/// filter fails loudly instead of the second-apply assertion trivially (and
/// falsely) passing with an unmatched 0.
@MainActor
final class LivePathChurnTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-live-path-churn"

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
        manager = nil; context = nil; container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "subscriptionUrls_\(testProfileId)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @discardableResult
    private func insertPodcast(url: String) -> Podcast {
        let podcast = Podcast(url: url, title: "Churn Pod")
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func makeFeed(url: String, episodeNumber: Double = 1) -> FeedFetchResult {
        var ep = ParsedEpisode(guid: "live-churn-ep1", title: "Ep 1", audioUrl: "https://example.com/1.mp3")
        ep.episodeNumber = episodeNumber
        ep.seasonNumber = 1
        ep.episodeType = "full"
        ep.explicit = false
        ep.feedItemIndex = 2
        return FeedFetchResult(
            url: url, authHeader: nil,
            parsed: ParsedPodcast(title: "Churn Pod"),
            episodes: [ep]
        )
    }

    // MARK: - No-churn, on the live path

    /// Thread-safe max accumulator. The willSave observer fires on whichever
    /// thread the background context flushes on, so a captured `var` would be a
    /// data race (and won't compile cleanly in an async context).
    private final class DirtyPeak: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0
        func record(_ n: Int) { lock.lock(); peak = Swift.max(peak, n); lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }

    /// Rows flagged dirty, belonging to THIS test's own fixture (matched by
    /// `url` and/or `guid`), at the moment any context flushes. See the class
    /// doc comment for why this is content-scoped rather than
    /// context-identity-scoped.
    ///
    /// This is the Core Data layer that re-writes a row for ANY setter call —
    /// including an identical-value assign — and is exactly what the on-device
    /// `dirtyKeys` diagnostic samples.
    private func dirtyRowCount(
        url: String? = nil,
        guid: String? = nil,
        during work: () async -> Void
    ) async -> Int {
        let peak = DirtyPeak()
        let token = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: nil, queue: nil
        ) { note in
            guard let moc = note.object as? NSManagedObjectContext else { return }
            let touched = moc.updatedObjects.union(moc.insertedObjects).union(moc.deletedObjects)
            let matching = touched.filter { obj in
                if let url, obj.entity.attributesByName["url"] != nil,
                   obj.value(forKey: "url") as? String == url {
                    return true
                }
                if let guid, obj.entity.attributesByName["guid"] != nil,
                   obj.value(forKey: "guid") as? String == guid {
                    return true
                }
                return false
            }
            peak.record(matching.count)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await work()
        return peak.value
    }

    func test_applyFeedResults_doesNotDirtyContext_whenNothingChanged() async {
        let url = "https://example.com/live-churn-feed"
        insertPodcast(url: url)
        let feed = makeFeed(url: url)

        // First apply inserts the podcast/episode rows — dirty rows here are
        // expected and fine. Also a sanity check: proves the content-based
        // filter below actually detects a genuine write, so a broken filter
        // fails loudly here instead of letting the second-apply assertion
        // trivially (and falsely) pass with an unmatched 0.
        let firstApplyDirty = await dirtyRowCount(url: url, guid: "live-churn-ep1") {
            _ = await manager.syncStore.applyFeedResults([feed])
        }
        manager.reconcileAfterBackgroundWrites()
        XCTAssertGreaterThan(firstApplyDirty, 0,
                             "Sanity check: the content-based dirty-row filter must detect the genuine " +
                             "podcast/episode insert, or the second-apply 0 below would be a false green")

        // Re-apply the IDENTICAL feed. The live path must write nothing.
        let dirty = await dirtyRowCount(url: url, guid: "live-churn-ep1") {
            _ = await manager.syncStore.applyFeedResults([feed])
        }

        XCTAssertEqual(dirty, 0,
                       "Re-applying identical feed metadata must not dirty any row — this is the " +
                       "whole-library re-persist churn, on the path refreshAllFeeds actually uses")
    }

    func test_applyFeedResults_stillUpdates_whenMetadataChanged() async {
        let url = "https://example.com/live-churn-changed"
        insertPodcast(url: url)

        _ = await manager.syncStore.applyFeedResults([makeFeed(url: url, episodeNumber: 5)])
        manager.reconcileAfterBackgroundWrites()
        _ = await manager.syncStore.applyFeedResults([makeFeed(url: url, episodeNumber: 6)])
        manager.reconcileAfterBackgroundWrites()

        XCTAssertEqual(manager.episodes(withGuids: ["live-churn-ep1"]).first?.episodeNumber, 6,
                       "A genuine change must still land — the guard suppresses no-ops, not updates")
    }

    // MARK: - feedItemIndex, never set on the live path today

    func test_applyFeedResults_setsFeedItemIndex_onInsert() async {
        let url = "https://example.com/live-feeditemindex"
        insertPodcast(url: url)

        _ = await manager.syncStore.applyFeedResults([makeFeed(url: url)])
        manager.reconcileAfterBackgroundWrites()

        XCTAssertEqual(manager.episodes(withGuids: ["live-churn-ep1"]).first?.feedItemIndex, 2,
                       "feedItemIndex is the episodesByFeedOrder tie-breaker — the live path must set it. " +
                       "Expected value is deliberately non-zero so this assertion can't degrade into a " +
                       "tautology if feedItemIndex ever became a non-optional Int with a default of 0.")
    }

    func test_applyFeedResults_updatesFeedItemIndex_whenFeedReorders() async {
        let url = "https://example.com/live-reorder"
        insertPodcast(url: url)

        _ = await manager.syncStore.applyFeedResults([makeFeed(url: url)])
        manager.reconcileAfterBackgroundWrites()

        var moved = ParsedEpisode(guid: "live-churn-ep1", title: "Ep 1", audioUrl: "https://example.com/1.mp3")
        moved.feedItemIndex = 3
        _ = await manager.syncStore.applyFeedResults([
            FeedFetchResult(url: url, authHeader: nil, parsed: ParsedPodcast(title: "Churn Pod"), episodes: [moved])
        ])
        manager.reconcileAfterBackgroundWrites()

        XCTAssertEqual(manager.episodes(withGuids: ["live-churn-ep1"]).first?.feedItemIndex, 3,
                       "A feed that reorders its items must move the tie-breaker with them")
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for subscription drift fix.
///
/// Root cause: `syncSubscriptions()` only runs remote deletion (Step 5b)
/// when `since == 0`. YourPods Pro always returns the full subscription list,
/// but after the first sync `since > 0`, so remote deletions are never detected.
///
/// Fix: Use `SyncClient.returnsFullSubscriptionList` to gate Step 5b instead
/// of the `since == 0` check.
@MainActor
final class SubscriptionDriftTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-drift"

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
            "serverProfiles",
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

    // MARK: - Remote Deletion Tests

    /// When a full-list client returns a subscription list that does NOT contain
    /// a locally-subscribed URL, that subscription must be disassociated —
    /// even when `since > 0` (incremental sync).
    func test_remoteDeletion_runsForFullListClient_whenSinceGreaterThanZero() async throws {
        // GIVEN: 3 local subscriptions, server only has 2
        insertPodcast(url: "https://example.com/podcast-a", title: "Podcast A")
        insertPodcast(url: "https://example.com/podcast-b", title: "Podcast B")
        insertPodcast(url: "https://example.com/podcast-c", title: "Podcast C (deleted on server)")
        XCTAssertEqual(manager.subscriptions.count, 3)

        // Set since > 0 to simulate an incremental sync (NOT first sync)
        UserDefaults.standard.set(1000, forKey: "lastSubscriptionSync_\(testProfileId)")

        // Mock: full-list client returns only A and B (C was deleted on server)
        let spy = DriftSpySyncClient(
            serverSubscriptions: [
                "https://example.com/podcast-a",
                "https://example.com/podcast-b"
            ],
            returnsFullList: true
        )
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: syncSubscriptions runs
        _ = try await manager.syncSubscriptions()
        manager.loadSubscriptions()

        // THEN: Podcast C should be removed (disassociated from profile)
        XCTAssertEqual(manager.subscriptions.count, 2,
                       "Full-list client must trigger remote deletion even when since > 0")
        XCTAssertTrue(manager.subscriptions.contains(where: { $0.url == "https://example.com/podcast-a" }))
        XCTAssertTrue(manager.subscriptions.contains(where: { $0.url == "https://example.com/podcast-b" }))
        XCTAssertFalse(manager.subscriptions.contains(where: { $0.url == "https://example.com/podcast-c" }),
                       "Podcast C must be removed — server no longer has it")
    }

    /// A delta client (gPodder) with `since > 0` must NOT run remote deletion,
    /// because `delta.add` only contains new additions — not the full list.
    func test_remoteDeletion_skippedForDeltaClient_whenSinceGreaterThanZero() async throws {
        // GIVEN: 3 local subscriptions, delta client returns only 1 (new addition)
        insertPodcast(url: "https://example.com/podcast-a", title: "Podcast A")
        insertPodcast(url: "https://example.com/podcast-b", title: "Podcast B")
        insertPodcast(url: "https://example.com/podcast-c", title: "Podcast C")
        XCTAssertEqual(manager.subscriptions.count, 3)

        // Set since > 0 — incremental delta sync
        UserDefaults.standard.set(1000, forKey: "lastSubscriptionSync_\(testProfileId)")

        // Mock: delta client returns 1 new addition (NOT the full list)
        let spy = DriftSpySyncClient(
            serverSubscriptions: ["https://example.com/podcast-d"],  // new add
            returnsFullList: false  // delta mode
        )
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: syncSubscriptions runs
        _ = try await manager.syncSubscriptions()
        manager.loadSubscriptions()

        // THEN: All 3 original subscriptions must survive (no remote deletion)
        XCTAssertTrue(manager.subscriptions.count >= 3,
                      "Delta client must NOT remove local subscriptions during incremental sync")
    }

    /// A pending local add must NOT be removed during reconciliation,
    /// even if the full-list server response doesn't include it yet
    /// (the push hasn't been confirmed).
    func test_pendingAddNotRemoved_duringFullListReconciliation() async throws {
        // GIVEN: 2 server-known subs + 1 pending local add not yet on server
        insertPodcast(url: "https://example.com/podcast-a", title: "Podcast A")
        insertPodcast(url: "https://example.com/podcast-b", title: "Podcast B")
        insertPodcast(url: "https://example.com/podcast-new", title: "New (pending add)")
        manager.addPendingSubscriptionAdd("https://example.com/podcast-new")
        XCTAssertEqual(manager.subscriptions.count, 3)

        // Simulate incremental sync (since > 0)
        UserDefaults.standard.set(1000, forKey: "lastSubscriptionSync_\(testProfileId)")

        // Mock: server only has A and B (doesn't have "new" yet — push hasn't arrived)
        let spy = DriftSpySyncClient(
            serverSubscriptions: [
                "https://example.com/podcast-a",
                "https://example.com/podcast-b"
            ],
            returnsFullList: true
        )
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: syncSubscriptions runs
        _ = try await manager.syncSubscriptions()
        manager.loadSubscriptions()

        // THEN: "podcast-new" must survive — it's a pending add (race condition guard)
        XCTAssertTrue(manager.subscriptions.contains(where: { $0.url == "https://example.com/podcast-new" }),
                      "Pending local add must NOT be removed during server reconciliation")
    }
}

// MARK: - Spy SyncClient for Drift Tests

actor DriftSpySyncClient: SyncClient {
    let serverSubscriptions: [String]
    let returnsFullSubscriptionList: Bool

    init(serverSubscriptions: [String], returnsFullList: Bool) {
        self.serverSubscriptions = serverSubscriptions
        self.returnsFullSubscriptionList = returnsFullList
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: serverSubscriptions, remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

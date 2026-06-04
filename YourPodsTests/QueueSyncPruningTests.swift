import XCTest
@testable import YourPods

// MARK: - Queue Sync Pruning Tests

/// Tests for the queue sync pruning fix.
///
/// Root cause: Step 1.5 in `syncQueueWithServer()` prunes local items
/// NOT on the server. This incorrectly removes items that were just added
/// locally and haven't been pushed yet — the server has never seen them.
///
/// Fix: Only prune items that were in the PREVIOUS sync's server response
/// and are now absent (removed/completed on another device). Items the
/// server has never acknowledged are preserved as "new local" items.
@MainActor
final class QueueSyncPruningTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let serverGuidsKey = "proQueueSyncServerGuids"
    private let syncCompletedKey = "proQueueSyncCompleted"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: serverGuidsKey)
        defaults.removeObject(forKey: syncCompletedKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: serverGuidsKey)
        defaults.removeObject(forKey: syncCompletedKey)
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    private func makeSyncItem(guid: String, sortOrder: Int, title: String = "Episode") -> QueueSyncItem {
        QueueSyncItem(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/\(guid).mp3",
            episodeGuid: guid,
            sortOrder: sortOrder,
            positionSec: 0,
            title: title,
            podcastTitle: "Test Podcast"
        )
    }

    // MARK: - Test 1: New local items survive pruning

    /// A locally-added item that was never in any server response must NOT
    /// be pruned during sync. This is the core bug: the user adds episode #5,
    /// sync fires before the push, and the pruning kills it.
    func test_pruning_preservesNewLocalItem_neverSeenByServer() async {
        // GIVEN: 4 items on the server (from last sync) + 1 new local item
        let serverItems = (1...4).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        // Previous server GUIDs = the 4 items from last sync
        defaults.set(["ep-1", "ep-2", "ep-3", "ep-4"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        // Local queue has all 4 server items + 1 new one ("ep-5")
        audioManager.appendToQueue((1...4).map { makeItem(id: "ep-\($0)") })
        audioManager.appendToQueue([makeItem(id: "ep-5", title: "New Local Episode")])
        XCTAssertEqual(audioManager.queue.count, 5, "Precondition: 5 local items")

        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        // syncQueue returns whatever is pushed (echo)
        await mockClient.setEchoMode(true)

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Queue sync runs (simulating sync before the push of ep-5)
        await playerManager.syncQueueWithServer()

        // THEN: ep-5 must survive — it was never on the server before
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertTrue(queueIds.contains("ep-5"),
                       "REGRESSION: New local item 'ep-5' was pruned! It was never on the server.")
        XCTAssertGreaterThanOrEqual(audioManager.queue.count, 5,
                       "Queue must have at least 5 items (4 server + 1 new local)")
    }

    // MARK: - Test 2: Server-removed items ARE pruned

    /// An item that was in the previous server response but is now gone
    /// (removed/completed on another device) SHOULD be pruned.
    func test_pruning_removesItemPreviouslyOnServer_nowGone() async {
        // GIVEN: Last sync had 4 items, now server only has 3 (ep-4 removed on another device)
        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        defaults.set(["ep-1", "ep-2", "ep-3", "ep-4"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        audioManager.appendToQueue((1...4).map { makeItem(id: "ep-\($0)") })
        XCTAssertEqual(audioManager.queue.count, 4, "Precondition: 4 local items")

        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setEchoMode(true)

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: ep-4 should be pruned (it was on the server, now it's gone)
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertFalse(queueIds.contains("ep-4"),
                       "ep-4 should be pruned — it was on the server before but is now removed")
    }

    // MARK: - Test 3: First sync (no previous history) does not prune

    /// On the very first queue sync (no proQueueSyncServerGuids stored),
    /// no local items should be pruned regardless of server state.
    func test_pruning_noopOnFirstSync_noPreviousServerHistory() async {
        // GIVEN: First sync — no server GUID history, but sync is "completed"
        // (This tests the edge case where proQueueSyncCompleted is true
        //  but proQueueSyncServerGuids has never been written)
        defaults.set(true, forKey: syncCompletedKey)
        // NO serverGuidsKey set — simulates first sync

        let audioManager = AudioManager()
        audioManager.appendToQueue((1...5).map { makeItem(id: "ep-\($0)") })

        // Server has only 3 items
        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setEchoMode(true)

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: ep-4 and ep-5 must NOT be pruned — no previous server history
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertTrue(queueIds.contains("ep-4"),
                       "ep-4 must not be pruned on first sync (no server history)")
        XCTAssertTrue(queueIds.contains("ep-5"),
                       "ep-5 must not be pruned on first sync (no server history)")
    }

    // MARK: - Test 4: Server GUIDs are persisted after sync

    /// After a successful sync, the server response GUIDs must be saved
    /// for the next sync's pruning comparison.
    func test_syncQueuePersistsServerGuids_forNextPruningCycle() async {
        let audioManager = AudioManager()
        audioManager.appendToQueue((1...3).map { makeItem(id: "ep-\($0)") })

        // Server has the same 3 items
        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setEchoMode(true)

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Server GUIDs should be persisted
        let storedGuids = defaults.stringArray(forKey: serverGuidsKey) ?? []
        XCTAssertFalse(storedGuids.isEmpty,
                        "Server GUIDs must be persisted after successful sync")
        XCTAssertTrue(storedGuids.contains("ep-1"), "ep-1 should be in stored GUIDs")
        XCTAssertTrue(storedGuids.contains("ep-2"), "ep-2 should be in stored GUIDs")
        XCTAssertTrue(storedGuids.contains("ep-3"), "ep-3 should be in stored GUIDs")
    }

    // MARK: - Test 5: Full scenario — 5 episodes, sync with server that has 4

    /// Integration test: user has 4 synced items, adds a 5th, then sync runs
    /// before the debounced push completes. The 5th must survive.
    func test_fiveEpisodes_allSurviveWhenSyncRunsBeforePush() async {
        // GIVEN: Previous sync established 4 items on the server
        defaults.set(["ep-1", "ep-2", "ep-3", "ep-4"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        // Local queue: 4 existing + 1 newly added
        audioManager.appendToQueue((1...5).map { makeItem(id: "ep-\($0)") })
        XCTAssertEqual(audioManager.queue.count, 5, "Precondition: 5 local items")

        // Server still has only 4 (push of ep-5 hasn't landed yet)
        let serverItems = (1...4).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setEchoMode(true)

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: syncQueueWithServer runs (race: sync fires before debounced push)
        await playerManager.syncQueueWithServer()

        // THEN: All 5 episodes must be in the final queue
        XCTAssertEqual(audioManager.queue.count, 5,
                       "REGRESSION: Queue was truncated to \(audioManager.queue.count) items! All 5 must survive.")

        // Verify the pushed payload included all 5
        let pushedCount = await mockClient.lastPushedItems.count
        XCTAssertEqual(pushedCount, 5,
                       "Push payload must include all 5 items, got \(pushedCount)")
    }
}

// MARK: - Mock SyncClient for Queue Pruning Tests

actor QueuePruningMockSyncClient: SyncClient {
    private var getQueueResponse: [QueueSyncItem] = []
    private var echoMode = false
    private(set) var lastPushedItems: [QueueSyncItem] = []

    func setGetQueueResponse(_ items: [QueueSyncItem]) {
        getQueueResponse = items
    }

    func setEchoMode(_ enabled: Bool) {
        echoMode = enabled
    }

    // MARK: - Queue (the methods under test)

    var supportsQueueSync: Bool { true }

    func getQueue() async throws -> [QueueSyncItem] {
        return getQueueResponse
    }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        lastPushedItems = items
        if echoMode {
            // Echo back what was pushed — simulates server accepting all items
            return QueueSyncResult(items: items, droppedItems: [])
        }
        return QueueSyncResult(items: getQueueResponse, droppedItems: [])
    }

    // MARK: - Stubs (not used in these tests)

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsSettingsSync: Bool { false }
}

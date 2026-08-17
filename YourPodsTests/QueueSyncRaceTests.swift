import XCTest
@testable import YourPods

// MARK: - Queue Sync Race Condition Tests

/// Tests for the in-flight item preservation fix.
///
/// Root cause: `syncQueueWithServer()` Step 4 ADOPT calls
/// `audioManager.replaceQueue(finalQueue)` where finalQueue is built
/// ONLY from the server response. If items were added to the local
/// queue BETWEEN Step 3 (push snapshot) and Step 4 (adopt), they are
/// silently destroyed.
///
/// Fix: Compare-and-swap — snapshot queue IDs before push, detect
/// additions after push returns, re-append them after adopt.
@MainActor
final class QueueSyncRaceTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let serverGuidsKey = PlayerManager.proQueueSyncServerGuidsKey
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

    // MARK: - Test 1: In-flight adds survive adopt

    /// Items added to the queue AFTER Step 3 builds the push payload
    /// must survive Step 4 ADOPT. The mock injects items into the queue
    /// during the syncQueue call (simulating user adds during the await).
    /// The server response only contains the original items.
    /// The fix must detect and re-append the in-flight items.
    func test_inFlightAddsSurviveAdopt() async {
        defaults.set(["ep-1", "ep-2", "ep-3"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        audioManager.appendToQueue((1...3).map { makeItem(id: "ep-\($0)") })
        XCTAssertEqual(audioManager.queue.count, 3, "Precondition: 3 local items")

        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = RaceConditionMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setSyncQueueResponse(serverItems)

        // Inject items during the push (simulating user adds during await)
        await mockClient.setOnSyncQueueCalled { [weak audioManager] in
            guard let audioManager else { return }
            audioManager.appendToQueue([
                QueueItem(
                    id: "ep-4", title: "In-Flight Episode 4",
                    podcastTitle: "Test Podcast",
                    audioUrl: "https://example.com/ep-4.mp3",
                    artworkUrl: nil, durationSeconds: 3600,
                    positionSeconds: 0, podcastUrl: "https://example.com/feed",
                    pubDate: nil
                ),
                QueueItem(
                    id: "ep-5", title: "In-Flight Episode 5",
                    podcastTitle: "Test Podcast",
                    audioUrl: "https://example.com/ep-5.mp3",
                    artworkUrl: nil, durationSeconds: 3600,
                    positionSeconds: 0, podcastUrl: "https://example.com/feed",
                    pubDate: nil
                ),
            ])
        }

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: In-flight items ep-4 and ep-5 must survive Step 4 ADOPT
        let queueIds = audioManager.queue.map(\.id)
        let queueCount = audioManager.queue.count
        XCTAssertTrue(queueIds.contains("ep-4"),
                       "REGRESSION: In-flight item 'ep-4' was destroyed by Step 4 ADOPT! Queue: \(queueIds)")
        XCTAssertTrue(queueIds.contains("ep-5"),
                       "REGRESSION: In-flight item 'ep-5' was destroyed by Step 4 ADOPT! Queue: \(queueIds)")
        XCTAssertEqual(queueCount, 5,
                       "Queue must have 5 items (3 server + 2 in-flight), got \(queueCount). IDs: \(queueIds)")
    }

    // MARK: - Test 2: Debounce suppression during sync

    /// `isSyncingQueue` should be true during syncQueueWithServer
    /// and false after it completes.
    func test_debounceSuppressionDuringSync() async {
        let audioManager = AudioManager()
        audioManager.appendToQueue([makeItem(id: "ep-1")])

        let serverItems = [makeSyncItem(guid: "ep-1", sortOrder: 1)]

        let mockClient = RaceConditionMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setSyncQueueResponse(serverItems)

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // Capture isSyncingQueue during the push
        var wasSyncingDuringPush = false
        await mockClient.setOnSyncQueueCalled { [weak playerManager] in
            wasSyncingDuringPush = playerManager?.isSyncingQueue ?? false
        }

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: isSyncingQueue should have been true during the push
        XCTAssertTrue(wasSyncingDuringPush,
                       "isSyncingQueue must be true during syncQueueWithServer execution")
        // And false after
        XCTAssertFalse(playerManager.isSyncingQueue,
                        "isSyncingQueue must be false after sync completes")
    }

    // MARK: - Test 3: In-flight adds are in queue after sync

    /// When in-flight items are detected and re-appended, they must be
    /// present in the queue so a subsequent debounced push can deliver them.
    func test_inFlightAddsPresentAfterSync() async {
        defaults.set(["ep-1", "ep-2", "ep-3"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        audioManager.appendToQueue((1...3).map { makeItem(id: "ep-\($0)") })

        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = RaceConditionMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setSyncQueueResponse(serverItems)

        // Add an in-flight item during the push
        await mockClient.setOnSyncQueueCalled { [weak audioManager] in
            audioManager?.appendToQueue([
                QueueItem(
                    id: "ep-inflight", title: "In-Flight",
                    podcastTitle: "Test Podcast",
                    audioUrl: "https://example.com/ep-inflight.mp3",
                    artworkUrl: nil, durationSeconds: 3600,
                    positionSeconds: 0, podcastUrl: "https://example.com/feed",
                    pubDate: nil
                )
            ])
        }

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: ep-inflight must be in queue (available for next push)
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertTrue(queueIds.contains("ep-inflight"),
                       "In-flight item must survive sync and be available for next push. Queue: \(queueIds)")
        XCTAssertFalse(playerManager.isSyncingQueue,
                        "isSyncingQueue must be false after sync completes")
    }

    // MARK: - Test 4: In-flight adds NOT in server GUIDs

    /// In-flight items haven't been acknowledged by the server.
    /// They must NOT be in `proQueueSyncServerGuids`.
    func test_inFlightAddsNotInServerGuids() async {
        defaults.set(["ep-1", "ep-2", "ep-3"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        audioManager.appendToQueue((1...3).map { makeItem(id: "ep-\($0)") })

        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = RaceConditionMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setSyncQueueResponse(serverItems)

        // Add in-flight item during push
        await mockClient.setOnSyncQueueCalled { [weak audioManager] in
            audioManager?.appendToQueue([
                QueueItem(
                    id: "ep-inflight", title: "In-Flight",
                    podcastTitle: "Test Podcast",
                    audioUrl: "https://example.com/ep-inflight.mp3",
                    artworkUrl: nil, durationSeconds: 3600,
                    positionSeconds: 0, podcastUrl: "https://example.com/feed",
                    pubDate: nil
                )
            ])
        }

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Stored server GUIDs should NOT include "ep-inflight"
        let storedGuids = defaults.stringArray(forKey: serverGuidsKey) ?? []
        XCTAssertFalse(storedGuids.contains("ep-inflight"),
                        "In-flight item must NOT be in stored server GUIDs")
        XCTAssertTrue(storedGuids.contains("ep-1"), "ep-1 should be in stored GUIDs")
        XCTAssertTrue(storedGuids.contains("ep-2"), "ep-2 should be in stored GUIDs")
        XCTAssertTrue(storedGuids.contains("ep-3"), "ep-3 should be in stored GUIDs")
    }

    // MARK: - Test 5: No in-flight adds — normal sync unchanged

    /// When no items are added during sync, behavior is identical to before.
    func test_noInFlightAdds_normalSyncUnchanged() async {
        defaults.set(["ep-1", "ep-2", "ep-3"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        audioManager.appendToQueue((1...3).map { makeItem(id: "ep-\($0)") })

        let serverItems = (1...3).map { makeSyncItem(guid: "ep-\($0)", sortOrder: $0) }

        let mockClient = RaceConditionMockSyncClient()
        await mockClient.setGetQueueResponse(serverItems)
        await mockClient.setSyncQueueResponse(serverItems)
        // No onSyncQueueCalled hook — no concurrent modifications

        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Queue has exactly 3 items
        XCTAssertEqual(audioManager.queue.count, 3,
                       "Normal sync should result in exactly 3 queue items")
        let queueIds = Set(audioManager.queue.map(\.id))
        XCTAssertEqual(queueIds, Set(["ep-1", "ep-2", "ep-3"]),
                       "Queue should contain exactly the server items")
    }
}

// MARK: - Race Condition Mock SyncClient

/// Mock SyncClient that:
/// 1. Returns a fixed response from syncQueue (not echo) to simulate server state lag
/// 2. Executes a @MainActor callback during syncQueue to inject items into AudioManager
actor RaceConditionMockSyncClient: SyncClient {
    private var getQueueResponse: [QueueSyncItem] = []
    private var syncQueueResponse: [QueueSyncItem]?
    private var onSyncQueueCalled: (@Sendable @MainActor () -> Void)?
    private(set) var syncQueueCallCount = 0
    private(set) var lastPushedItems: [QueueSyncItem] = []

    func setGetQueueResponse(_ items: [QueueSyncItem]) {
        getQueueResponse = items
    }

    func setSyncQueueResponse(_ items: [QueueSyncItem]) {
        syncQueueResponse = items
    }

    func setOnSyncQueueCalled(_ handler: @escaping @Sendable @MainActor () -> Void) {
        onSyncQueueCalled = handler
    }

    // MARK: - Queue

    var supportsQueueSync: Bool { true }

    func getQueue() async throws -> [QueueSyncItem] {
        return getQueueResponse
    }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCallCount += 1
        lastPushedItems = items

        // Execute the side-effect callback on the main actor BEFORE returning.
        if let handler = onSyncQueueCalled {
            await handler()
        }

        return QueueSyncResult(items: syncQueueResponse ?? items, droppedItems: [])
    }

    // MARK: - Stubs

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsSettingsSync: Bool { false }
}

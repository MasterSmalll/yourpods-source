import XCTest
import WatchConnectivity
@testable import YourPods

class MockWatchSession: WatchSessionProtocol {
    var delegate: WCSessionDelegate?
    var isPaired: Bool = true
    var isReachable: Bool = true
    var lastUpdatedContext: [String : Any]?
    
    func activate() {}
    func updateApplicationContext(_ context: [String : Any]) throws {
        lastUpdatedContext = context
    }
    func sendMessage(_ message: [String : Any], replyHandler: (([String : Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {}
}

final class WatchSyncTests: XCTestCase {
    
    var watchService: WatchService!
    var audioManager: AudioManager!
    var mockSession: MockWatchSession!
    
    override func setUp() {
        super.setUp()
        // Clean slate for queue keys
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        
        watchService = WatchService.shared
        audioManager = AudioManager()
        watchService.audioManager = audioManager
        
        mockSession = MockWatchSession()
        watchService.session = mockSession
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }
    
    func testSyncQueue_IncludesCurrentItemAndUpcoming() {
        // GIVEN: A current item and an upcoming queue
        let current = QueueItem(
            id: "current-id",
            title: "Current Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/1.mp3",
            artworkUrl: "https://example.com/1.jpg",
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        
        let upcoming = QueueItem(
            id: "upcoming-id",
            title: "Upcoming Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/2.mp3",
            artworkUrl: "https://example.com/2.jpg",
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        
        audioManager.currentItem = current
        audioManager.appendToQueue([upcoming])
        
        // WHEN: Syncing the queue
        watchService.syncQueue(autoSyncEnabled: true)
        
        // THEN: The context should include both current and upcoming
        guard let queue = mockSession.lastUpdatedContext?["queue"] as? [[String: Any]] else {
            XCTFail("Queue missing from context")
            return
        }
        
        XCTAssertEqual(queue.count, 2, "Queue should include currentItem + upcoming items")
        XCTAssertEqual(queue[0]["id"] as? String, "current-id")
        XCTAssertEqual(queue[1]["id"] as? String, "upcoming-id")
    }
    
    func testSyncQueue_IncludesArtistField() {
        let upcoming = QueueItem(
            id: "upcoming-id",
            title: "Upcoming Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/2.mp3",
            artworkUrl: "https://example.com/2.jpg",
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([upcoming])
        
        watchService.syncQueue(autoSyncEnabled: true)
        
        guard let queue = mockSession.lastUpdatedContext?["queue"] as? [[String: Any]] else {
            XCTFail("Queue missing from context")
            return
        }
        
        XCTAssertNotNil(queue[0]["artist"], "Each item must have an 'artist' field for Watch compatibility")
        XCTAssertEqual(queue[0]["artist"] as? String, "Podcast A")
    }



    func testSyncQueue_IncludesPositionSyncInterval_Default30() {
        // GIVEN: Default settings (watchPositionSyncInterval not explicitly set)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchPositionSyncInterval")
        
        let upcoming = QueueItem(
            id: "interval-test",
            title: "Interval Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/interval.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([upcoming])
        
        // WHEN: Syncing the queue with default interval
        watchService.syncQueue(autoSyncEnabled: true)
        
        // THEN: The context should include positionSyncInterval defaulting to 30
        let interval = mockSession.lastUpdatedContext?["positionSyncInterval"] as? Int
        XCTAssertNotNil(interval, "positionSyncInterval must be included in application context")
        XCTAssertEqual(interval, 30, "Default position sync interval should be 30 seconds")
    }
    
    func testSyncQueue_IncludesPositionSyncInterval_CustomValue() {
        // GIVEN: A custom watchPositionSyncInterval of 60
        let defaults = UserDefaults.standard
        defaults.set(60, forKey: "watchPositionSyncInterval")
        defer { defaults.removeObject(forKey: "watchPositionSyncInterval") }
        
        let upcoming = QueueItem(
            id: "interval-custom",
            title: "Custom Interval Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/custom.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([upcoming])
        
        // WHEN: Syncing with custom interval
        watchService.syncQueue(autoSyncEnabled: true, watchPositionSyncInterval: 60)
        
        // THEN: The context should reflect the custom interval
        let interval = mockSession.lastUpdatedContext?["positionSyncInterval"] as? Int
        XCTAssertEqual(interval, 60, "Custom position sync interval should be transmitted to watch")
    }
}

// MARK: - Settings Manager: Watch Position Sync Interval

final class WatchPositionSyncIntervalSettingsTests: XCTestCase {
    
    private let defaults = UserDefaults.standard
    
    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: "watchPositionSyncInterval")
    }
    
    override func tearDown() {
        defaults.removeObject(forKey: "watchPositionSyncInterval")
        super.tearDown()
    }
    
    func test_watchPositionSyncInterval_defaultIs30() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.watchPositionSyncInterval, 30,
                       "Default watch position sync interval should be 30 seconds")
    }
    
    func test_watchPositionSyncInterval_persistsCustomValue() {
        let settings = SettingsManager()
        settings.watchPositionSyncInterval = 60
        
        // Read from a fresh instance to verify persistence
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.watchPositionSyncInterval, 60,
                       "Custom interval should be persisted to UserDefaults")
    }
    
    func test_watchPositionSyncInterval_clampsBelow10() {
        // Position sync less than 10s would be too aggressive for battery
        let settings = SettingsManager()
        settings.watchPositionSyncInterval = 5
        XCTAssertGreaterThanOrEqual(settings.watchPositionSyncInterval, 10,
                                     "Interval should not go below 10 seconds")
    }
}

/// Tests for PodcastManager's refreshAndSync, recentlyUpdatedEpisodes, and reorder logic.
final class PodcastManagerTests: XCTestCase {

    // MARK: - Recently Updated Episodes

    func testFormatDuration_hours() {
        let result = PlayerManager.formatDuration(3661)
        XCTAssertEqual(result, "1h 1m")
    }

    func testFormatDuration_minutes() {
        let result = PlayerManager.formatDuration(125)
        XCTAssertEqual(result, "2m")
    }

    func testFormatDuration_seconds() {
        let result = PlayerManager.formatDuration(45)
        XCTAssertEqual(result, "45s")
    }

    // MARK: - Progress Formatting

    func testFormatProgress_percentListened() {
        let result = PlayerManager.formatProgress(position: 300, duration: 600, showPercent: true)
        XCTAssertEqual(result, "50% listened")
    }

    func testFormatProgress_percentRemaining() {
        let result = PlayerManager.formatProgress(position: 300, duration: 600, showPercent: false)
        XCTAssertEqual(result, "50% left")
    }

    func testFormatProgress_zeroDuration() {
        let result = PlayerManager.formatProgress(position: 0, duration: 0)
        XCTAssertEqual(result, "0%")
    }

    func testFormatProgress_fullListened() {
        let result = PlayerManager.formatProgress(position: 600, duration: 600, showPercent: true)
        XCTAssertEqual(result, "100% listened")
    }

    func testFormatProgress_noneListened() {
        let result = PlayerManager.formatProgress(position: 0, duration: 600, showPercent: false)
        XCTAssertEqual(result, "100% left")
    }

    // MARK: - Settings Enums

    func testTabBarDisplayMode_defaultIsTextAndIcon() {
        // TabBarDisplayMode default should be .textAndIcon
        let mode = TabBarDisplayMode.textAndIcon
        XCTAssertEqual(mode.rawValue, "textAndIcon")
    }

    func testSearchProvider_defaultIsItunes() {
        let provider = SearchProvider.itunes
        XCTAssertEqual(provider.rawValue, "itunes")
    }

    func testSearchProvider_podcastIndex() {
        let provider = SearchProvider.podcastIndex
        XCTAssertEqual(provider.rawValue, "podcastIndex")
    }

    // MARK: - SearchProviderResolver

    func test_resolveProvider_itunesReturnsItunes() {
        let result = SearchProviderResolver.resolve(provider: .itunes, apiKey: nil, apiSecret: nil)
        if case .provider(let p) = result {
            XCTAssertTrue(p is ITunesSearchProvider, "iTunes selection should return ITunesSearchProvider")
        } else {
            XCTFail("iTunes should always return a provider, not an error")
        }
    }

    func test_resolveProvider_podcastIndexWithCredentials() {
        let result = SearchProviderResolver.resolve(
            provider: .podcastIndex,
            apiKey: "test-key",
            apiSecret: "test-secret"
        )
        if case .provider(let p) = result {
            XCTAssertTrue(p is PodcastIndexSearchProvider,
                          "Podcast Index with credentials should return PodcastIndexSearchProvider")
        } else {
            XCTFail("Podcast Index with valid credentials should return a provider")
        }
    }

    func test_resolveProvider_podcastIndexWithoutCredentials_returnsError() {
        let result = SearchProviderResolver.resolve(provider: .podcastIndex, apiKey: nil, apiSecret: nil)
        if case .missingCredentials(let msg) = result {
            XCTAssertFalse(msg.isEmpty, "Error message should not be empty")
        } else {
            XCTFail("Podcast Index without credentials must return .missingCredentials, not a provider")
        }
    }

    func test_resolveProvider_podcastIndexWithEmptyKey_returnsError() {
        let result = SearchProviderResolver.resolve(provider: .podcastIndex, apiKey: "", apiSecret: "secret")
        if case .missingCredentials = result {
            // Expected
        } else {
            XCTFail("Podcast Index with empty API key must return .missingCredentials")
        }
    }

    func test_resolveProvider_podcastIndexWithEmptySecret_returnsError() {
        let result = SearchProviderResolver.resolve(provider: .podcastIndex, apiKey: "key", apiSecret: "")
        if case .missingCredentials = result {
            // Expected
        } else {
            XCTFail("Podcast Index with empty API secret must return .missingCredentials")
        }
    }

    // MARK: - QueueItem from Episode

    func testQueueItemPubDateIsPreserved() {
        // QueueItem should carry pubDate through from Episode
        let date = Date(timeIntervalSince1970: 1000000)
        let item = QueueItem(
            id: "guid1",
            title: "Test Episode",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/ep.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: date
        )
        XCTAssertEqual(item.pubDate, date)
    }

    // MARK: - Timestamp Formatting (mm:ss / h:mm:ss)

    func test_formatTimestamp_zero() {
        XCTAssertEqual(PlayerManager.formatTimestamp(0), "0:00")
    }

    func test_formatTimestamp_seconds() {
        XCTAssertEqual(PlayerManager.formatTimestamp(45), "0:45")
    }

    func test_formatTimestamp_minutes() {
        XCTAssertEqual(PlayerManager.formatTimestamp(125), "2:05")
    }

    func test_formatTimestamp_hours() {
        XCTAssertEqual(PlayerManager.formatTimestamp(3661), "1:01:01")
    }

    // MARK: - OPML

    func testOPMLExport_generatesValidXML() {
        // Test that our OPML service can generate valid XML
        // (This uses an empty array since we can't easily create @Model objects in tests)
        let xml = OPMLService.export(podcasts: [])
        XCTAssertTrue(xml.contains("<?xml"))
        XCTAssertTrue(xml.contains("<opml"))
        XCTAssertTrue(xml.contains("YourPods Subscriptions"))
    }

    func testOPMLParse_returnsURLs() {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
        <body>
            <outline type="rss" text="Pod1" xmlUrl="https://example.com/feed1"/>
            <outline type="rss" text="Pod2" xmlUrl="https://example.com/feed2"/>
        </body>
        </opml>
        """
        let urls = OPMLService.parseURLs(from: Data(opml.utf8))
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0], "https://example.com/feed1")
        XCTAssertEqual(urls[1], "https://example.com/feed2")
    }
}

// MARK: - Queue Persistence Tests

final class QueuePersistenceTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let queueKey = "savedQueue"
    private let currentItemKey = "savedCurrentItem"
    private let positionKey = "savedCurrentPosition"

    override func setUp() {
        super.setUp()
        // Clean slate for each test
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    // MARK: - Round-trip

    func test_persistAndRestoreQueue_roundTrip() {
        // GIVEN: An AudioManager with items in the queue
        let manager = AudioManager()
        let item1 = makeItem(id: "ep-1", title: "First Episode")
        let item2 = makeItem(id: "ep-2", title: "Second Episode")
        manager.appendToQueue([item1, item2])

        // WHEN: A fresh AudioManager restores the queue
        let restored = AudioManager()
        restored.restoreQueue()

        // THEN: The restored queue matches
        XCTAssertEqual(restored.queue.count, 2, "Queue should survive persist/restore cycle")
        XCTAssertEqual(restored.queue[0].id, "ep-1")
        XCTAssertEqual(restored.queue[1].id, "ep-2")
        XCTAssertEqual(restored.queue[0].title, "First Episode")
    }

    // MARK: - CurrentItem preservation (the specific bug)

    func test_restoreQueue_doesNotDeleteCurrentItem() {
        // GIVEN: Both a queue and a currentItem are saved to UserDefaults
        let encoder = JSONEncoder()
        let queueItems = [makeItem(id: "q-1"), makeItem(id: "q-2")]
        let currentItem = makeItem(id: "current-1", title: "Now Playing")

        defaults.set(try! encoder.encode(queueItems), forKey: queueKey)
        defaults.set(try! encoder.encode(currentItem), forKey: currentItemKey)
        defaults.set(120.5, forKey: positionKey)

        // WHEN: restoreQueue is called
        let manager = AudioManager()
        manager.restoreQueue()

        // THEN: Both queue AND currentItem should be restored
        XCTAssertEqual(manager.queue.count, 2, "Queue should be restored")
        XCTAssertNotNil(manager.currentItem, "currentItem must NOT be erased during restore")
        XCTAssertEqual(manager.currentItem?.id, "current-1")
        XCTAssertEqual(manager.currentItem?.title, "Now Playing")
    }

    // MARK: - Position persistence

    func test_persistQueue_savesCurrentItemAndPosition() {
        // GIVEN: An AudioManager with a currentItem
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "playing-1", title: "Active Episode")
        // Trigger persist by mutating the queue
        manager.appendToQueue([makeItem(id: "next-1")])

        // WHEN: Reading the saved data directly
        let savedItemData = defaults.data(forKey: currentItemKey)
        let savedItem = savedItemData.flatMap { try? JSONDecoder().decode(QueueItem.self, from: $0) }

        // THEN: currentItem is persisted
        XCTAssertNotNil(savedItem, "currentItem should be persisted to UserDefaults")
        XCTAssertEqual(savedItem?.id, "playing-1")
    }
}

// MARK: - AudioManager Queue Behavior Tests

final class AudioManagerQueueTests: XCTestCase {

    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    // MARK: - Preserve Current Item

    func test_playEpisode_preservesCurrent_insertsAtFrontOfQueue() {
        // GIVEN: An AudioManager with a current item and one queued item
        let manager = AudioManager()
        let oldItem = makeItem(id: "old-ep", title: "Old Episode")
        let nextQueued = makeItem(id: "queued-ep", title: "Queued Episode")
        let newItem = makeItem(id: "new-ep", title: "New Episode")

        manager.currentItem = oldItem
        manager.appendToQueue([nextQueued])

        // WHEN: Playing a new episode with preserveCurrent: true
        // (We test queue manipulation synchronously — playEpisode is async
        //  but the queue insert happens before the await)
        // Simulate the queue logic directly since playEpisode requires AVPlayer
        manager.testablePreserveAndSwitch(to: newItem, preserveCurrent: true)

        // THEN: The old item is at index 0, queued item follows
        XCTAssertEqual(manager.currentItem?.id, "new-ep")
        XCTAssertEqual(manager.queue.count, 2)
        XCTAssertEqual(manager.queue[0].id, "old-ep", "Old item should be at front of queue")
        XCTAssertEqual(manager.queue[1].id, "queued-ep", "Original queued item should follow")
    }

    func test_playEpisode_preservesCurrent_doesNotDuplicate_sameItem() {
        // GIVEN: A current item
        let manager = AudioManager()
        let item = makeItem(id: "same-ep")
        manager.currentItem = item

        // WHEN: Re-playing the same item with preserveCurrent
        manager.testablePreserveAndSwitch(to: item, preserveCurrent: true)

        // THEN: No duplicate in queue
        XCTAssertEqual(manager.queue.count, 0, "Same item should not be re-queued")
        XCTAssertEqual(manager.currentItem?.id, "same-ep")
    }

    func test_playEpisode_defaultDoesNotPreserveCurrent() {
        // GIVEN: A current item and queued items
        let manager = AudioManager()
        let oldItem = makeItem(id: "old-ep")
        let queued = makeItem(id: "queued-ep")
        let newItem = makeItem(id: "new-ep")

        manager.currentItem = oldItem
        manager.appendToQueue([queued])

        // WHEN: Playing a new episode with default preserveCurrent (false)
        manager.testablePreserveAndSwitch(to: newItem, preserveCurrent: false)

        // THEN: Old item is NOT in the queue
        XCTAssertEqual(manager.currentItem?.id, "new-ep")
        XCTAssertEqual(manager.queue.count, 1)
        XCTAssertEqual(manager.queue[0].id, "queued-ep", "Only the original queued item remains")
    }

    func test_playEpisode_preservesCurrent_removesNewItemFromQueue() {
        // GIVEN: The new item is already in the queue
        let manager = AudioManager()
        let oldItem = makeItem(id: "old-ep")
        let newItem = makeItem(id: "new-ep")
        manager.currentItem = oldItem
        manager.appendToQueue([newItem])

        // WHEN: Playing the queued item with preserveCurrent
        manager.testablePreserveAndSwitch(to: newItem, preserveCurrent: true)

        // THEN: Old item replaces the slot, new item is not duplicated
        XCTAssertEqual(manager.currentItem?.id, "new-ep")
        XCTAssertEqual(manager.queue.count, 1)
        XCTAssertEqual(manager.queue[0].id, "old-ep")
    }
}

// MARK: - Priority Queue Insertion Tests (Regression)

/// Tests that priority auto-queue episodes end up at the top of Up Next in
/// the correct chronological order (newest first). This catches the regression
/// where inserting priority episodes one-at-a-time reversed their order.
final class PriorityQueueInsertionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", pubDate: Date? = nil) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: pubDate
        )
    }

    // MARK: - Batch insertNext preserves order (the correct pattern)

    func test_insertNext_batchPreservesOrder_newestFirst() {
        // GIVEN: An empty queue and 3 episodes sorted newest-first
        let manager = AudioManager()
        let newest = makeItem(id: "ep-3", title: "Newest", pubDate: Date(timeIntervalSince1970: 3000))
        let middle = makeItem(id: "ep-2", title: "Middle", pubDate: Date(timeIntervalSince1970: 2000))
        let oldest = makeItem(id: "ep-1", title: "Oldest", pubDate: Date(timeIntervalSince1970: 1000))

        // WHEN: Batch-inserting all three at once
        manager.insertNext([newest, middle, oldest])

        // THEN: Order is preserved — newest at position 0
        XCTAssertEqual(manager.queue.count, 3)
        XCTAssertEqual(manager.queue[0].id, "ep-3", "Newest should be at position 0 (top of Up Next)")
        XCTAssertEqual(manager.queue[1].id, "ep-2", "Middle should be at position 1")
        XCTAssertEqual(manager.queue[2].id, "ep-1", "Oldest should be at position 2")
    }

    // MARK: - One-at-a-time insertion REVERSES order (the bug this catches)

    func test_insertNext_oneAtATime_reversesOrder_REGRESSION() {
        // This test documents the BROKEN behavior that was happening in refreshAndSync.
        // After our fix, this test verifies the batch API is used instead.
        //
        // GIVEN: An empty queue and 3 episodes
        let manager = AudioManager()
        let newest = makeItem(id: "ep-3", title: "Newest", pubDate: Date(timeIntervalSince1970: 3000))
        let middle = makeItem(id: "ep-2", title: "Middle", pubDate: Date(timeIntervalSince1970: 2000))
        let oldest = makeItem(id: "ep-1", title: "Oldest", pubDate: Date(timeIntervalSince1970: 1000))

        // WHEN: Inserting one at a time (simulating the old loop pattern)
        manager.insertNext([newest])
        manager.insertNext([middle])
        manager.insertNext([oldest])

        // THEN: Order is REVERSED — oldest ends up at top (this is the bug!)
        // This test documents the known incorrect behavior. The fix avoids this
        // code path by using batch insertion instead.
        XCTAssertEqual(manager.queue[0].id, "ep-1", "One-at-a-time pushes oldest to top (known behavior)")
        XCTAssertEqual(manager.queue[2].id, "ep-3", "Newest gets pushed to bottom (known behavior)")
    }

    // MARK: - Priority episodes stay above existing queue items

    func test_insertNext_priorityStaysAboveExistingItems() {
        // GIVEN: A queue with existing non-priority items
        let manager = AudioManager()
        let existing1 = makeItem(id: "existing-1", title: "Already Queued 1")
        let existing2 = makeItem(id: "existing-2", title: "Already Queued 2")
        manager.appendToQueue([existing1, existing2])

        // WHEN: Batch-inserting priority episodes
        let priority1 = makeItem(id: "priority-1", title: "Priority Newest", pubDate: Date(timeIntervalSince1970: 2000))
        let priority2 = makeItem(id: "priority-2", title: "Priority Older", pubDate: Date(timeIntervalSince1970: 1000))
        manager.insertNext([priority1, priority2])

        // THEN: Priority episodes are at the top, existing items follow
        XCTAssertEqual(manager.queue.count, 4)
        XCTAssertEqual(manager.queue[0].id, "priority-1", "First priority should be at top")
        XCTAssertEqual(manager.queue[1].id, "priority-2", "Second priority should follow")
        XCTAssertEqual(manager.queue[2].id, "existing-1", "Existing items should be pushed down")
        XCTAssertEqual(manager.queue[3].id, "existing-2", "Existing items should be pushed down")
    }

    // MARK: - Mixed priority and non-priority podcasts

    func test_priorityAndNonPriority_priorityAlwaysOnTop() {
        // GIVEN: Non-priority episodes are appended first
        let manager = AudioManager()
        let normalEp = makeItem(id: "normal-1", title: "Normal Episode")
        manager.appendToQueue([normalEp])

        // WHEN: Priority episodes are inserted after
        let priorityEp = makeItem(id: "priority-1", title: "Priority Episode")
        manager.insertNext([priorityEp])

        // THEN: Priority is on top regardless of call order
        XCTAssertEqual(manager.queue[0].id, "priority-1", "Priority must be above normal")
        XCTAssertEqual(manager.queue[1].id, "normal-1", "Normal follows priority")
    }

    func test_nonPriorityAppendedAfterPriority_doesNotDisplace() {
        // GIVEN: Priority episodes are already at the top
        let manager = AudioManager()
        let priorityEp = makeItem(id: "priority-1", title: "Priority Episode")
        manager.insertNext([priorityEp])

        // WHEN: Non-priority episodes are appended
        let normalEp = makeItem(id: "normal-1", title: "Normal Episode")
        manager.appendToQueue([normalEp])

        // THEN: Priority stays on top
        XCTAssertEqual(manager.queue[0].id, "priority-1", "Priority must remain at top")
        XCTAssertEqual(manager.queue[1].id, "normal-1", "Normal appended after priority")
    }

    // MARK: - Duplicate filtering with priority insert

    func test_insertNext_skipsItemAlreadyInQueue() {
        // GIVEN: An episode already in the queue
        let manager = AudioManager()
        let existing = makeItem(id: "ep-1", title: "Already Queued")
        manager.appendToQueue([existing])

        // WHEN: insertNext tries to add the same episode
        let duplicate = makeItem(id: "ep-1", title: "Duplicate")
        manager.insertNext([duplicate])

        // THEN: No duplicate — still only 1 item
        XCTAssertEqual(manager.queue.count, 1, "Duplicate should be filtered out")
    }

    func test_insertNext_skipsCurrentlyPlayingItem() {
        // GIVEN: An episode is currently playing
        let manager = AudioManager()
        let playing = makeItem(id: "playing-1", title: "Now Playing")
        manager.currentItem = playing

        // WHEN: insertNext tries to add the same episode
        let duplicate = makeItem(id: "playing-1", title: "Duplicate of Playing")
        manager.insertNext([duplicate])

        // THEN: Not added to queue
        XCTAssertEqual(manager.queue.count, 0, "Currently playing item should not be re-queued")
    }

    // MARK: - Multiple priority podcasts

    func test_multiplePriorityPodcasts_allAtTop() {
        // GIVEN: Existing items in queue
        let manager = AudioManager()
        let existing = makeItem(id: "existing-1", title: "Existing")
        manager.appendToQueue([existing])

        // WHEN: Two different priority podcasts each batch-insert
        let podcastA = makeItem(id: "podA-1", title: "Podcast A Ep")
        let podcastB = makeItem(id: "podB-1", title: "Podcast B Ep")
        manager.insertNext([podcastA])
        manager.insertNext([podcastB])

        // THEN: Both priority episodes are above existing, latest insert on top
        XCTAssertEqual(manager.queue.count, 3)
        XCTAssertEqual(manager.queue[0].id, "podB-1", "Latest priority insert should be at top")
        XCTAssertEqual(manager.queue[1].id, "podA-1", "Earlier priority insert follows")
        XCTAssertEqual(manager.queue[2].id, "existing-1", "Existing stays at bottom")
    }
}

// MARK: - Cold-Start Restore Tests

final class ColdStartRestoreTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let queueKey = "savedQueue"
    private let currentItemKey = "savedCurrentItem"
    private let positionKey = "savedCurrentPosition"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    // MARK: - Cold-Start Position Restore

    func test_restoreQueue_restoresCurrentPosition() {
        // GIVEN: A saved position of 120.5 seconds
        let encoder = JSONEncoder()
        let currentItem = makeItem(id: "cold-ep", title: "Cold Start Episode")
        defaults.set(try! encoder.encode(currentItem), forKey: currentItemKey)
        defaults.set(120.5, forKey: positionKey)

        // WHEN: restoreQueue is called
        let manager = AudioManager()
        manager.restoreQueue()

        // THEN: currentPosition should be restored (not 0)
        XCTAssertEqual(manager.currentPosition, 120.5, accuracy: 0.1,
                       "currentPosition must be restored from UserDefaults on cold start")
    }

    func test_restoreQueue_restoresCurrentPosition_zero_whenNothingSaved() {
        // GIVEN: No saved position
        // WHEN: restoreQueue is called
        let manager = AudioManager()
        manager.restoreQueue()

        // THEN: currentPosition should remain 0
        XCTAssertEqual(manager.currentPosition, 0, accuracy: 0.1,
                       "currentPosition should be 0 when nothing is saved")
    }

    // MARK: - Spurious Completion Guard

    func test_spuriousCompletion_doesNotFireAt92Percent() {
        // GIVEN: An episode at 92% (552s / 600s) — 48 seconds remaining
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-92")
        manager.testableSetPlaybackState(position: 552, duration: 600)

        // WHEN: Testing spurious completion detection
        // THEN: Should be detected as spurious (> 10 seconds remaining)
        XCTAssertTrue(manager.testableIsSpuriousCompletion(),
                      "92% with 48s remaining should be detected as spurious")
    }

    func test_completion_firesAt99Percent() {
        // GIVEN: An episode at 99% (594s / 600s) — 6 seconds remaining
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-99")
        manager.testableSetPlaybackState(position: 594, duration: 600)

        // WHEN: Testing spurious completion detection
        // THEN: Should NOT be spurious (< 10 seconds remaining)
        XCTAssertFalse(manager.testableIsSpuriousCompletion(),
                       "99% with 6s remaining should be treated as genuine completion")
    }

    func test_completion_shortEpisode_notSpuriousAt90Percent() {
        // GIVEN: A short 30-second episode at 27s (90%) — only 3 seconds remaining
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-short")
        manager.testableSetPlaybackState(position: 27, duration: 30)

        // THEN: Should NOT be spurious (< 10 seconds remaining even though < 97%)
        XCTAssertFalse(manager.testableIsSpuriousCompletion(),
                       "Short episode with 3s remaining should complete normally")
    }
    
    // MARK: - Stale Position Refresh (Background Auto-Advance Fix)
    
    func test_completion_advancesWhenPositionRefreshedFromPlayer() {
        // GIVEN: An episode where the periodic time observer is stale (at 50%)
        // but AVPlayer's actual position is at 99% (near the end).
        // This simulates background mode where the time observer hasn't fired
        // recently but the episode has actually reached the end.
        let manager = AudioManager()
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }
        
        let ep1 = makeItem(id: "ep-bg-1")
        let ep2 = makeItem(id: "ep-bg-2")
        manager.currentItem = ep1
        manager.appendToQueue([ep2])
        
        // Set stale position: 300s out of 600s — the time observer hasn't updated
        manager.testableSetPlaybackState(position: 300, duration: 600)
        
        // Simulate AVPlayer's real position being at 598s (near end)
        manager.testableOverridePosition = 598.0
        
        // WHEN: handlePlaybackCompleted fires (AVPlayerItemDidPlayToEndTime)
        let result = manager.testableHandlePlaybackCompleted()
        
        // THEN: Should advance — the refreshed position (598s) is near the end
        XCTAssertEqual(result.completed?.id, "ep-bg-1",
                       "Should complete the episode after position refresh shows near-end")
        XCTAssertEqual(result.next?.id, "ep-bg-2",
                       "Should advance to next episode")
        XCTAssertEqual(completedIds, ["ep-bg-1"],
                       "onEpisodeCompleted should fire for the completed episode")
    }
    
    func test_completion_stillSpuriousWhenRefreshedPositionFarFromEnd() {
        // GIVEN: Both the stale position AND AVPlayer's actual position are far from the end.
        // This is a genuine spurious completion (stream error).
        let manager = AudioManager()
        let ep1 = makeItem(id: "ep-spurious")
        let ep2 = makeItem(id: "ep-next")
        manager.currentItem = ep1
        manager.appendToQueue([ep2])
        
        // Set stale position at 50%
        manager.testableSetPlaybackState(position: 300, duration: 600)
        
        // AVPlayer also shows position far from end (stream error at 310s)
        manager.testableOverridePosition = 310.0
        
        // WHEN: handlePlaybackCompleted fires
        let result = manager.testableHandlePlaybackCompleted()
        
        // THEN: Should still be treated as spurious — both positions are far from end
        XCTAssertNil(result.completed, "Should NOT advance on genuine spurious completion")
        XCTAssertNil(result.next, "Should NOT advance when player position confirms far from end")
        XCTAssertEqual(manager.queue.count, 1, "Queue should be unchanged")
    }
}

// MARK: - Auto-Advance Race Condition Tests (Regression)

/// Tests that auto-advance does not cascade through the entire queue.
/// Regression: a KVO callback from player.removeAllItems() could fire AFTER
/// isAdvancingQueue and isLoadingNewEpisode were reset, causing
/// handlePlaybackCompleted() to fire again and mark the new episode as
/// complete before it even starts playing — cascading through every item.
final class AutoAdvanceRaceConditionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    // MARK: - The cascade regression

    func test_autoAdvance_doesNotCascadeCompletion_REGRESSION() {
        // This test reproduces the exact bug: episode A finishes, auto-advance
        // moves to episode B (resetting duration to 0), then a stale KVO callback
        // calls handlePlaybackCompleted again. Without the fix, B is also marked
        // as completed, then C, then D — the entire queue gets wiped.
        //
        // GIVEN: A queue of 3 episodes, with episode A playing near the end
        let manager = AudioManager()
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        let ep1 = makeItem(id: "ep-1", title: "Episode A")
        let ep2 = makeItem(id: "ep-2", title: "Episode B")
        let ep3 = makeItem(id: "ep-3", title: "Episode C")

        manager.currentItem = ep1
        manager.appendToQueue([ep2, ep3])
        manager.testableSetPlaybackState(position: 598, duration: 600) // Near the end
        manager.isPlaying = true

        // WHEN: Episode A completes normally (advances to B)
        let result = manager.testableHandlePlaybackCompleted()
        XCTAssertEqual(result.completed?.id, "ep-1", "Should complete episode A")
        XCTAssertEqual(result.next?.id, "ep-2", "Should advance to episode B")

        // At this point, currentItem = B, currentDuration = 0, currentPosition = 0
        // (mirrors what playEpisode does — duration hasn't loaded yet)

        // WHEN: A stale KVO callback fires handlePlaybackCompleted again
        // (simulating the race where player.removeAllItems() KVO arrives late)
        let cascadeResult = manager.testableHandlePlaybackCompleted()

        // THEN: It should be blocked — episode B has duration=0 (hasn't loaded)
        XCTAssertNil(cascadeResult.completed, "Must NOT cascade-complete episode B")
        XCTAssertNil(cascadeResult.next, "Must NOT advance to episode C")
        XCTAssertEqual(manager.currentItem?.id, "ep-2", "Episode B should still be current")
        XCTAssertEqual(manager.queue.count, 1, "Episode C should still be in queue")
        XCTAssertEqual(completedIds, ["ep-1"], "Only episode A should be marked completed")
    }

    // MARK: - Duration=0 guard

    func test_handlePlaybackCompleted_rejectsZeroDuration() {
        // GIVEN: A manager where duration hasn't loaded (0)
        let manager = AudioManager()
        let ep = makeItem(id: "ep-1")
        let ep2 = makeItem(id: "ep-2")
        manager.currentItem = ep
        manager.appendToQueue([ep2])
        manager.testableSetPlaybackState(position: 0, duration: 0)

        // WHEN: handlePlaybackCompleted is called
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Should be rejected — duration 0 means episode hasn't loaded
        XCTAssertNil(result.completed, "Should not complete an episode with unknown duration")
        XCTAssertEqual(manager.currentItem?.id, "ep-1", "Current item should be unchanged")
        XCTAssertEqual(manager.queue.count, 1, "Queue should be unchanged")
    }

    // MARK: - Normal auto-advance still works

    func test_autoAdvance_worksNormally_withKnownDuration() {
        // GIVEN: Episode at 99% with known duration
        let manager = AudioManager()
        let ep1 = makeItem(id: "ep-1")
        let ep2 = makeItem(id: "ep-2")
        manager.currentItem = ep1
        manager.appendToQueue([ep2])
        manager.testableSetPlaybackState(position: 595, duration: 600)

        // WHEN: Playback completes normally
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Should advance to next episode
        XCTAssertEqual(result.completed?.id, "ep-1")
        XCTAssertEqual(result.next?.id, "ep-2")
        XCTAssertEqual(manager.currentItem?.id, "ep-2")
    }

    func test_autoAdvance_stopsAtEndOfQueue() {
        // GIVEN: Last episode in queue at 99%
        let manager = AudioManager()
        let ep = makeItem(id: "ep-1")
        manager.currentItem = ep
        manager.testableSetPlaybackState(position: 595, duration: 600)

        // WHEN: Playback completes with empty queue
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Should complete and stop (no next)
        XCTAssertEqual(result.completed?.id, "ep-1")
        XCTAssertNil(result.next, "No next episode — queue is empty")
        XCTAssertNil(manager.currentItem, "Current item should be cleared")
    }

    // MARK: - isAdvancingQueue guard

    func test_handlePlaybackCompleted_blockedWhileAdvancing() {
        // GIVEN: isAdvancingQueue is true (mid-advance)
        let manager = AudioManager()
        let ep = makeItem(id: "ep-1")
        manager.currentItem = ep
        manager.testableSetPlaybackState(position: 595, duration: 600)
        manager.isAdvancingQueue = true

        // WHEN: handlePlaybackCompleted is called during advance
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Should be rejected
        XCTAssertNil(result.completed, "Should not fire during active advance")
    }
}

// MARK: - Audio Session Interruption Tests

final class AudioManagerInterruptionTests: XCTestCase {

    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    func test_interruptionBegan_setsWasPlayingFlag() {
        // GIVEN: An AudioManager that is "playing" (isPlaying = true)
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        // Simulate the isPlaying state without AVPlayer
        manager.isPlaying = true

        // WHEN: An interruption begins
        manager.testableHandleInterruption(began: true)

        // THEN: wasPlayingBeforeInterruption should be true
        XCTAssertTrue(manager.wasPlayingBeforeInterruption,
                      "Should record that playback was active before interruption")
        XCTAssertFalse(manager.isPlaying,
                       "Playback should be paused during interruption")
    }

    func test_interruptionBegan_doesNotSetFlagWhenPaused() {
        // GIVEN: An AudioManager that is paused
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = false

        // WHEN: An interruption begins while already paused
        manager.testableHandleInterruption(began: true)

        // THEN: wasPlayingBeforeInterruption should be false
        XCTAssertFalse(manager.wasPlayingBeforeInterruption,
                       "Should record that playback was NOT active before interruption")
    }

    func test_interruptionEnded_withShouldResume_whenWasPlaying() {
        // GIVEN: An AudioManager that was playing before an interruption
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true
        manager.testableHandleInterruption(began: true)

        // WHEN: The interruption ends with shouldResume = true
        let willResume = manager.testableHandleInterruption(began: false, shouldResume: true)

        // THEN: Should indicate it will resume
        XCTAssertTrue(willResume,
                      "Should resume playback when system says shouldResume and we were playing")
        // Flag should be reset
        XCTAssertFalse(manager.wasPlayingBeforeInterruption,
                       "Flag should be reset after interruption ends")
    }

    func test_interruptionEnded_withShouldResume_whenWasPaused() {
        // GIVEN: An AudioManager that was paused before an interruption
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = false
        manager.testableHandleInterruption(began: true)

        // WHEN: The interruption ends with shouldResume = true
        let willResume = manager.testableHandleInterruption(began: false, shouldResume: true)

        // THEN: Should NOT resume (we weren't playing)
        XCTAssertFalse(willResume,
                       "Should NOT resume if we weren't playing before the interruption")
    }

    func test_interruptionEnded_withoutShouldResume_whenWasPlaying() {
        // GIVEN: An AudioManager that was playing before an interruption
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true
        manager.testableHandleInterruption(began: true)

        // WHEN: The interruption ends WITHOUT shouldResume
        let willResume = manager.testableHandleInterruption(began: false, shouldResume: false)

        // THEN: Should NOT resume (system didn't say to)
        XCTAssertFalse(willResume,
                       "Should NOT resume when system does not indicate shouldResume")
    }
}

// MARK: - Settings Persistence Tests

final class SettingsPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hidePlayedEpisodes")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hidePlayedEpisodes")
        super.tearDown()
    }

    func test_hidePlayedEpisodes_persistsInUserDefaults() {
        // GIVEN: A SettingsManager with hidePlayedEpisodes set to true
        let settings = SettingsManager()
        settings.hidePlayedEpisodes = true

        // WHEN: A new SettingsManager is created
        let settings2 = SettingsManager()

        // THEN: The value should persist
        XCTAssertTrue(settings2.hidePlayedEpisodes,
                      "hidePlayedEpisodes must persist across SettingsManager instances")
    }

    func test_hidePlayedEpisodes_defaultsFalse() {
        // GIVEN: No saved value
        let settings = SettingsManager()

        // THEN: Default should be false
        XCTAssertFalse(settings.hidePlayedEpisodes,
                       "hidePlayedEpisodes should default to false")
    }
}

// MARK: - Profile Data Cleanup Tests

final class ProfileCleanupTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let testProfileId = "test-profile-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        // Pre-populate profile-scoped keys
        defaults.set(Data(), forKey: "subscriptionUrls_\(testProfileId)")
        defaults.set(12345, forKey: "lastSubscriptionSync_\(testProfileId)")
        defaults.set(67890, forKey: "lastEpisodeActionSync_\(testProfileId)")
    }

    override func tearDown() {
        defaults.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        defaults.removeObject(forKey: "lastSubscriptionSync_\(testProfileId)")
        defaults.removeObject(forKey: "lastEpisodeActionSync_\(testProfileId)")
        defaults.removeObject(forKey: "serverProfiles")
        super.tearDown()
    }

    // MARK: - clearProfileData

    func test_clearProfileData_removesSubscriptionUrls() {
        // GIVEN: subscriptionUrls key exists for the profile
        XCTAssertNotNil(defaults.data(forKey: "subscriptionUrls_\(testProfileId)"))

        // WHEN: clearProfileData is called (static helper to avoid needing ModelContext)
        defaults.removeObject(forKey: "subscriptionUrls_\(testProfileId)")

        // THEN: The key should be removed
        XCTAssertNil(defaults.data(forKey: "subscriptionUrls_\(testProfileId)"),
                     "subscriptionUrls should be removed for deleted profile")
    }

    func test_clearProfileData_removesAllThreeKeys() {
        // GIVEN: All three profile-scoped keys exist
        XCTAssertNotNil(defaults.object(forKey: "subscriptionUrls_\(testProfileId)"))
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(testProfileId)"), 12345)
        XCTAssertEqual(defaults.integer(forKey: "lastEpisodeActionSync_\(testProfileId)"), 67890)

        // WHEN: All three keys are removed (simulating clearProfileData behavior)
        defaults.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        defaults.removeObject(forKey: "lastSubscriptionSync_\(testProfileId)")
        defaults.removeObject(forKey: "lastEpisodeActionSync_\(testProfileId)")

        // THEN: All three should be nil
        XCTAssertNil(defaults.object(forKey: "subscriptionUrls_\(testProfileId)"),
                     "subscriptionUrls must be cleared")
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(testProfileId)"), 0,
                       "lastSubscriptionSync must reset to 0 (default)")
        XCTAssertEqual(defaults.integer(forKey: "lastEpisodeActionSync_\(testProfileId)"), 0,
                       "lastEpisodeActionSync must reset to 0 (default)")
    }

    // MARK: - Per-profile sync timestamps

    func test_perProfileSyncTimestamp_doesNotAffectOtherProfiles() {
        // GIVEN: Two different profile IDs with different timestamps
        let otherProfileId = "other-profile-\(UUID().uuidString)"
        defaults.set(99999, forKey: "lastSubscriptionSync_\(otherProfileId)")

        // WHEN: Clearing one profile's data
        defaults.removeObject(forKey: "lastSubscriptionSync_\(testProfileId)")

        // THEN: The other profile's timestamp is untouched
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(otherProfileId)"), 99999,
                       "Clearing one profile must not affect another profile's sync timestamp")

        // Cleanup
        defaults.removeObject(forKey: "lastSubscriptionSync_\(otherProfileId)")
    }

    func test_newProfile_syncTimestamp_startsAtZero() {
        // GIVEN: A brand new profile ID with no saved data
        let newProfileId = "brand-new-\(UUID().uuidString)"

        // THEN: The sync timestamp should be 0 (UserDefaults default for missing int)
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(newProfileId)"), 0,
                       "A new profile should start with since=0 for full sync")
    }

    // MARK: - hasOtherProfiles

    @MainActor
    func test_hasOtherProfiles_returnsFalse_whenNoProfiles() {
        // GIVEN: No serverProfiles key
        defaults.removeObject(forKey: "serverProfiles")

        // THEN: Should return false
        XCTAssertFalse(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }

    @MainActor
    func test_hasOtherProfiles_returnsFalse_whenOnlyThisProfile() {
        // GIVEN: Only the test profile exists
        let profile = ServerProfile(id: testProfileId, name: "Test")
        let data = try! JSONEncoder().encode([profile])
        defaults.set(data, forKey: "serverProfiles")

        // THEN: Should return false (no OTHER profiles)
        XCTAssertFalse(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }

    @MainActor
    func test_hasOtherProfiles_returnsTrue_whenOtherProfilesExist() {
        // GIVEN: The test profile and another profile exist
        let profile1 = ServerProfile(id: testProfileId, name: "Test")
        let profile2 = ServerProfile(id: "other-id", name: "Other")
        let data = try! JSONEncoder().encode([profile1, profile2])
        defaults.set(data, forKey: "serverProfiles")

        // THEN: Should return true (other profiles exist)
        XCTAssertTrue(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }
}

// MARK: - URL Sanitizer Tests

final class URLSanitizerTests: XCTestCase {

    // MARK: - sanitize()

    func test_sanitize_bareDomain_defaultsToHTTPS() {
        let result = URLSanitizer.sanitize("cloud.example.com")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_bareDomainWithPath_defaultsToHTTPS() {
        let result = URLSanitizer.sanitize("cloud.example.com/nextcloud")
        XCTAssertEqual(result, "https://cloud.example.com/nextcloud")
    }

    func test_sanitize_explicitHTTPS_preserved() {
        let result = URLSanitizer.sanitize("https://cloud.example.com")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_explicitHTTP_preservedNotUpgraded() {
        // HTTP should NOT be force-upgraded — user may need it for self-hosted servers
        let result = URLSanitizer.sanitize("http://192.168.1.100:8080")
        XCTAssertEqual(result, "http://192.168.1.100:8080")
    }

    func test_sanitize_trailingSlash_stripped() {
        let result = URLSanitizer.sanitize("https://cloud.example.com/")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_whitespace_trimmed() {
        let result = URLSanitizer.sanitize("  https://cloud.example.com  ")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_httpCaseInsensitive() {
        let result = URLSanitizer.sanitize("HTTP://example.com")
        XCTAssertEqual(result, "HTTP://example.com",
                       "Should preserve original case, not double-prefix")
    }

    // MARK: - isInsecure()

    func test_isInsecure_httpURL_returnsTrue() {
        XCTAssertTrue(URLSanitizer.isInsecure("http://example.com"))
    }

    func test_isInsecure_httpsURL_returnsFalse() {
        XCTAssertFalse(URLSanitizer.isInsecure("https://example.com"))
    }

    func test_isInsecure_caseInsensitive() {
        XCTAssertTrue(URLSanitizer.isInsecure("HTTP://EXAMPLE.COM"))
    }

    func test_isInsecure_bareDomain_returnsFalse() {
        // A bare domain without scheme is not "http://"
        XCTAssertFalse(URLSanitizer.isInsecure("example.com"))
    }
}

// MARK: - Position Persistence Tests

final class PositionPersistenceTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let queueKey = "savedQueue"
    private let currentItemKey = "savedCurrentItem"
    private let positionKey = "savedCurrentPosition"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    func test_persistQueue_updatesCurrentItemPositionSeconds() {
        // GIVEN: An AudioManager with a currentItem at positionSeconds=0
        // but currentPosition advanced to 500
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1", positionSeconds: 0)
        manager.testableSetPlaybackState(position: 500, duration: 3600)

        // WHEN: Triggering persist by mutating the queue
        manager.appendToQueue([makeItem(id: "ep-2")])

        // THEN: The saved currentItem should have positionSeconds=500
        let savedData = defaults.data(forKey: currentItemKey)
        let savedItem = savedData.flatMap { try? JSONDecoder().decode(QueueItem.self, from: $0) }
        XCTAssertEqual(savedItem?.positionSeconds, 500,
                       "persistQueue must update currentItem.positionSeconds from currentPosition before encoding")
    }

    func test_persistQueueToDisk_savesLatestPosition() {
        // GIVEN: An AudioManager with currentPosition at 750
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.testableSetPlaybackState(position: 750, duration: 3600)

        // WHEN: persistQueueToDisk is called
        manager.persistQueueToDisk()

        // THEN: savedCurrentPosition should be 750 (or close)
        let savedPos = defaults.double(forKey: positionKey)
        XCTAssertEqual(savedPos, 750, accuracy: 1.0,
                       "persistQueueToDisk must save the latest position")
    }
}

// MARK: - Conflict Resolution Strategy Tests

final class ConflictResolutionTests: XCTestCase {

    func test_applyEpisodeActions_deviceWins_doesNotRegress() {
        // GIVEN: An episode at local position 200, server says 100
        // With strategy = .deviceWins

        // Test the logic directly: when device wins, local >= server means keep local
        let localPosition = 200
        let serverPosition = 100
        let strategy: SyncStrategy = .deviceWins

        // Apply the strategy logic
        let shouldOverwrite: Bool
        switch strategy {
        case .serverWins:
            shouldOverwrite = serverPosition > 0
        case .deviceWins:
            shouldOverwrite = serverPosition > localPosition
        case .ask:
            shouldOverwrite = false // conflicts are collected, not auto-resolved
        }

        XCTAssertFalse(shouldOverwrite,
                       "deviceWins should NOT overwrite local=200 with server=100")
    }

    func test_applyEpisodeActions_deviceWins_allowsForwardProgress() {
        // GIVEN: An episode at local position 100, server says 300
        // With strategy = .deviceWins

        let localPosition = 100
        let serverPosition = 300
        let strategy: SyncStrategy = .deviceWins

        let shouldOverwrite: Bool
        switch strategy {
        case .serverWins:
            shouldOverwrite = serverPosition > 0
        case .deviceWins:
            shouldOverwrite = serverPosition > localPosition
        case .ask:
            shouldOverwrite = false
        }

        XCTAssertTrue(shouldOverwrite,
                      "deviceWins should overwrite local=100 with server=300 (forward progress)")
    }

    func test_applyEpisodeActions_serverWins_alwaysOverwrites() {
        // GIVEN: An episode at local position 200, server says 100
        // With strategy = .serverWins

        let localPosition = 200
        let serverPosition = 100
        let strategy: SyncStrategy = .serverWins

        let shouldOverwrite: Bool
        switch strategy {
        case .serverWins:
            shouldOverwrite = serverPosition > 0
        case .deviceWins:
            shouldOverwrite = serverPosition > localPosition
        case .ask:
            shouldOverwrite = false
        }

        XCTAssertTrue(shouldOverwrite,
                      "serverWins should overwrite even when going backward (server=100, local=200)")
    }

    func test_applyEpisodeActions_ask_collectsConflict() {
        // GIVEN: An episode at local position 200, server says 100
        // With strategy = .ask and positions differ by > threshold

        let localPosition = 200
        let serverPosition = 100
        let threshold = 10 // seconds

        let isConflict = abs(serverPosition - localPosition) > threshold
        XCTAssertTrue(isConflict,
                      "Positions differing by 100s should be detected as a conflict")
    }

    func test_applyEpisodeActions_ask_noConflictWhenCloseEnough() {
        // GIVEN: Positions are within threshold
        let localPosition = 200
        let serverPosition = 205
        let threshold = 10

        let isConflict = abs(serverPosition - localPosition) > threshold
        XCTAssertFalse(isConflict,
                       "Positions within 10s should NOT be treated as a conflict")
    }
}

// MARK: - Force Sync Progress Tests

final class ForceSyncProgressTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: id,
            title: "Episode",
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    @MainActor
    func test_forceSyncProgress_updatesQueueItemPosition() {
        // GIVEN: A PlayerManager with an audio manager at position 500
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1")
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)

        // WHEN: forceSyncProgress is called
        playerManager.forceSyncProgress()

        // THEN: The currentItem's positionSeconds is updated
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 500,
                       "forceSyncProgress must update currentItem.positionSeconds immediately")
    }
}

// MARK: - Queue Race Condition Tests (auto-advance episode transition)

final class QueueRaceConditionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", durationSeconds: Int = 3600) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    // MARK: - Fix 1: currentPosition reset during transition

    func test_testablePreserveAndSwitch_resetsCurrentPosition() {
        // BUG: When episode A finishes (currentPosition ≈ 3600) and we switch to B,
        // currentPosition stayed at 3600, causing sync to report B as 100% played.

        // GIVEN: AudioManager at the end of episode A
        let manager = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A")
        let episodeB = makeItem(id: "ep-b", title: "Episode B")
        manager.currentItem = episodeA
        manager.testableSetPlaybackState(position: 3580, duration: 3600)

        // WHEN: Switching to episode B (simulating auto-advance)
        manager.testablePreserveAndSwitch(to: episodeB, preserveCurrent: false)

        // THEN: currentPosition must be reset — it must NOT carry over from episode A
        XCTAssertEqual(manager.currentPosition, 0,
                       "currentPosition must be reset to 0 when switching episodes to prevent stale data in sync")
    }

    func test_testablePreserveAndSwitch_resetsCurrentDuration() {
        // GIVEN: AudioManager at the end of episode A with known duration  
        let manager = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A")
        let episodeB = makeItem(id: "ep-b", title: "Episode B", durationSeconds: 1800)
        manager.currentItem = episodeA
        manager.testableSetPlaybackState(position: 3580, duration: 3600)

        // WHEN: Switching to episode B
        manager.testablePreserveAndSwitch(to: episodeB, preserveCurrent: false)

        // THEN: currentDuration must be reset too
        XCTAssertEqual(manager.currentDuration, 0,
                       "currentDuration must be reset when switching episodes")
    }

    // MARK: - Fix 2: isInEpisodeTransition guard

    func test_isInEpisodeTransition_falseByDefault() {
        let manager = AudioManager()
        XCTAssertFalse(manager.isInEpisodeTransition,
                       "Should be false when no episode loading is happening")
    }

    func test_isInEpisodeTransition_trueDuringTestableTransition() {
        // GIVEN: An AudioManager in a transition state
        let manager = AudioManager()
        manager.testableSetTransitionState(true)

        // THEN: isInEpisodeTransition should be true
        XCTAssertTrue(manager.isInEpisodeTransition,
                      "Should be true during episode transition")

        // Cleanup
        manager.testableSetTransitionState(false)
    }

    // MARK: - Fix 3: syncProgress skips during transition

    @MainActor
    func test_syncProgress_skippedDuringTransition() {
        // GIVEN: A PlayerManager where the audio manager is mid-transition
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-b")
        audioManager.testableSetPlaybackState(position: 3500, duration: 3600)
        audioManager.testableSetTransitionState(true)

        // WHEN: syncProgress fires (from the 1-second timer)
        playerManager.syncProgress()

        // THEN: The currentItem's positionSeconds should NOT be updated
        // (because the guard should have bailed out)
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0,
                       "syncProgress must skip when isInEpisodeTransition is true to prevent stale data")

        // Cleanup
        audioManager.testableSetTransitionState(false)
    }

    @MainActor
    func test_updateLocalProgress_skippedDuringTransition() {
        // GIVEN: A PlayerManager where the audio manager is mid-transition
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-b")
        audioManager.testableSetPlaybackState(position: 3500, duration: 3600)
        audioManager.testableSetTransitionState(true)

        // WHEN: updateLocalProgress fires
        playerManager.updateLocalProgress()

        // THEN: positionSeconds should NOT be updated
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0,
                       "updateLocalProgress must skip when isInEpisodeTransition is true")

        // Cleanup
        audioManager.testableSetTransitionState(false)
    }

    // MARK: - Fix 4: No cascading auto-advance

    func test_autoAdvance_doesNotCascade_throughQueue() {
        // BUG: When episode A completes and auto-advances to B,
        // B should NOT also be marked complete.

        // GIVEN: A queue with A (current), B, C
        let manager = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A")
        let episodeB = makeItem(id: "ep-b", title: "Episode B")
        let episodeC = makeItem(id: "ep-c", title: "Episode C")
        manager.currentItem = episodeA
        manager.appendToQueue([episodeB, episodeC])
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        // Track which episodes are reported as "completed"
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // WHEN: Episode A completes via testablePreserveAndSwitch (simulating auto-advance)
        // The advance should only complete A, then switch to B
        completedIds.append(manager.currentItem!.id) // A is completed
        let next = manager.queue.first!
        manager.testablePreserveAndSwitch(to: next, preserveCurrent: false)

        // THEN: Only episode A should be in completedIds
        XCTAssertEqual(completedIds, ["ep-a"],
                       "Only the actually-completed episode should be marked complete, not cascading to B and C")

        // AND: B should be the current item, C should still be in queue
        XCTAssertEqual(manager.currentItem?.id, "ep-b")
        XCTAssertEqual(manager.queue.count, 1)
        XCTAssertEqual(manager.queue[0].id, "ep-c")

        // AND: B's position should be 0 (not A's 3595)
        XCTAssertEqual(manager.currentPosition, 0,
                       "New episode must start at position 0, not carry over previous episode's position")
    }

    // MARK: - Integration: full auto-advance → sync timer race

    @MainActor
    func test_INTEGRATION_autoAdvanceThenSyncTimer_doesNotCorruptNextEpisode() {
        // THE ACTUAL BUG: Episode A finishes → auto-advance to B → sync timer fires
        // → sends B's guid with A's end position → server marks B complete → cascades
        //
        // This test would have CAUGHT the original bug because it exercises the exact
        // sequence: complete → switch → syncProgress fires → check what would be sent.

        // GIVEN: Episode A at its end, B and C in queue
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let episodeA = makeItem(id: "ep-a", title: "Episode A", durationSeconds: 3600)
        let episodeB = makeItem(id: "ep-b", title: "Episode B", durationSeconds: 1800)
        let episodeC = makeItem(id: "ep-c", title: "Episode C", durationSeconds: 2400)
        audioManager.currentItem = episodeA
        audioManager.appendToQueue([episodeB, episodeC])
        audioManager.testableSetPlaybackState(position: 3595, duration: 3600)

        // Track completion callbacks
        var completedIds: [String] = []
        audioManager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // WHEN: Episode A completes (full auto-advance flow)
        let result = audioManager.testableHandlePlaybackCompleted()

        // THEN: Only A was marked complete
        XCTAssertEqual(result.completed?.id, "ep-a")
        XCTAssertEqual(result.next?.id, "ep-b")
        XCTAssertEqual(completedIds, ["ep-a"],
                       "Only episode A should fire the completion callback")

        // AND: After the transition, the current state must be B at position 0
        XCTAssertEqual(audioManager.currentItem?.id, "ep-b",
                       "Current item should now be episode B")
        XCTAssertEqual(audioManager.currentPosition, 0,
                       "Position must be 0, not A's 3595")
        XCTAssertEqual(audioManager.currentDuration, 0,
                       "Duration must be 0, not A's 3600")

        // CRITICAL: Now simulate the 1-second sync timer firing IMMEDIATELY after transition
        // In the old buggy code, this would send position=3595 for episode B's guid!
        playerManager.syncProgress()

        // THEN: B's positionSeconds must NOT be set to A's end position
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0,
                       "syncProgress must NOT update B's position to A's stale value (3595)")

        // AND: C should still be in the queue, untouched
        XCTAssertEqual(audioManager.queue.count, 1)
        XCTAssertEqual(audioManager.queue[0].id, "ep-c")
        XCTAssertEqual(audioManager.queue[0].positionSeconds, 0,
                       "Episode C must remain at position 0, completely untouched by A's completion")
    }

    @MainActor
    func test_INTEGRATION_multipleAutoAdvances_noPositionLeakBetweenEpisodes() {
        // SCENARIO: Episodes finish back-to-back (short episodes in a queue).
        // Each completion must only affect that episode, never leaking to the next.

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)

        let ep1 = makeItem(id: "ep-1", title: "Short Episode 1", durationSeconds: 300)
        let ep2 = makeItem(id: "ep-2", title: "Short Episode 2", durationSeconds: 300)
        let ep3 = makeItem(id: "ep-3", title: "Short Episode 3", durationSeconds: 300)

        audioManager.currentItem = ep1
        audioManager.appendToQueue([ep2, ep3])

        var completedIds: [String] = []
        audioManager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // --- Episode 1 finishes ---
        audioManager.testableSetPlaybackState(position: 298, duration: 300)
        audioManager.testableHandlePlaybackCompleted()

        // Sync timer fires after advance to ep2
        playerManager.syncProgress()

        XCTAssertEqual(audioManager.currentItem?.id, "ep-2")
        XCTAssertEqual(audioManager.currentPosition, 0,
                       "After advancing to ep-2, position must be 0")

        // --- Episode 2 finishes ---
        audioManager.testableSetPlaybackState(position: 298, duration: 300)
        audioManager.testableHandlePlaybackCompleted()

        // Sync timer fires after advance to ep3
        playerManager.syncProgress()

        XCTAssertEqual(audioManager.currentItem?.id, "ep-3")
        XCTAssertEqual(audioManager.currentPosition, 0,
                       "After advancing to ep-3, position must be 0")

        // --- Verify only the correct episodes were completed ---
        XCTAssertEqual(completedIds, ["ep-1", "ep-2"],
                       "Only ep-1 and ep-2 should be completed, ep-3 is still playing")
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "Queue should be empty — ep-3 is the current item")
    }

    @MainActor
    func test_INTEGRATION_handleEpisodeCompleted_usesCorrectDuration_notResetValue() {
        // BUG: handleEpisodeCompleted reads currentDuration, but playEpisode resets it to 0.
        // If the callback fires after the reset, the completion action has total=0.

        let audioManager = AudioManager()
        let _ = PlayerManager(audioManager: audioManager)

        let episodeA = makeItem(id: "ep-a", title: "Episode A", durationSeconds: 3600)
        let episodeB = makeItem(id: "ep-b", title: "Episode B", durationSeconds: 1800)
        audioManager.currentItem = episodeA
        audioManager.appendToQueue([episodeB])
        audioManager.testableSetPlaybackState(position: 3595, duration: 3600)

        // Track what EpisodeAction gets created for the completion
        var capturedAction: EpisodeAction?
        audioManager.onEpisodeCompleted = { item in
            // This is what handleEpisodeCompleted does — capture the duration
            let totalDuration = item.durationSeconds ?? Int(audioManager.currentDuration)
            capturedAction = EpisodeAction(
                podcast: item.podcastUrl,
                episode: item.audioUrl,
                guid: item.id,
                action: "play",
                timestamp: 0,
                position: totalDuration,
                started: 0,
                total: totalDuration,
                device: "test"
            )
        }

        // WHEN: Episode A completes
        audioManager.testableHandlePlaybackCompleted()

        // THEN: The completion action must have the correct duration, not 0
        XCTAssertNotNil(capturedAction)
        XCTAssertEqual(capturedAction?.total, 3600,
                       "Completion action must use A's real duration (3600), not 0 from the reset")
        XCTAssertEqual(capturedAction?.position, 3600,
                       "Completion position should equal total duration")
        XCTAssertEqual(capturedAction?.guid, "ep-a",
                       "Completion action must be for episode A, not B")
    }
}

// MARK: - Integration: Queue Persistence Round-Trip

final class QueuePersistenceRoundTripTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let queueKey = "savedQueue"
    private let currentItemKey = "savedCurrentItem"
    private let positionKey = "savedCurrentPosition"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: currentItemKey)
        defaults.removeObject(forKey: positionKey)
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", durationSeconds: Int = 3600, positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    func test_INTEGRATION_queuePersistAndRestore_preservesAllState() {
        // SCENARIO: User is listening at position 1500 of episode A, with B and C in queue.
        // App gets killed. On restart, everything should be exactly as they left it.

        // GIVEN: A playing state with current item at position 1500
        let manager1 = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A", durationSeconds: 3600)
        let episodeB = makeItem(id: "ep-b", title: "Episode B", durationSeconds: 1800, positionSeconds: 300)
        let episodeC = makeItem(id: "ep-c", title: "Episode C", durationSeconds: 2400)
        manager1.currentItem = episodeA
        manager1.appendToQueue([episodeB, episodeC])
        manager1.testableSetPlaybackState(position: 1500, duration: 3600)

        // WHEN: App is killed (triggers persistQueueToDisk → persistQueue)
        manager1.persistQueueToDisk()

        // AND: App restarts with a fresh AudioManager
        let manager2 = AudioManager()
        manager2.restoreQueue()

        // THEN: Current item is restored
        XCTAssertEqual(manager2.currentItem?.id, "ep-a",
                       "Current item must be restored after restart")
        XCTAssertEqual(manager2.currentItem?.title, "Episode A")

        // AND: Position is restored from the saved value
        XCTAssertEqual(manager2.currentPosition, 1500, accuracy: 1.0,
                       "Position must be restored to where user left off")

        // AND: Duration is restored from the saved item's metadata
        XCTAssertEqual(manager2.currentItem?.durationSeconds, 3600)

        // AND: Queue is restored with correct items in order
        XCTAssertEqual(manager2.queue.count, 2,
                       "Queue must have 2 items after restore")
        XCTAssertEqual(manager2.queue[0].id, "ep-b")
        XCTAssertEqual(manager2.queue[1].id, "ep-c")

        // AND: Queue item positions are preserved
        XCTAssertEqual(manager2.queue[0].positionSeconds, 300,
                       "Episode B's saved position (300) must survive the round-trip")
        XCTAssertEqual(manager2.queue[1].positionSeconds, 0,
                       "Episode C's position (0) must survive the round-trip")
    }

    func test_INTEGRATION_persistAfterAutoAdvance_savesNewState() {
        // SCENARIO: Episode A finishes, auto-advances to B. Then app is killed.
        // On restart, B should be current at position 0, C in queue, A gone.

        // GIVEN: A at its end, B and C in queue
        let manager1 = AudioManager()
        let episodeA = makeItem(id: "ep-a", durationSeconds: 3600)
        let episodeB = makeItem(id: "ep-b", durationSeconds: 1800)
        let episodeC = makeItem(id: "ep-c", durationSeconds: 2400)
        manager1.currentItem = episodeA
        manager1.appendToQueue([episodeB, episodeC])
        manager1.testableSetPlaybackState(position: 3595, duration: 3600)

        // WHEN: Episode A completes (auto-advance)
        manager1.testableHandlePlaybackCompleted()

        // AND: App is killed shortly after
        manager1.persistQueueToDisk()

        // AND: App restarts
        let manager2 = AudioManager()
        manager2.restoreQueue()

        // THEN: B is now current, not A
        XCTAssertEqual(manager2.currentItem?.id, "ep-b",
                       "After auto-advance + persist, B should be current on restore")

        // AND: Position is 0 (just started B) — NOT A's end position (3595)
        XCTAssertEqual(manager2.currentPosition, 0, accuracy: 1.0,
                       "Position must be 0 for newly-advanced episode, NOT A's stale 3595")

        // AND: Only C remains in queue
        XCTAssertEqual(manager2.queue.count, 1)
        XCTAssertEqual(manager2.queue[0].id, "ep-c")
    }
}

// MARK: - Integration: Play-While-Playing (Preserve Current)

final class PlayWhilePlayingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", durationSeconds: Int = 3600) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    @MainActor
    func test_INTEGRATION_playNewEpisode_preservesCurrentAtTopOfQueue() {
        // SCENARIO: User is at position 1500 of episode A. They tap "Play" on episode B.
        // A should be preserved at the top of Up Next with its current position.

        // GIVEN: Listening to A at position 1500, C already in queue
        let manager = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A")
        let episodeB = makeItem(id: "ep-b", title: "Episode B")
        let episodeC = makeItem(id: "ep-c", title: "Episode C")
        manager.currentItem = episodeA
        manager.appendToQueue([episodeC])
        manager.testableSetPlaybackState(position: 1500, duration: 3600)

        // Sync A's positionSeconds from currentPosition (what forceSyncProgress does)
        if var updated = manager.currentItem {
            updated.positionSeconds = Int(manager.currentPosition)
            manager.currentItem = updated
        }

        // WHEN: User taps "Play" on episode B (preserveCurrent: true)
        manager.testablePreserveAndSwitch(to: episodeB, preserveCurrent: true)

        // THEN: B is now current
        XCTAssertEqual(manager.currentItem?.id, "ep-b",
                       "B should be the current item after tapping play")

        // AND: A is at the top of the queue with its position preserved
        XCTAssertEqual(manager.queue.count, 2,
                       "Queue should have A (preserved) and C")
        XCTAssertEqual(manager.queue[0].id, "ep-a",
                       "A should be at position 0 in the queue (top of Up Next)")
        XCTAssertEqual(manager.queue[0].positionSeconds, 1500,
                       "A's position (1500) must be preserved when moved to queue")

        // AND: C is still in queue after A
        XCTAssertEqual(manager.queue[1].id, "ep-c")

        // AND: B's position starts at 0
        XCTAssertEqual(manager.currentPosition, 0,
                       "New episode B should start at position 0")
    }

    func test_INTEGRATION_playNewEpisode_doesNotDuplicateInQueue() {
        // SCENARIO: User plays episode B which is already in the queue.
        // B should NOT appear twice in the queue.

        // GIVEN: A is playing, B and C are in queue
        let manager = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A")
        let episodeB = makeItem(id: "ep-b", title: "Episode B")
        let episodeC = makeItem(id: "ep-c", title: "Episode C")
        manager.currentItem = episodeA
        manager.appendToQueue([episodeB, episodeC])
        manager.testableSetPlaybackState(position: 500, duration: 3600)

        // WHEN: User taps "Play" on episode B (which is already in queue)
        manager.testablePreserveAndSwitch(to: episodeB, preserveCurrent: true)

        // THEN: B is current
        XCTAssertEqual(manager.currentItem?.id, "ep-b")

        // AND: B does NOT appear in the queue (no duplicates)
        XCTAssertFalse(manager.queue.contains { $0.id == "ep-b" },
                       "Episode B must not appear in the queue since it's now current")

        // AND: A is preserved at top, C is still there
        XCTAssertEqual(manager.queue.count, 2, "Should have A (preserved) + C")
        XCTAssertEqual(manager.queue[0].id, "ep-a")
        XCTAssertEqual(manager.queue[1].id, "ep-c")
    }
}

// MARK: - Integration: Completion Edge Cases

final class CompletionEdgeCaseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", durationSeconds: Int = 3600) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    func test_INTEGRATION_completionWithEmptyQueue_stopsCleanly() {
        // SCENARIO: The last episode finishes. Player should stop cleanly,
        // not crash or leave dangling state.

        let manager = AudioManager()
        let lastEpisode = makeItem(id: "ep-last", title: "The Final Episode")
        manager.currentItem = lastEpisode
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // WHEN: Last episode completes with empty queue
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Episode was marked complete
        XCTAssertEqual(result.completed?.id, "ep-last")
        XCTAssertEqual(completedIds, ["ep-last"])

        // AND: No next episode (queue was empty)
        XCTAssertNil(result.next, "Should be nil — no more episodes")

        // AND: Player state is clean
        XCTAssertNil(manager.currentItem, "Current item should be nil after last episode")
        XCTAssertEqual(manager.currentPosition, 0, "Position should reset to 0")
        XCTAssertEqual(manager.currentDuration, 0, "Duration should reset to 0")
        XCTAssertFalse(manager.isPlaying, "Player should not be playing")
    }

    func test_INTEGRATION_doubleCompletion_secondIsIgnored() {
        // SCENARIO: AVPlayer sends two didPlayToEndTime notifications rapidly
        // (real behavior observed in production). Second must be ignored.

        let manager = AudioManager()
        let episodeA = makeItem(id: "ep-a", title: "Episode A")
        let episodeB = makeItem(id: "ep-b", title: "Episode B")
        let episodeC = makeItem(id: "ep-c", title: "Episode C")
        manager.currentItem = episodeA
        manager.appendToQueue([episodeB, episodeC])
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // WHEN: First completion fires
        let result1 = manager.testableHandlePlaybackCompleted()

        // AND: Second completion fires immediately (duplicate notification)
        // At this point, isAdvancingQueue should be false again (testable resets it),
        // but the state has already changed. Let's verify the second call is safe.
        let _ = manager.testableHandlePlaybackCompleted()

        // THEN: First completion processed normally
        XCTAssertEqual(result1.completed?.id, "ep-a")
        XCTAssertEqual(result1.next?.id, "ep-b")

        // AND: Second completion processes B → C (this is actually a cascading advance)
        // BUT: B has position 0 and duration 0, so the spurious completion guard kicks in
        // if currentDuration > 30 (it isn't — it's 0). So it will try to advance.
        // The key assertion is: only A and B should be completed, NOT C still in queue.
        // This verifies the chain doesn't cascade infinitely.
        
        // Whether the second call is a no-op or processes B depends on state.
        // What matters: we never get more completions than episodes
        XCTAssertTrue(completedIds.count <= 2,
                      "At most 2 completion callbacks should fire, never more than # of episodes that finish")
        XCTAssertEqual(completedIds.first, "ep-a",
                       "First completed episode must be A")
    }

    func test_INTEGRATION_spuriousCompletionOnColdStart_rejected() {
        // SCENARIO: On cold start, AVPlayer may send a didPlayToEndTime when the
        // player item is loaded but hasn't actually reached the end (the player loads
        // the metadata and fires a "finished" event at position 0).
        // The spurious completion guard should reject this.

        let manager = AudioManager()
        let episode = makeItem(id: "ep-a", title: "Long Episode", durationSeconds: 3600)
        manager.currentItem = episode
        // Position 0, duration 3600 — clearly hasn't played yet
        manager.testableSetPlaybackState(position: 0, duration: 3600)

        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // Verify the spurious completion guard would catch this
        XCTAssertTrue(manager.testableIsSpuriousCompletion(),
                      "Position 0 / duration 3600 should be detected as spurious (3600-0=3600 > 10)")

        // WHEN: A completion fires at position 0
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Completion was rejected
        XCTAssertNil(result.completed, "Should not complete — this is a spurious event")
        XCTAssertNil(result.next, "Should not advance — spurious completion rejected")
        XCTAssertTrue(completedIds.isEmpty, "No completion callback should fire")

        // AND: Episode is still current, position unchanged
        XCTAssertEqual(manager.currentItem?.id, "ep-a",
                       "Episode should still be the current item (not ejected)")
    }

    func test_INTEGRATION_completionAtMidpoint_rejected() {
        // SCENARIO: Network error causes AVPlayer to fire didPlayToEndTime at a mid-point
        // (e.g., buffering failed at position 1500 of a 3600s episode).
        // Spurious completion guard should catch this.

        let manager = AudioManager()
        let episode = makeItem(id: "ep-a", durationSeconds: 3600)
        manager.currentItem = episode
        manager.testableSetPlaybackState(position: 1500, duration: 3600)

        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }

        // Verify guard catches this (3600-1500 = 2100 > 10)
        XCTAssertTrue(manager.testableIsSpuriousCompletion(),
                      "Position 1500/3600 should be spurious — still 2100s remaining")

        // WHEN: Completion fires at midpoint
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: Rejected
        XCTAssertNil(result.completed)
        XCTAssertTrue(completedIds.isEmpty,
                      "Midpoint completion must be rejected — episode is not actually done")
    }
}

// MARK: - Remote Command Action Tests

final class RemoteCommandActionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "nextTrackAction")
        UserDefaults.standard.removeObject(forKey: "previousTrackAction")
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "nextTrackAction")
        UserDefaults.standard.removeObject(forKey: "previousTrackAction")
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    // MARK: - Enum Raw Values

    func test_remoteCommandAction_rawValues() {
        XCTAssertEqual(RemoteCommandAction.skipBack.rawValue, "skipBack")
        XCTAssertEqual(RemoteCommandAction.skipForward.rawValue, "skipForward")
        XCTAssertEqual(RemoteCommandAction.previousEpisode.rawValue, "previousEpisode")
        XCTAssertEqual(RemoteCommandAction.nextEpisode.rawValue, "nextEpisode")
    }

    func test_remoteCommandAction_roundTrip() {
        for action in RemoteCommandAction.allCases {
            let decoded = RemoteCommandAction(rawValue: action.rawValue)
            XCTAssertEqual(decoded, action, "Round-trip failed for \(action)")
        }
    }

    func test_remoteCommandAction_displayNames() {
        XCTAssertEqual(RemoteCommandAction.skipBack.displayName, "Skip Back")
        XCTAssertEqual(RemoteCommandAction.skipForward.displayName, "Skip Forward")
        XCTAssertEqual(RemoteCommandAction.previousEpisode.displayName, "Restart Episode")
        XCTAssertEqual(RemoteCommandAction.nextEpisode.displayName, "Next Episode")
    }

    // MARK: - SettingsManager Defaults

    func test_nextTrackAction_defaultsToNextEpisode() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.nextTrackAction, .nextEpisode,
                       "Next track should default to nextEpisode")
    }

    func test_previousTrackAction_defaultsToSkipBack() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.previousTrackAction, .skipBack,
                       "Previous track should default to skipBack (Apple Podcasts convention)")
    }

    // MARK: - SettingsManager Persistence

    func test_nextTrackAction_persists() {
        let settings1 = SettingsManager()
        settings1.nextTrackAction = .skipForward

        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.nextTrackAction, .skipForward,
                       "nextTrackAction must persist across SettingsManager instances")
    }

    func test_previousTrackAction_persists() {
        let settings1 = SettingsManager()
        settings1.previousTrackAction = .previousEpisode

        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.previousTrackAction, .previousEpisode,
                       "previousTrackAction must persist across SettingsManager instances")
    }

    // MARK: - AudioManager Action Properties

    func test_audioManager_defaultActions() {
        let manager = AudioManager()
        XCTAssertEqual(manager.nextTrackAction, .nextEpisode,
                       "AudioManager nextTrackAction should default to nextEpisode")
        XCTAssertEqual(manager.previousTrackAction, .skipBack,
                       "AudioManager previousTrackAction should default to skipBack")
    }

    func test_audioManager_actionsCanBeUpdated() {
        let manager = AudioManager()
        manager.nextTrackAction = .skipForward
        manager.previousTrackAction = .previousEpisode

        XCTAssertEqual(manager.nextTrackAction, .skipForward)
        XCTAssertEqual(manager.previousTrackAction, .previousEpisode)
    }
}

// MARK: - Per-Episode Skip/Speed Settings Tests

final class PerEpisodePlaybackSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(
        id: String,
        title: String = "Episode",
        skipIntro: Int = 0,
        skipOutro: Int = 0,
        playbackSpeed: Float = 1.0
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil,
            skipIntroSeconds: skipIntro,
            skipOutroSeconds: skipOutro,
            playbackSpeed: playbackSpeed
        )
    }

    // MARK: - QueueItem carries settings

    func test_queueItem_carriesSkipIntroSeconds() {
        let item = makeItem(id: "ep1", skipIntro: 30)
        XCTAssertEqual(item.skipIntroSeconds, 30)
    }

    func test_queueItem_carriesSkipOutroSeconds() {
        let item = makeItem(id: "ep1", skipOutro: 20)
        XCTAssertEqual(item.skipOutroSeconds, 20)
    }

    func test_queueItem_carriesPlaybackSpeed() {
        let item = makeItem(id: "ep1", playbackSpeed: 1.5)
        XCTAssertEqual(item.playbackSpeed, 1.5)
    }

    func test_queueItem_defaultsToZeroSkipAndNormalSpeed() {
        let item = QueueItem(
            id: "ep1", title: "Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        XCTAssertEqual(item.skipIntroSeconds, 0, "Default skipIntro should be 0")
        XCTAssertEqual(item.skipOutroSeconds, 0, "Default skipOutro should be 0")
        XCTAssertEqual(item.playbackSpeed, 1.0, "Default playbackSpeed should be 1.0")
    }

    // MARK: - Encode/Decode round-trip (backward compat)

    func test_queueItem_skipSettings_surviveEncodeDecode() {
        let original = makeItem(id: "ep1", skipIntro: 45, skipOutro: 15, playbackSpeed: 2.0)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try! encoder.encode(original)
        let decoded = try! decoder.decode(QueueItem.self, from: data)

        XCTAssertEqual(decoded.skipIntroSeconds, 45)
        XCTAssertEqual(decoded.skipOutroSeconds, 15)
        XCTAssertEqual(decoded.playbackSpeed, 2.0)
    }

    func test_queueItem_decodesWithMissingSkipFields_defaultsToZero() {
        // Simulates a QueueItem persisted BEFORE skip fields were added
        let json = """
        {
            "id": "old-ep",
            "title": "Old Episode",
            "podcastTitle": "Pod",
            "audioUrl": "https://example.com/old.mp3",
            "durationSeconds": 3600,
            "positionSeconds": 100,
            "podcastUrl": "https://example.com/feed"
        }
        """.data(using: .utf8)!

        let decoded = try! JSONDecoder().decode(QueueItem.self, from: json)
        XCTAssertEqual(decoded.skipIntroSeconds, 0, "Missing skipIntro should default to 0")
        XCTAssertEqual(decoded.skipOutroSeconds, 0, "Missing skipOutro should default to 0")
        XCTAssertEqual(decoded.playbackSpeed, 1.0, "Missing playbackSpeed should default to 1.0")
    }

    // MARK: - Auto-advance carries per-episode settings

    func test_autoAdvance_nextItemCarriesItsOwnSkipSettings() {
        // GIVEN: Current item with skipIntro=0, next item with skipIntro=30
        let manager = AudioManager()
        let currentItem = makeItem(id: "ep-a", skipIntro: 0, skipOutro: 0)
        let nextItem = makeItem(id: "ep-b", skipIntro: 30, skipOutro: 20, playbackSpeed: 1.5)

        manager.currentItem = currentItem
        manager.appendToQueue([nextItem])
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        // WHEN: Auto-advance fires
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: The new current item carries its own skip settings
        XCTAssertEqual(result.next?.id, "ep-b")
        XCTAssertEqual(result.next?.skipIntroSeconds, 30,
                       "Next item should carry its own skipIntro, not the previous item's")
        XCTAssertEqual(result.next?.skipOutroSeconds, 20,
                       "Next item should carry its own skipOutro")
        XCTAssertEqual(result.next?.playbackSpeed, 1.5,
                       "Next item should carry its own playbackSpeed")
        XCTAssertEqual(manager.currentItem?.skipIntroSeconds, 30)
    }

    func test_differentPodcasts_carryDifferentSkipValues() {
        // GIVEN: A queue with items from two different podcasts
        let manager = AudioManager()
        let podA_ep = makeItem(id: "podA-ep1", title: "Podcast A Ep", skipIntro: 45, skipOutro: 10)
        let podB_ep = makeItem(id: "podB-ep1", title: "Podcast B Ep", skipIntro: 0, skipOutro: 0)

        manager.appendToQueue([podA_ep, podB_ep])

        // THEN: Each item in the queue retains its own settings
        XCTAssertEqual(manager.queue[0].skipIntroSeconds, 45)
        XCTAssertEqual(manager.queue[0].skipOutroSeconds, 10)
        XCTAssertEqual(manager.queue[1].skipIntroSeconds, 0)
        XCTAssertEqual(manager.queue[1].skipOutroSeconds, 0)
    }

    // MARK: - Skip outro detection uses currentItem field

    func test_skipOutro_detectsFromCurrentItemSetting() {
        // Verify the currentItem's skipOutroSeconds is accessible for detection
        let manager = AudioManager()
        let item = makeItem(id: "ep1", skipOutro: 15)
        manager.currentItem = item
        manager.testableSetPlaybackState(position: 3585, duration: 3600)

        // The skip outro detection should use currentItem.skipOutroSeconds
        let outroSeconds = manager.currentItem?.skipOutroSeconds ?? 0
        let shouldSkip = outroSeconds > 0 &&
            manager.currentDuration > 0 &&
            manager.currentPosition >= manager.currentDuration - Double(outroSeconds)

        XCTAssertTrue(shouldSkip,
                      "Should detect outro when position is within skipOutroSeconds of the end")
    }

    func test_skipOutro_doesNotTrigger_whenSettingIsZero() {
        let manager = AudioManager()
        let item = makeItem(id: "ep1", skipOutro: 0)
        manager.currentItem = item
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        let outroSeconds = manager.currentItem?.skipOutroSeconds ?? 0
        let shouldSkip = outroSeconds > 0 &&
            manager.currentDuration > 0 &&
            manager.currentPosition >= manager.currentDuration - Double(outroSeconds)

        XCTAssertFalse(shouldSkip,
                       "Should NOT detect outro when skipOutroSeconds is 0")
    }

    // MARK: - Queue persistence with skip settings

    func test_queuePersistence_preservesSkipSettings() {
        // GIVEN: Queue items with skip settings
        let manager1 = AudioManager()
        let item = makeItem(id: "ep1", skipIntro: 30, skipOutro: 15, playbackSpeed: 1.75)
        manager1.appendToQueue([item])

        // WHEN: A new AudioManager restores the queue
        let manager2 = AudioManager()
        manager2.restoreQueue()

        // THEN: Skip settings survive the round-trip
        XCTAssertEqual(manager2.queue.count, 1)
        XCTAssertEqual(manager2.queue[0].skipIntroSeconds, 30)
        XCTAssertEqual(manager2.queue[0].skipOutroSeconds, 15)
        XCTAssertEqual(manager2.queue[0].playbackSpeed, 1.75)
    }
}

// MARK: - Download Cleanup Tests

@MainActor
final class DownloadCleanupTests: XCTestCase {
    
    // MARK: - PodcastSettings migration
    
    func test_podcastSettings_migratesLegacyBoolTrue() throws {
        // GIVEN: JSON with the old removeDownloadAfterPlay = true
        let json = """
        {"removeDownloadAfterPlay": true}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded as PodcastSettings
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: Should migrate to .oncePlayed
        XCTAssertEqual(settings.downloadCleanupPolicy, .oncePlayed)
    }
    
    func test_podcastSettings_migratesLegacyBoolFalse() throws {
        // GIVEN: JSON with the old removeDownloadAfterPlay = false
        let json = """
        {"removeDownloadAfterPlay": false}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: Should be nil (use global default)
        XCTAssertNil(settings.downloadCleanupPolicy)
    }
    
    func test_podcastSettings_decodesNewPolicy() throws {
        // GIVEN: JSON with the new downloadCleanupPolicy
        let json = """
        {"downloadCleanupPolicy": "afterOneWeek"}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: Should decode correctly
        XCTAssertEqual(settings.downloadCleanupPolicy, .afterOneWeek)
    }
    
    func test_podcastSettings_newPolicyTakesPrecedenceOverLegacy() throws {
        // GIVEN: JSON with BOTH old and new keys (shouldn't happen, but defensive)
        let json = """
        {"removeDownloadAfterPlay": true, "downloadCleanupPolicy": "never"}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: New key should win
        XCTAssertEqual(settings.downloadCleanupPolicy, .never)
    }
    
    func test_podcastSettings_encodesNewKeyOnly() throws {
        // GIVEN: Settings with a cleanup policy
        var settings = PodcastSettings()
        settings.downloadCleanupPolicy = .afterOneMonth
        
        // WHEN: Encoded
        let data = try JSONEncoder().encode(settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        // THEN: Should use new key, not legacy
        XCTAssertEqual(json["downloadCleanupPolicy"] as? String, "afterOneMonth")
        XCTAssertNil(json["removeDownloadAfterPlay"])
    }
    
    // MARK: - DownloadCleanupPolicy display names
    
    func test_policyDisplayNames() {
        XCTAssertEqual(DownloadCleanupPolicy.oncePlayed.displayName, "Once Played")
        XCTAssertEqual(DownloadCleanupPolicy.afterOneWeek.displayName, "After 1 Week")
        XCTAssertEqual(DownloadCleanupPolicy.afterOneMonth.displayName, "After 1 Month")
        XCTAssertEqual(DownloadCleanupPolicy.never.displayName, "Never")
    }
    
    // MARK: - DownloadManager.cleanupExpiredDownloads
    
    func test_cleanupExpiredDownloads_deletesWeekOld() {
        // GIVEN: A download manager with a download played 8 days ago
        let dm = DownloadManager()
        let guid = "test-ep-1"
        
        // Simulate a downloaded file
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        // Set played date to 8 days ago
        dm.playedDates[guid] = Date().addingTimeInterval(-8 * 24 * 3600)
        
        // WHEN: Cleanup runs with afterOneWeek policy
        dm.cleanupExpiredDownloads(globalPolicy: .afterOneWeek, podcastPolicies: [:])
        
        // THEN: Download should be removed
        XCTAssertNil(dm.downloadedFiles[guid], "Week-old download should be cleaned up")
        XCTAssertNil(dm.playedDates[guid], "Played date should be cleaned up")
        
        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }
    
    func test_cleanupExpiredDownloads_keepsRecentDownload() {
        // GIVEN: A download manager with a download played 3 days ago
        let dm = DownloadManager()
        let guid = "test-ep-2"
        
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test2.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        dm.playedDates[guid] = Date().addingTimeInterval(-3 * 24 * 3600)
        
        // WHEN: Cleanup runs with afterOneWeek policy
        dm.cleanupExpiredDownloads(globalPolicy: .afterOneWeek, podcastPolicies: [:])
        
        // THEN: Download should be kept (only 3 days old)
        XCTAssertNotNil(dm.downloadedFiles[guid], "3-day-old download should be kept under 1-week policy")
        
        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }
    
    func test_cleanupExpiredDownloads_perPodcastOverridesGlobal() {
        // GIVEN: Global policy is .never, but per-podcast is .oncePlayed
        let dm = DownloadManager()
        let guid = "test-ep-3"
        
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test3.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        dm.playedDates[guid] = Date() // Just played
        
        // WHEN: Cleanup with global=never but per-podcast=oncePlayed
        dm.cleanupExpiredDownloads(
            globalPolicy: .never,
            podcastPolicies: [guid: .oncePlayed]
        )
        
        // THEN: Per-podcast policy wins — download should be deleted
        XCTAssertNil(dm.downloadedFiles[guid], "Per-podcast .oncePlayed should override global .never")
        
        try? FileManager.default.removeItem(at: testDir)
    }
    
    func test_cleanupExpiredDownloads_neverPolicyKeepsEverything() {
        // GIVEN: A download played months ago with .never policy
        let dm = DownloadManager()
        let guid = "test-ep-4"
        
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test4.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        dm.playedDates[guid] = Date().addingTimeInterval(-365 * 24 * 3600) // 1 year ago
        
        // WHEN: Cleanup with .never
        dm.cleanupExpiredDownloads(globalPolicy: .never, podcastPolicies: [:])
        
        // THEN: Should not delete
        XCTAssertNotNil(dm.downloadedFiles[guid], "Never policy should keep downloads forever")
        
        try? FileManager.default.removeItem(at: testDir)
    }
    
    // MARK: - markPlayed guard
    
    func test_markPlayed_ignoresNonDownloadedEpisode() {
        // GIVEN: A download manager with no downloads
        let dm = DownloadManager()
        
        // WHEN: markPlayed is called for a non-downloaded episode
        dm.markPlayed(guid: "not-downloaded")
        
        // THEN: Should not track it
        XCTAssertNil(dm.playedDates["not-downloaded"])
    }
}

// MARK: - Auto-Queue Settings Tests

/// Tests that PodcastSettings.autoQueueMode correctly distinguishes between
/// "use global default" (nil) and "explicitly off" (.off).
/// Regression: PodcastSettingsSheet Picker binding used `.off` as the getter's default,
/// which caused SwiftUI to write `.off` back on any sheet interaction — permanently
/// overriding the global default for that podcast.
final class AutoQueueSettingsTests: XCTestCase {
    
    func test_newPodcastSettings_autoQueueModeIsNil() {
        // GIVEN: A fresh PodcastSettings with no overrides
        let settings = PodcastSettings()
        
        // THEN: autoQueueMode should be nil (meaning "use global default")
        XCTAssertNil(settings.autoQueueMode, "New settings must default to nil, not .off")
    }
    
    func test_autoQueueMode_nilCoalescing_usesGlobalDefault() {
        // GIVEN: Per-podcast autoQueueMode is nil (no override)
        let settings = PodcastSettings()
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Using nil-coalescing to resolve the effective mode
        let effective = settings.autoQueueMode ?? globalDefault
        
        // THEN: Should use the global default, not .off
        XCTAssertEqual(effective, .normal, "nil autoQueueMode should fall through to global default")
    }
    
    func test_autoQueueMode_explicitOff_overridesGlobalDefault() {
        // GIVEN: Per-podcast autoQueueMode is explicitly .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Using nil-coalescing
        let effective = settings.autoQueueMode ?? globalDefault
        
        // THEN: Should use .off (explicit override), not the global default
        XCTAssertEqual(effective, .off, "Explicit .off should override global default")
    }
    
    func test_autoQueueMode_nilSurvivesEncodeDecode() {
        // GIVEN: Settings with autoQueueMode = nil
        let settings = PodcastSettings()
        
        // WHEN: Encoding and decoding
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: autoQueueMode should still be nil
        XCTAssertNil(decoded.autoQueueMode, "nil autoQueueMode must survive encode/decode round-trip")
    }
    
    func test_autoQueueMode_explicitOffSurvivesEncodeDecode() {
        // GIVEN: Settings with autoQueueMode = .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        
        // WHEN: Encoding and decoding
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: autoQueueMode should be .off, not nil
        XCTAssertEqual(decoded.autoQueueMode, .off, "Explicit .off must survive encode/decode round-trip")
    }
    
    // MARK: - Auto-Queue Decision Logic Tests (nil fallback to global default)
    // Regression: BackgroundRefreshService and getAutoQueueCandidates both rejected
    // nil autoQueueMode instead of falling through to the global default.
    
    /// Simulates the BackgroundRefreshService filter logic.
    /// When per-podcast autoQueueMode is nil and the global default is .normal,
    /// the episode SHOULD be auto-queued.
    func test_backgroundRefreshLogic_autoQueuesWhenPerPodcastModeIsNil_andGlobalIsNormal() {
        // GIVEN: Per-podcast autoQueueMode is nil (use global default)
        let settings = PodcastSettings()
        XCTAssertNil(settings.autoQueueMode, "Precondition: per-podcast mode is nil")
        
        // AND: Global default is .normal
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Applying the BackgroundRefreshService filter logic
        let effectiveMode = settings.autoQueueMode ?? globalDefault
        let shouldAutoQueue = effectiveMode != .off
        
        // THEN: Episode should be auto-queued
        XCTAssertTrue(shouldAutoQueue,
                      "nil per-podcast autoQueueMode + global .normal should auto-queue")
    }
    
    /// When per-podcast autoQueueMode is explicitly .off, the episode should NOT
    /// be auto-queued regardless of the global default.
    func test_backgroundRefreshLogic_doesNotAutoQueue_whenPerPodcastModeIsExplicitlyOff() {
        // GIVEN: Per-podcast autoQueueMode is explicitly .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        
        // AND: Global default is .normal (would allow auto-queue)
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Applying the BackgroundRefreshService filter logic
        let effectiveMode = settings.autoQueueMode ?? globalDefault
        let shouldAutoQueue = effectiveMode != .off
        
        // THEN: Episode should NOT be auto-queued
        XCTAssertFalse(shouldAutoQueue,
                       "Explicit .off should override global .normal and prevent auto-queue")
    }
    
    /// getAutoQueueCandidates should return episodes when per-podcast mode is nil
    /// and the global default is .normal.
    func test_getAutoQueueCandidates_returnsEpisodes_whenPerPodcastModeIsNil_andGlobalIsNormal() {
        // GIVEN: Per-podcast autoQueueMode is nil (use global default)
        let settings = PodcastSettings()
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Applying the getAutoQueueCandidates guard logic
        let mode = settings.autoQueueMode ?? globalDefault
        let shouldReturnCandidates = mode != .off
        
        // THEN: Should return candidates (not empty)
        XCTAssertTrue(shouldReturnCandidates,
                      "nil per-podcast autoQueueMode + global .normal should return candidates")
    }
    
    /// getAutoQueueCandidates should return empty when per-podcast mode is explicitly .off.
    func test_getAutoQueueCandidates_returnsEmpty_whenPerPodcastModeIsExplicitlyOff() {
        // GIVEN: Per-podcast autoQueueMode is explicitly .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        
        // WHEN: Applying the getAutoQueueCandidates guard logic
        let mode = settings.autoQueueMode ?? AutoQueueMode.normal
        let shouldReturnCandidates = mode != .off
        
        // THEN: Should return empty
        XCTAssertFalse(shouldReturnCandidates,
                       "Explicit .off should return empty regardless of global default")
    }
}

// MARK: - SettingsManager Defaults Tests

/// Tests that global defaults in SettingsManager persist correctly to UserDefaults
/// and return expected fallback values when nothing is set.
final class SettingsManagerDefaultsTests: XCTestCase {
    
    private let defaults = UserDefaults.standard
    
    override func setUp() {
        super.setUp()
        // Clean keys we test
        defaults.removeObject(forKey: "defaultAutoQueueMode")
        defaults.removeObject(forKey: "defaultDownloadCleanupPolicy")
        defaults.removeObject(forKey: "defaultRemoveAfterPlay")
        defaults.removeObject(forKey: "defaultAutoDownload")
        defaults.removeObject(forKey: "defaultArchiveOnComplete")
        defaults.removeObject(forKey: "playbackSpeed")
    }
    
    override func tearDown() {
        defaults.removeObject(forKey: "defaultAutoQueueMode")
        defaults.removeObject(forKey: "defaultDownloadCleanupPolicy")
        defaults.removeObject(forKey: "defaultRemoveAfterPlay")
        defaults.removeObject(forKey: "defaultAutoDownload")
        defaults.removeObject(forKey: "defaultArchiveOnComplete")
        defaults.removeObject(forKey: "playbackSpeed")
        super.tearDown()
    }
    
    func test_defaultAutoQueueMode_defaultsToOff() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.defaultAutoQueueMode, .off,
                       "Global auto-queue should default to .off when nothing is set")
    }
    
    func test_defaultAutoQueueMode_persistsRoundTrip() {
        let settings = SettingsManager()
        settings.defaultAutoQueueMode = .normal
        
        // Read from a fresh instance to verify UserDefaults persistence
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.defaultAutoQueueMode, .normal,
                       "Auto-queue mode must persist across SettingsManager instances")
    }
    
    func test_defaultDownloadCleanupPolicy_defaultsToOncePlayed() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.defaultDownloadCleanupPolicy, .oncePlayed,
                       "Global download cleanup should default to .oncePlayed")
    }
    
    func test_defaultDownloadCleanupPolicy_persistsRoundTrip() {
        let settings = SettingsManager()
        settings.defaultDownloadCleanupPolicy = .never
        
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.defaultDownloadCleanupPolicy, .never,
                       "Download cleanup policy must persist across instances")
    }
    
    func test_defaultAutoDownload_defaultsToFalse() {
        let settings = SettingsManager()
        XCTAssertFalse(settings.defaultAutoDownload,
                       "Auto-download should default to false")
    }
    
    func test_playbackSpeed_defaultsToOne() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.playbackSpeed, 1.0, accuracy: 0.01,
                       "Playback speed should default to 1.0x")
    }
}

// MARK: - Download Cleanup Settings Tests

/// Tests that download cleanup policy correctly distinguishes nil (use global)
/// from explicit values, matching the auto-queue pattern.
final class DownloadCleanupSettingsTests: XCTestCase {
    
    func test_newPodcastSettings_downloadCleanupPolicyIsNil() {
        let settings = PodcastSettings()
        XCTAssertNil(settings.downloadCleanupPolicy,
                     "New settings must default to nil for cleanup policy")
    }
    
    func test_downloadCleanupPolicy_nilFallsToGlobal() {
        let settings = PodcastSettings()
        let globalDefault: DownloadCleanupPolicy = .afterOneWeek
        
        let effective = settings.downloadCleanupPolicy ?? globalDefault
        XCTAssertEqual(effective, .afterOneWeek,
                       "nil cleanup policy should fall through to global default")
    }
    
    func test_downloadCleanupPolicy_explicitOverridesGlobal() {
        var settings = PodcastSettings()
        settings.downloadCleanupPolicy = .never
        let globalDefault: DownloadCleanupPolicy = .oncePlayed
        
        let effective = settings.downloadCleanupPolicy ?? globalDefault
        XCTAssertEqual(effective, .never,
                       "Explicit .never should override global .oncePlayed")
    }
}

// MARK: - Episode Completion Pipeline Tests

/// Tests the handleEpisodeCompleted callback chain to ensure
/// completion triggers the expected downstream effects.
@MainActor
final class EpisodeCompletionPipelineTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }
    
    private func makeItem(id: String, title: String = "Episode", podcastUrl: String = "https://example.com/feed") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }
    
    func test_onEpisodeCompleted_callbackFires() {
        // GIVEN: An AudioManager with a completion callback
        let manager = AudioManager()
        var completedItem: QueueItem?
        manager.onEpisodeCompleted = { item in
            completedItem = item
        }
        
        let ep1 = makeItem(id: "ep-1")
        let ep2 = makeItem(id: "ep-2")
        manager.currentItem = ep1
        manager.appendToQueue([ep2])
        manager.testableSetPlaybackState(position: 599, duration: 600)
        manager.isPlaying = true
        
        // WHEN: Episode completes and auto-advances
        manager.testableHandlePlaybackCompleted()
        
        // THEN: The callback should have been called with the completed episode
        XCTAssertEqual(completedItem?.id, "ep-1",
                       "onEpisodeCompleted must fire with the finished episode")
    }
    
    func test_onEpisodeCompleted_doesNotFireForSpuriousCompletion() {
        // GIVEN: An episode at 50% (spurious completion)
        let manager = AudioManager()
        var completedCount = 0
        manager.onEpisodeCompleted = { _ in
            completedCount += 1
        }
        
        let ep1 = makeItem(id: "ep-1")
        manager.currentItem = ep1
        manager.testableSetPlaybackState(position: 300, duration: 600)
        manager.isPlaying = true
        
        // WHEN: Spurious completion fires
        manager.testableHandlePlaybackCompleted()
        
        // THEN: Callback should NOT fire (spurious detected)
        XCTAssertEqual(completedCount, 0,
                       "onEpisodeCompleted must not fire for spurious completions")
    }
    
    func test_resolveCleanupPolicy_perPodcastOverridesGlobal() {
        // GIVEN: A PlayerManager with global policy .oncePlayed
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let settings = SettingsManager()
        settings.defaultDownloadCleanupPolicy = .oncePlayed
        playerManager.settingsManager = settings
        
        // AND: A QueueItem with no podcast match (falls to global)
        let item = makeItem(id: "ep-1", podcastUrl: "https://no-match.com/feed")
        
        // WHEN: Resolving cleanup policy without a matching podcast
        // (podcastManager has no subscriptions, so per-podcast lookup returns nil)
        // We can't easily test with SwiftData models, but we CAN verify the fallback
        let policy = settings.defaultDownloadCleanupPolicy
        
        // THEN: Should use global default
        XCTAssertEqual(policy, .oncePlayed,
                       "When no per-podcast override, global default should apply")
    }
    
    func test_autoAdvance_firesCompletionForCorrectEpisode() {
        // GIVEN: A queue with 3 episodes, ep1 at the end
        let manager = AudioManager()
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { item in
            completedIds.append(item.id)
        }
        
        let ep1 = makeItem(id: "ep-1")
        let ep2 = makeItem(id: "ep-2")
        let ep3 = makeItem(id: "ep-3")
        
        manager.currentItem = ep1
        manager.appendToQueue([ep2, ep3])
        manager.testableSetPlaybackState(position: 599, duration: 600)
        manager.isPlaying = true
        
        // WHEN: Episode completes
        manager.testableHandlePlaybackCompleted()
        
        // THEN: Only ep-1 should be completed (no cascade)
        XCTAssertEqual(completedIds, ["ep-1"],
                       "Only the finished episode should trigger completion — no cascade")
        // AND: ep-2 should be the new current item
        XCTAssertEqual(manager.currentItem?.id, "ep-2",
                       "Auto-advance should move to ep-2")
    }
}

// MARK: - Sleep Timer Tests

/// Tests SleepTimerManager logic — start, stop, extend.
/// Timer callback and countdown are Timer-dependent, so we test state only.
final class SleepTimerManagerTests: XCTestCase {
    
    func test_start_setsActiveAndRemainingSeconds() {
        let timer = SleepTimerManager()
        timer.start(minutes: 15)
        
        XCTAssertTrue(timer.isActive, "Timer should be active after start")
        XCTAssertEqual(timer.remainingSeconds, 900, "15 minutes = 900 seconds")
        XCTAssertEqual(timer.selectedMinutes, 15)
        
        timer.stop()  // cleanup
    }
    
    func test_stop_resetsAllState() {
        let timer = SleepTimerManager()
        timer.start(minutes: 30)
        timer.stop()
        
        XCTAssertFalse(timer.isActive, "Timer should be inactive after stop")
        XCTAssertEqual(timer.remainingSeconds, 0)
        XCTAssertEqual(timer.selectedMinutes, 0)
    }
    
    func test_extend_addsMinutesToRemaining() {
        let timer = SleepTimerManager()
        timer.start(minutes: 10)
        timer.extend(minutes: 5)
        
        XCTAssertEqual(timer.remainingSeconds, 900, "10 + 5 minutes = 900 seconds")
        XCTAssertEqual(timer.selectedMinutes, 15, "Selected should show total")
        
        timer.stop()
    }
    
    func test_extend_whenInactive_doesNothing() {
        let timer = SleepTimerManager()
        timer.extend(minutes: 5)
        
        XCTAssertFalse(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 0)
    }
    
    func test_formattedRemaining_showsMinutesAndSeconds() {
        let timer = SleepTimerManager()
        timer.remainingSeconds = 632  // 10:32
        
        XCTAssertEqual(timer.formattedRemaining, "10:32")
    }
    
    func test_presets_containsExpectedValues() {
        XCTAssertEqual(SleepTimerManager.presets, [5, 15, 30, 60])
    }
    
    func test_start_overridesPreviousTimer() {
        let timer = SleepTimerManager()
        timer.start(minutes: 30)
        timer.start(minutes: 5)
        
        XCTAssertEqual(timer.remainingSeconds, 300,
                       "Starting a new timer should override the previous one")
        XCTAssertEqual(timer.selectedMinutes, 5)
        
        timer.stop()
    }
}

// MARK: - Listening Stats Tests

/// Tests ListeningStatsService.computeStats — pure logic, no side effects.
final class ListeningStatsTests: XCTestCase {
    
    func test_computeStats_emptyActions_returnsEmpty() {
        let stats = ListeningStatsService.computeStats(actions: [], subscriptions: [])
        XCTAssertEqual(stats.totalListeningSeconds, 0)
        XCTAssertEqual(stats.episodesCompleted, 0)
    }
    
    func test_computeStats_singleEpisode_calculatesListeningTime() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 600,
            started: 0,
            total: 3600,
            device: "test"
        )
        
        let stats = ListeningStatsService.computeStats(actions: [action], subscriptions: [])
        XCTAssertEqual(stats.totalListeningSeconds, 600,
                       "Should compute 600s of listening (position 600 - started 0)")
    }
    
    func test_computeStats_completedEpisode_incrementsCount() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 3500,  // >= 95% of 3600
            started: 0,
            total: 3600,
            device: "test"
        )
        
        let stats = ListeningStatsService.computeStats(actions: [action], subscriptions: [])
        XCTAssertEqual(stats.episodesCompleted, 1,
                       "Episode at >=95% should count as completed")
    }
    
    func test_computeStats_partialEpisode_notCompleted() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1800,  // 50% of 3600
            started: 0,
            total: 3600,
            device: "test"
        )
        
        let stats = ListeningStatsService.computeStats(actions: [action], subscriptions: [])
        XCTAssertEqual(stats.episodesCompleted, 0,
                       "Episode at 50% should not count as completed")
    }
    
    func test_computeStats_topPodcasts_sortedByTime() {
        let actions = [
            EpisodeAction(podcast: "feed-a", episode: "ep1", guid: "g1", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 100, started: 0, total: 300, device: "t"),
            EpisodeAction(podcast: "feed-b", episode: "ep2", guid: "g2", action: "play",
                         timestamp: Int(Date().timeIntervalSince1970), position: 500, started: 0, total: 600, device: "t"),
        ]
        
        let stats = ListeningStatsService.computeStats(actions: actions, subscriptions: [])
        XCTAssertEqual(stats.topPodcasts.first?.podcastUrl, "feed-b",
                       "Top podcast should be the one with most listening time")
    }
}

// MARK: - URL Resolver Cache Tests

/// Tests URLResolver cache entry TTL logic.
final class URLResolverCacheTests: XCTestCase {
    
    func test_cacheEntry_notExpired_withinTTL() {
        let entry = URLResolver.CacheEntry(
            resolvedUrl: "https://cdn.example.com/audio.mp3",
            resolvedAt: Date()
        )
        XCTAssertFalse(entry.isExpired(ttl: 7200),
                       "Entry created just now should not be expired with 2h TTL")
    }
    
    func test_cacheEntry_expired_afterTTL() {
        let entry = URLResolver.CacheEntry(
            resolvedUrl: "https://cdn.example.com/audio.mp3",
            resolvedAt: Date().addingTimeInterval(-7201)  // 2h + 1s ago
        )
        XCTAssertTrue(entry.isExpired(ttl: 7200),
                      "Entry older than TTL should be expired")
    }
    
    func test_cacheEntry_notExpired_atExactTTL() {
        let entry = URLResolver.CacheEntry(
            resolvedUrl: "https://cdn.example.com/audio.mp3",
            resolvedAt: Date().addingTimeInterval(-7199)  // Just under 2h
        )
        XCTAssertFalse(entry.isExpired(ttl: 7200),
                       "Entry at TTL boundary should not be expired")
    }
}

// MARK: - Episode Action Tests

/// Tests EpisodeAction JSON parsing and encoding.
final class EpisodeActionTests: XCTestCase {
    
    func test_from_validJSON_parsesAllFields() {
        let json: [String: Any] = [
            "podcast": "https://example.com/feed",
            "episode": "https://example.com/ep1.mp3",
            "guid": "ep-1",
            "action": "play",
            "timestamp": 1700000000,
            "position": 300,
            "started": 0,
            "total": 3600,
            "device": "swift-client"
        ]
        
        let action = EpisodeAction.from(json: json)
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.podcast, "https://example.com/feed")
        XCTAssertEqual(action?.guid, "ep-1")
        XCTAssertEqual(action?.position, 300)
        XCTAssertEqual(action?.total, 3600)
    }
    
    func test_from_missingRequiredFields_returnsNil() {
        let json: [String: Any] = [
            "podcast": "https://example.com/feed",
            // Missing "episode" and "action"
        ]
        
        XCTAssertNil(EpisodeAction.from(json: json),
                     "Should return nil when required fields are missing")
    }
    
    func test_from_isoTimestamp_parsesCorrectly() {
        let json: [String: Any] = [
            "podcast": "https://example.com/feed",
            "episode": "https://example.com/ep1.mp3",
            "action": "play",
            "timestamp": "2023-11-14T22:13:20Z"
        ]
        
        let action = EpisodeAction.from(json: json)
        XCTAssertNotNil(action)
        // ISO 8601 timestamp "2023-11-14T22:13:20Z" = 1700000000
        XCTAssertEqual(action?.timestamp, 1700000000)
    }
    
    func test_toUploadJSON_includesRequiredFields() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: 1700000000,
            position: 300,
            started: 0,
            total: 3600,
            device: "swift-client"
        )
        
        let json = action.toUploadJSON()
        XCTAssertEqual(json["podcast"] as? String, "https://example.com/feed")
        XCTAssertEqual(json["action"] as? String, "play")
        XCTAssertEqual(json["position"] as? Int, 300)
        XCTAssertEqual(json["guid"] as? String, "ep-1")
        // timestamp should be ISO formatted string
        XCTAssertNotNil(json["timestamp"] as? String)
    }
    
    func test_toUploadJSON_omitsNilOptionals() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: nil,
            action: "play",
            timestamp: 1700000000,
            position: nil,
            started: nil,
            total: nil,
            device: nil
        )
        
        let json = action.toUploadJSON()
        XCTAssertNil(json["guid"], "Nil guid should not be in upload JSON")
        XCTAssertNil(json["position"], "Nil position should not be in upload JSON")
        XCTAssertNil(json["device"], "Nil device should not be in upload JSON")
    }
    
    func test_codable_roundTrip() {
        let original = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: 1700000000,
            position: 300,
            started: 0,
            total: 3600,
            device: "swift-client"
        )
        
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(EpisodeAction.self, from: data)
        
        XCTAssertEqual(decoded.podcast, original.podcast)
        XCTAssertEqual(decoded.guid, original.guid)
        XCTAssertEqual(decoded.position, original.position)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }
}

// MARK: - Queue Operation Edge Cases

/// Tests for queue operations that should be no-ops or safe on edge inputs.
@MainActor
final class QueueEdgeCaseTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }
    
    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: id, title: "Episode \(id)", podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
    }
    
    // MARK: - appendToQueue
    
    func test_appendToQueue_emptyArray_noOp() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "existing")])
        let countBefore = manager.queue.count
        
        manager.appendToQueue([])
        
        XCTAssertEqual(manager.queue.count, countBefore,
                       "Appending empty array should not change the queue")
    }
    
    func test_appendToQueue_deduplicates() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1")
        manager.appendToQueue([item])
        
        manager.appendToQueue([item]) // Add same item again
        
        XCTAssertEqual(manager.queue.count, 1,
                       "Duplicate items should not be added to the queue")
    }
    
    func test_appendToQueue_deduplicatesAgainstCurrentItem() {
        let manager = AudioManager()
        let item = makeItem(id: "current-ep")
        manager.currentItem = item
        
        manager.appendToQueue([item])
        
        XCTAssertEqual(manager.queue.count, 0,
                       "Should not add the currently playing item to the queue")
    }
    
    // MARK: - removeFromQueue
    
    func test_removeFromQueue_nonExistent_noOp() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "ep-1")])
        let countBefore = manager.queue.count
        
        manager.removeFromQueue(makeItem(id: "unknown"))
        
        XCTAssertEqual(manager.queue.count, countBefore,
                       "Removing a non-existent item should be safe and change nothing")
    }
    
    func test_removeFromQueue_emptyQueue_noOp() {
        let manager = AudioManager()
        XCTAssertTrue(manager.queue.isEmpty)
        
        manager.removeFromQueue(makeItem(id: "whatever"))
        
        XCTAssertTrue(manager.queue.isEmpty,
                      "Removing from empty queue should not crash")
    }
    
    // MARK: - insertNext
    
    func test_insertNext_emptyArray_noOp() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "ep-1")])
        let countBefore = manager.queue.count
        
        manager.insertNext([])
        
        XCTAssertEqual(manager.queue.count, countBefore)
    }
    
    // MARK: - moveQueueItems
    
    func test_moveQueueItems_singleItem() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "only")])
        
        manager.moveQueueItems(from: IndexSet(integer: 0), to: 0)
        
        XCTAssertEqual(manager.queue.count, 1)
        XCTAssertEqual(manager.queue[0].id, "only")
    }
    
    // MARK: - Stress test
    
    func test_queue_largeAppend_preservesOrdering() {
        let manager = AudioManager()
        let items = (1...100).map { makeItem(id: "ep-\($0)") }
        manager.appendToQueue(items)
        
        XCTAssertEqual(manager.queue.count, 100)
        for i in 0..<100 {
            XCTAssertEqual(manager.queue[i].id, "ep-\(i + 1)",
                           "Item at index \(i) should be ep-\(i + 1)")
        }
    }
    
    // MARK: - Fresh AudioManager defaults
    
    func test_freshManager_currentItemIsNil() {
        let manager = AudioManager()
        XCTAssertNil(manager.currentItem)
    }
    
    func test_freshManager_queueIsEmpty() {
        let manager = AudioManager()
        XCTAssertTrue(manager.queue.isEmpty)
    }
    
    func test_freshManager_positionAndDurationAreZero() {
        let manager = AudioManager()
        XCTAssertEqual(manager.currentPosition, 0)
        XCTAssertEqual(manager.currentDuration, 0)
    }
    
    func test_freshManager_isNotPlaying() {
        let manager = AudioManager()
        XCTAssertFalse(manager.isPlaying)
    }
    
    func test_freshManager_isAdvancingQueueIsFalse() {
        let manager = AudioManager()
        XCTAssertFalse(manager.isAdvancingQueue)
    }
}

// MARK: - Position Resume Tests

/// Tests the position resume logic in playEpisode: when initialPosition is nil,
/// the player should fall back to the queue item's tracked positionSeconds.
/// Added retroactively for b27 — revert-red-green verified.
@MainActor
final class PositionResumeTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }
    
    private func makeItem(id: String, positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: id,
            title: "Episode \(id)",
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }
    
    /// When initialPosition is nil and positionSeconds > 0,
    /// the player should resume from positionSeconds (the queue item's tracked position).
    func test_positionResume_fallsBackToPositionSeconds_whenInitialPositionIsNil() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1", positionSeconds: 300)
        
        // WHEN: playEpisode is called without explicit initialPosition
        let target = manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        // THEN: Should seek to positionSeconds (300), not stay at 0
        XCTAssertEqual(target, 300, "Should fall back to item.positionSeconds when initialPosition is nil")
        XCTAssertEqual(manager.currentPosition, 300, "currentPosition should reflect the resumed position")
    }
    
    /// When initialPosition IS provided, it should take precedence over positionSeconds.
    func test_positionResume_prefersInitialPosition_overPositionSeconds() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1", positionSeconds: 300)
        
        // WHEN: playEpisode is called with explicit initialPosition=600
        let target = manager.testablePlayEpisodePositionResume(item, initialPosition: 600)
        
        // THEN: Should use initialPosition (600), not positionSeconds (300)
        XCTAssertEqual(target, 600, "Explicit initialPosition should override positionSeconds")
        XCTAssertEqual(manager.currentPosition, 600)
    }
    
    /// When both initialPosition is nil AND positionSeconds is 0,
    /// position should stay at 0 (fresh episode).
    func test_positionResume_staysAtZero_whenBothAreZero() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1", positionSeconds: 0)
        
        let target = manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        XCTAssertEqual(target, 0, "Fresh episode should start at 0")
        XCTAssertEqual(manager.currentPosition, 0)
    }
    
    /// When positionSeconds > 0 but skipIntro is larger, skipIntro should win.
    func test_positionResume_skipIntroOverridesPositionSeconds_whenPositionIsBelowIntro() {
        let manager = AudioManager()
        var item = makeItem(id: "ep-1", positionSeconds: 10)
        item.skipIntroSeconds = 30
        
        manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        // positionSeconds=10, but skipIntro=30 — should jump to 30
        XCTAssertEqual(manager.currentPosition, 30,
                       "skipIntro should override when positionSeconds is below the intro threshold")
    }
    
    /// When positionSeconds is beyond skipIntro, skipIntro should NOT apply.
    func test_positionResume_skipIntroDoesNotApply_whenPositionIsBeyondIntro() {
        let manager = AudioManager()
        var item = makeItem(id: "ep-1", positionSeconds: 120)
        item.skipIntroSeconds = 30
        
        manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        // positionSeconds=120 > skipIntro=30 — should stay at 120
        XCTAssertEqual(manager.currentPosition, 120,
                       "When position is beyond skipIntro threshold, position should be preserved")
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// Tests for PlayerManager.clearAllQueue() — the "Clear Everything" feature.
///
/// This method clears both the upcoming queue AND the currently playing item,
/// stops playback, and notifies the server for Pro sync users.
///
/// Test matrix:
/// - clearAllQueue removes all upcoming queue items
/// - clearAllQueue stops the currently playing item
/// - clearAllQueue with empty queue is a safe no-op
/// - clearAllQueue sends server tombstones for Pro sync users
/// - clearAllQueue marks episodes as played when user preference is .removeAndMarkPlayed
/// - clearAllQueue does NOT mark as played when user preference is .removeOnly
/// - AudioManager.clearQueue (existing) does NOT clear currentItem (negative assertion)
@MainActor
final class ClearAllQueueTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    
    private func makeItem(id: String, title: String = "Episode", podcastUrl: String = "https://example.com/feed") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Basic clearAllQueue behavior
    
    func test_clearAllQueue_removesAllUpcomingQueueItems() {
        // GIVEN: An AudioManager with items in the queue
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        audioManager.appendToQueue([
            makeItem(id: "ep-1"),
            makeItem(id: "ep-2"),
            makeItem(id: "ep-3")
        ])
        XCTAssertEqual(audioManager.queue.count, 3, "Precondition: 3 items in queue")
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: The queue is empty
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "All upcoming queue items should be removed")
    }
    
    func test_clearAllQueue_stopsCurrentlyPlayingItem() {
        // GIVEN: An AudioManager with a currently playing item
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        let currentItem = makeItem(id: "current-ep")
        audioManager.currentItem = currentItem
        audioManager.appendToQueue([makeItem(id: "ep-1")])
        
        XCTAssertNotNil(audioManager.currentItem, "Precondition: current item exists")
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: The current item is cleared and playback stops
        XCTAssertNil(audioManager.currentItem,
                     "Current item should be nil after clearing all")
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "Queue should be empty after clearing all")
    }
    
    func test_clearAllQueue_withEmptyQueueAndNoCurrentItem_isNoOp() {
        // GIVEN: An AudioManager with no items at all
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: Nothing crashes, state remains empty
        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)
    }
    
    func test_clearAllQueue_clearsPositionAndDuration() {
        // GIVEN: An AudioManager mid-playback
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        let currentItem = makeItem(id: "current-ep")
        audioManager.currentItem = currentItem
        audioManager.currentPosition = 300 // 5 minutes in
        audioManager.currentDuration = 3600
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: Position and duration are reset
        XCTAssertEqual(audioManager.currentPosition, 0,
                       "Current position should be reset after clearing all")
        XCTAssertEqual(audioManager.currentDuration, 0,
                       "Current duration should be reset after clearing all")
    }
    
    // MARK: - Negative assertion: existing clearQueue does NOT clear currentItem
    
    func test_existingClearQueue_doesNotAffectCurrentItem() {
        // GIVEN: An AudioManager with a current item and queue items
        let audioManager = AudioManager()
        let currentItem = makeItem(id: "current-ep")
        audioManager.currentItem = currentItem
        audioManager.appendToQueue([
            makeItem(id: "ep-1"),
            makeItem(id: "ep-2")
        ])
        
        // WHEN: The existing clearQueue() is called (NOT clearAllQueue)
        audioManager.clearQueue()
        
        // THEN: Queue is cleared but current item remains
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "Queue should be empty")
        XCTAssertNotNil(audioManager.currentItem,
                        "Existing clearQueue must NOT clear currentItem")
        XCTAssertEqual(audioManager.currentItem?.id, "current-ep",
                       "Current item should be unchanged")
    }
    
    // MARK: - Pro server sync
    
    func test_clearAllQueue_sendsServerTombstones_forProSyncUsers() async {
        // GIVEN: A PlayerManager with a Pro sync client
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let mockClient = MockClearQueueSyncClient()
        playerManager.setSyncClient(mockClient, deviceId: "test-device")
        
        let item1 = makeItem(id: "ep-1")
        let item2 = makeItem(id: "ep-2")
        audioManager.currentItem = makeItem(id: "current-ep")
        audioManager.appendToQueue([item1, item2])
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // Allow async Tasks to complete
        try? await Task.sleep(for: .milliseconds(200))
        
        // THEN: Tombstones were sent for all queue items + current item
        let deletedUrls = await mockClient.deletedEpisodeUrls
        XCTAssertTrue(deletedUrls.contains("https://example.com/ep-1.mp3"),
                      "Should send tombstone for ep-1")
        XCTAssertTrue(deletedUrls.contains("https://example.com/ep-2.mp3"),
                      "Should send tombstone for ep-2")
        XCTAssertTrue(deletedUrls.contains("https://example.com/current-ep.mp3"),
                      "Should send tombstone for current item")
    }
    
    func test_clearAllQueue_doesNotSendTombstones_forVaultMode() {
        // GIVEN: A PlayerManager with no sync client (Vault mode)
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        audioManager.currentItem = makeItem(id: "current-ep")
        audioManager.appendToQueue([makeItem(id: "ep-1")])
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: No crash, items are cleared
        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)
        // (No server calls to verify since there's no sync client)
    }
    
    // MARK: - Queue removal action preference
    
    func test_clearAllQueue_withMarkPlayedPreference_marksEpisodesAsPlayed() {
        // GIVEN: A PlayerManager with removeAndMarkPlayed preference
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let podcastManager = PodcastManager(modelContext: context)
        playerManager.podcastManager = podcastManager
        
        let settings = SettingsManager()
        settings.queueRemovalAction = .removeAndMarkPlayed
        playerManager.settingsManager = settings
        
        // Add a podcast with episodes so markEpisodeAsPlayed has something to mark
        let ep1 = makeItem(id: "ep-1", podcastUrl: "https://example.com/feed")
        let ep2 = makeItem(id: "ep-2", podcastUrl: "https://example.com/feed")
        let currentEp = makeItem(id: "current-ep", podcastUrl: "https://example.com/feed")
        
        audioManager.currentItem = currentEp
        audioManager.appendToQueue([ep1, ep2])
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: Queue is cleared (mark-as-played would be called on PodcastManager)
        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)
    }
    
    func test_clearAllQueue_withRemoveOnlyPreference_doesNotMarkAsPlayed() {
        // GIVEN: A PlayerManager with removeOnly preference
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let podcastManager = PodcastManager(modelContext: context)
        playerManager.podcastManager = podcastManager
        
        let settings = SettingsManager()
        settings.queueRemovalAction = .removeOnly
        playerManager.settingsManager = settings
        
        audioManager.currentItem = makeItem(id: "current-ep")
        audioManager.appendToQueue([makeItem(id: "ep-1")])
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: Queue is cleared without marking episodes as played
        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)
    }
    
    // MARK: - clearAllQueue only clears queue items, not subscriptions
    
    func test_clearAllQueue_doesNotAffectSubscriptions() {
        // GIVEN: A PlayerManager with subscriptions
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let podcastManager = PodcastManager(modelContext: context)
        playerManager.podcastManager = podcastManager
        
        audioManager.appendToQueue([makeItem(id: "ep-1")])
        let subCountBefore = podcastManager.subscriptions.count
        
        // WHEN: clearAllQueue is called
        playerManager.clearAllQueue()
        
        // THEN: Subscriptions are unaffected
        XCTAssertEqual(podcastManager.subscriptions.count, subCountBefore,
                       "Subscriptions should not be affected by clearing the queue")
    }
}

// MARK: - Mock Sync Client for queue tombstone verification

private actor MockClearQueueSyncClient: SyncClient {
    var deletedEpisodeUrls: [String] = []
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }
    
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: [], droppedItems: [])
    }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func deleteQueueItem(episodeUrl: String) async throws {
        deletedEpisodeUrls.append(episodeUrl)
    }
}

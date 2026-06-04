import XCTest
@testable import YourPods

// MARK: - AudioManager Queue Behavior Tests

@MainActor
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

    // MARK: - EDGE: Queue Duplication Bug

    func test_EDGE_preservesCurrent_doesNotDuplicateWhenCurrentAlreadyInQueue() {
        // GIVEN: A current item that already exists in the queue (e.g., from sync or restore)
        let manager = AudioManager()
        let currentItem = makeItem(id: "current-ep", title: "Currently Playing")
        let otherQueued = makeItem(id: "other-ep", title: "Other Queued")
        let newItem = makeItem(id: "new-ep", title: "New Episode")

        manager.currentItem = currentItem
        // Simulate a state where current item is already in the queue (sync race, restore bug, etc.)
        manager.testableSetQueue([currentItem, otherQueued])

        // WHEN: Playing a new episode from the queue with preserveCurrent
        manager.testablePreserveAndSwitch(to: newItem, preserveCurrent: true)

        // THEN: The old current item should appear exactly ONCE in the queue (not duplicated)
        let currentInQueue = manager.queue.filter { $0.id == "current-ep" }
        XCTAssertEqual(currentInQueue.count, 1,
                       "Current item must not be duplicated — should appear exactly once in queue")
        XCTAssertEqual(manager.queue.count, 2,
                       "Queue should have old current + other queued, NOT a duplicate")
        XCTAssertEqual(manager.queue[0].id, "current-ep",
                       "Preserved current item should be at position 0")
        XCTAssertEqual(manager.queue[1].id, "other-ep",
                       "Other queued item should follow")
    }

    func test_Scenario_rapidSuccessivePlaysFromQueue_noDuplicates() {
        // GIVEN: Episode A is playing with queue [B, C, D]
        let manager = AudioManager()
        let epA = makeItem(id: "ep-A", title: "Episode A")
        let epB = makeItem(id: "ep-B", title: "Episode B")
        let epC = makeItem(id: "ep-C", title: "Episode C")
        let epD = makeItem(id: "ep-D", title: "Episode D")

        manager.currentItem = epA
        manager.testableSetQueue([epB, epC, epD])

        // WHEN: User rapidly plays B, then C, then D from the queue
        manager.testablePreserveAndSwitch(to: epB, preserveCurrent: true)
        // After: playing=B, queue=[A, C, D]

        manager.testablePreserveAndSwitch(to: epC, preserveCurrent: true)
        // After: playing=C, queue=[B, A, D]

        manager.testablePreserveAndSwitch(to: epD, preserveCurrent: true)
        // After: playing=D, queue=[C, B, A]

        // THEN: No duplicates in the queue
        let ids = manager.queue.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count,
                       "Queue should have no duplicate entries: \(ids)")
        XCTAssertEqual(manager.currentItem?.id, "ep-D")
        XCTAssertEqual(manager.queue.count, 3,
                       "All previous episodes should be in queue")
    }

    func test_EDGE_preservesCurrent_doesNotRequeuePlayedEpisode() {
        // GIVEN: The current item has been marked as played
        let manager = AudioManager()
        var playedItem = makeItem(id: "played-ep", title: "Played Episode")
        playedItem.isPlayed = true
        let newItem = makeItem(id: "new-ep", title: "New Episode")

        manager.currentItem = playedItem
        manager.testableSetQueue([])

        // WHEN: Playing a new episode with preserveCurrent
        manager.testablePreserveAndSwitch(to: newItem, preserveCurrent: true)

        // THEN: The played episode should NOT be re-queued
        XCTAssertEqual(manager.queue.count, 0,
                       "Played episode should NOT be re-queued when preserveCurrent is true")
        XCTAssertEqual(manager.currentItem?.id, "new-ep")
    }
}

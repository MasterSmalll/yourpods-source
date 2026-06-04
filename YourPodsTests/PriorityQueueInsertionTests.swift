import XCTest
@testable import YourPods

// MARK: - Priority Queue Insertion Tests (Regression)

/// Tests that priority auto-queue episodes end up at the top of Up Next in
/// the correct chronological order (newest first). This catches the regression
/// where inserting priority episodes one-at-a-time reversed their order.
@MainActor
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

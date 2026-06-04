import XCTest
@testable import YourPods

// MARK: - Queue Persistence Tests

@MainActor
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

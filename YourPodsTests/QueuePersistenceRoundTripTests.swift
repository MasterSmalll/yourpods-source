import XCTest
@testable import YourPods

// MARK: - Integration: Queue Persistence Round-Trip

@MainActor
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

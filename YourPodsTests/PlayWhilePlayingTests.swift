import XCTest
@testable import YourPods

// MARK: - Integration: Play-While-Playing (Preserve Current)

@MainActor
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

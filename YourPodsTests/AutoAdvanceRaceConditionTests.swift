import XCTest
@testable import YourPods

// MARK: - Auto-Advance Race Condition Tests (Regression)

/// Tests that auto-advance does not cascade through the entire queue.
/// Regression: a KVO callback from player.removeAllItems() could fire AFTER
/// isAdvancingQueue and isLoadingNewEpisode were reset, causing
/// handlePlaybackCompleted() to fire again and mark the new episode as
/// complete before it even starts playing — cascading through every item.
@MainActor
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

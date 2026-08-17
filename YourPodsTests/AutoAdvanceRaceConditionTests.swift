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

    // MARK: - Deferred playback-rate on .readyToPlay (silent-stop regression)

    func test_playStartsAtPerEpisodeRate_whenItemBecomesReady_REGRESSION() {
        // GIVEN: a non-1.0 rate was deferred because the freshly-loaded item
        // wasn't .readyToPlay yet. Setting player.rate directly on an unready
        // AVQueuePlayer item is silently dropped — the auto-advance "silent
        // stop" bug. The rate must be applied once the item becomes ready.
        let manager = AudioManager()
        manager.testablePendingPlaybackRate = 1.5

        // WHEN: the item reaches .readyToPlay and the status observer runs
        manager.testableHandleItemReadyToPlay()

        // THEN: the deferred rate is applied and the pending flag cleared, so
        // playback actually starts (at the right speed) instead of staying silent.
        XCTAssertNil(manager.testablePendingPlaybackRate,
                     "Deferred rate must be applied and cleared once the item is ready")
    }

    func test_pauseClearsPendingRate() {
        // GIVEN: a deferred rate is pending (item still loading)
        let manager = AudioManager()
        manager.testablePendingPlaybackRate = 1.5

        // WHEN: the user pauses before the item became ready
        manager.pause()

        // THEN: the pending rate is dropped so it can't kick playback after pause.
        XCTAssertNil(manager.testablePendingPlaybackRate,
                     "pause() must clear a pending deferred rate")
    }

    // MARK: - skipToNext (manual advance — first direct coverage)

    func test_skipToNext_advancesToNextAndFiresCompletionOnce() async {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.appendToQueue([makeItem(id: "ep-2")])
        manager.isPlaying = true
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }

        manager.skipToNext()

        let advanced = await pollUntil { manager.currentItem?.id == "ep-2" }
        XCTAssertTrue(advanced, "skipToNext must advance currentItem to the next queued episode")
        XCTAssertEqual(completedIds, ["ep-1"],
                       "exactly one completion callback for the skipped episode")
        XCTAssertTrue(manager.queue.isEmpty, "next item must be popped from Up Next")
    }

    func test_skipToNext_emptyQueue_stopsWithoutFiringCompletion() {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }

        manager.skipToNext()

        XCTAssertNil(manager.currentItem, "empty-queue skip stops playback")
        XCTAssertFalse(manager.isPlaying)
        XCTAssertTrue(completedIds.isEmpty,
                      "empty-queue skip must NOT fire onEpisodeCompleted — callers on this path mark played themselves (PlayerManager relies on this)")
    }

    func test_skipToNext_autoPlayFalse_advancesWithoutStartingPlayback() async {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.appendToQueue([makeItem(id: "ep-2")])
        manager.isPlaying = false   // user is paused

        manager.skipToNext(autoPlay: false)

        let advanced = await pollUntil { manager.currentItem?.id == "ep-2" }
        XCTAssertTrue(advanced, "autoPlay:false must still advance the queue")
        XCTAssertFalse(manager.isPlaying,
                       "autoPlay:false must load the next episode paused — play() must never run (paused-handoff precedent)")
    }
}

/// Poll until `condition` is true or `timeout` elapses, yielding to the main actor
/// between checks. No real-time sleeps — the advance Task runs on the main actor,
/// and playEpisode sets currentItem in its synchronous prefix, so a few yields
/// are enough on the happy path.
@MainActor
fileprivate func pollUntil(
    timeout: TimeInterval = 2.0,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        await Task.yield()
    }
    return condition()
}

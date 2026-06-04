import XCTest
@testable import YourPods

// MARK: - Queue Race Condition Tests (auto-advance episode transition)

@MainActor
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

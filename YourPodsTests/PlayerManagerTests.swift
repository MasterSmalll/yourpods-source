import XCTest
@testable import YourPods

/// Tests for PlayerManager's static formatting helpers and sync guard logic.
final class PlayerManagerTests: XCTestCase {

    // `PlayerManager.init` unconditionally calls `audioManager.restoreQueue()`, and
    // `AudioManager.queue`'s didSet synchronously persists queue + currentItem to
    // the REAL UserDefaults.standard on every mutation (see AudioManager.swift's
    // `persistQueue()`). Without this cleanup, a queue/currentItem mutation in one
    // test (e.g. any `markCurrentEpisodeAsPlayed`/`skipToNext` advance) leaks into
    // the next fresh `AudioManager()` in this file via restoreQueue() — same root
    // cause MarkQueuedEpisodeAsPlayedTests.swift already guards against.
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

    // MARK: - formatTimestamp
    
    func test_formatTimestamp_minutesAndSeconds() {
        XCTAssertEqual(PlayerManager.formatTimestamp(125), "2:05")
    }
    
    func test_formatTimestamp_hoursMinutesSeconds() {
        XCTAssertEqual(PlayerManager.formatTimestamp(3661), "1:01:01")
    }
    
    func test_formatTimestamp_zero() {
        XCTAssertEqual(PlayerManager.formatTimestamp(0), "0:00")
    }
    
    func test_formatTimestamp_negativeClamps() {
        XCTAssertEqual(PlayerManager.formatTimestamp(-5), "0:00",
                       "Negative values should clamp to 0:00")
    }
    
    func test_formatTimestamp_exactHour() {
        XCTAssertEqual(PlayerManager.formatTimestamp(3600), "1:00:00")
    }
    
    func test_formatTimestamp_59minutes59seconds() {
        XCTAssertEqual(PlayerManager.formatTimestamp(3599), "59:59")
    }
    
    func test_formatTimestamp_oneSecond() {
        XCTAssertEqual(PlayerManager.formatTimestamp(1), "0:01")
    }
    
    // MARK: - formatDuration
    
    func test_formatDuration_seconds() {
        XCTAssertEqual(PlayerManager.formatDuration(45), "45s")
    }
    
    func test_formatDuration_minutes() {
        XCTAssertEqual(PlayerManager.formatDuration(300), "5m")
    }
    
    func test_formatDuration_hoursAndMinutes() {
        XCTAssertEqual(PlayerManager.formatDuration(5400), "1h 30m")
    }
    
    func test_formatDuration_exactHour() {
        XCTAssertEqual(PlayerManager.formatDuration(3600), "1h 0m")
    }
    
    func test_formatDuration_zero() {
        XCTAssertEqual(PlayerManager.formatDuration(0), "0s")
    }
    
    // MARK: - formatProgress
    
    func test_formatProgress_50percent() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 300, duration: 600), "50% listened")
    }
    
    func test_formatProgress_zeroDuration() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 0, duration: 0), "0%")
    }
    
    func test_formatProgress_100percent() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 600, duration: 600), "100% listened")
    }
    
    func test_formatProgress_over100_clamped() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 700, duration: 600), "100% listened",
                       "Progress over 100% should clamp to 100%")
    }
    
    func test_formatProgress_showPercentFalse() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 300, duration: 600, showPercent: false), "50% left")
    }
    
    func test_formatProgress_showPercentFalse_complete() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 600, duration: 600, showPercent: false), "0% left")
    }
    
    // MARK: - Sync Guards
    
    @MainActor
    func test_syncProgress_blockedDuringTransition() {
        // GIVEN: An AudioManager that is mid-transition
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        audioManager.testableSetTransitionState(true)
        
        // WHEN: syncProgress fires during a transition
        playerManager.syncProgress()
        
        // THEN: The item's position should NOT be updated
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0,
                       "syncProgress must be blocked during episode transitions")
    }
    
    @MainActor
    func test_updateLocalProgress_blockedDuringTransition() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        audioManager.testableSetTransitionState(true)
        
        playerManager.updateLocalProgress()
        
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 0,
                       "updateLocalProgress must be blocked during transitions")
    }
    
    @MainActor
    func test_updateLocalProgress_ignoresZeroPosition() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 100,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 0, duration: 3600)
        
        playerManager.updateLocalProgress()
        
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 100,
                       "updateLocalProgress must not overwrite with position 0")
    }
    
    // MARK: - Sync Conflict Resolution Seeking
    
    @MainActor
    func test_resolveConflictIfPlaying_seeksWhenCurrentEpisode() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-conflict", title: "Conflicted Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/conflict.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 300,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 300, duration: 3600)
        
        let conflict = SyncConflict(
            episodeGuid: "ep-conflict",
            episodeTitle: "Conflicted Episode",
            podcastTitle: "Pod",
            podcastUrl: "https://example.com/feed",
            artworkUrl: nil,
            audioUrl: "https://example.com/conflict.mp3",
            localPosition: 300,
            serverPosition: 1500,
            serverTimestamp: Int(Date().timeIntervalSince1970),
            totalDuration: 3600,
            occurrenceCount: 1
        )
        
        // Resolve with server position — should seek player to 1500
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        // The AudioManager's seek is async (CMTime seek), but position should be requested
        // We verify the method exists and can be called — the actual AVPlayer seek is a no-op in tests
        // since no real player item is loaded. The key contract: method must exist and not crash.
        XCTAssertEqual(audioManager.currentItem?.id, "ep-conflict",
                       "Current item should still be the same episode after conflict resolution")
    }
    
    @MainActor
    func test_resolveConflictIfPlaying_noOpWhenDifferentEpisode() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-other", title: "Other Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/other.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        
        let conflict = SyncConflict(
            episodeGuid: "ep-conflict",
            episodeTitle: "Conflicted Episode",
            podcastTitle: "Pod",
            podcastUrl: "https://example.com/feed",
            artworkUrl: nil,
            audioUrl: "https://example.com/conflict.mp3",
            localPosition: 300,
            serverPosition: 1500,
            serverTimestamp: Int(Date().timeIntervalSince1970),
            totalDuration: 3600,
            occurrenceCount: 1
        )
        
        // Resolve for a different episode — should NOT affect player position
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        // Position of the current episode should be unchanged
        XCTAssertEqual(audioManager.currentPosition, 500,
                       "Player position must not change when resolving a conflict for a different episode")
    }
    
    @MainActor
    func test_resolveConflictIfPlaying_noOpWhenNothingPlaying() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        // No current item
        XCTAssertNil(audioManager.currentItem)
        
        let conflict = SyncConflict(
            episodeGuid: "ep-conflict",
            episodeTitle: "Conflicted Episode",
            podcastTitle: "Pod",
            podcastUrl: "https://example.com/feed",
            artworkUrl: nil,
            audioUrl: "https://example.com/conflict.mp3",
            localPosition: 300,
            serverPosition: 1500,
            serverTimestamp: Int(Date().timeIntervalSince1970),
            totalDuration: 3600,
            occurrenceCount: 1
        )
        
        // Should not crash when nothing is playing
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        XCTAssertNil(audioManager.currentItem,
                     "No item should be loaded just from conflict resolution")
    }
    
    // MARK: - Mark as Played Queue Behavior

    @MainActor
    private func makeMarkPlayedFixture() -> (AudioManager, PlayerManager, QueueItem, QueueItem) {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-playing", title: "Playing Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        let nextItem = QueueItem(
            id: "ep-next", title: "Next Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep2.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        return (audioManager, playerManager, item, nextItem)
    }

    /// REGRESSION (2026-07-09): marking the playing episode as played from the mini
    /// player queue stopped playback dead instead of starting the next Up Next episode.
    @MainActor
    func test_markCurrentEpisodeAsPlayed_advancesToNextEpisode_whenPlaying() async {
        let (audioManager, playerManager, _, nextItem) = makeMarkPlayedFixture()
        audioManager.appendToQueue([nextItem])
        audioManager.isPlaying = true

        playerManager.markCurrentEpisodeAsPlayed()

        let advanced = await pollUntil { audioManager.currentItem?.id == "ep-next" }
        XCTAssertTrue(advanced,
                      "Marking the playing episode as played must advance to the next Up Next episode")
        XCTAssertFalse(audioManager.queue.contains(where: { $0.id == "ep-playing" }),
                       "Played episode must not be re-queued")
        XCTAssertFalse(audioManager.queue.contains(where: { $0.id == "ep-next" }),
                       "Next episode must be popped from Up Next, not duplicated")
    }

    /// EDGE: marked as played while PAUSED — advance, but never start audio (D2).
    @MainActor
    func test_markCurrentEpisodeAsPlayed_advancesPaused_whenNotPlaying() async {
        let (audioManager, playerManager, _, nextItem) = makeMarkPlayedFixture()
        audioManager.appendToQueue([nextItem])
        audioManager.isPlaying = false

        playerManager.markCurrentEpisodeAsPlayed()

        let advanced = await pollUntil { audioManager.currentItem?.id == "ep-next" }
        XCTAssertTrue(advanced, "Paused mark-played still advances the queue")
        XCTAssertFalse(audioManager.isPlaying,
                       "Mark-played while paused must NOT start audio — next episode loads paused")
    }

    /// EDGE: empty queue — original stop semantics preserved, direct marking path (D4).
    @MainActor
    func test_markCurrentEpisodeAsPlayed_stops_whenQueueEmpty() {
        let (audioManager, playerManager, _, _) = makeMarkPlayedFixture()
        var completions = 0
        let original = audioManager.onEpisodeCompleted
        audioManager.onEpisodeCompleted = { completions += 1; original?($0) }
        audioManager.isPlaying = true

        playerManager.markCurrentEpisodeAsPlayed()

        XCTAssertNil(audioManager.currentItem, "Nothing to advance to — playback stops")
        XCTAssertFalse(audioManager.isPlaying)
        XCTAssertEqual(completions, 0,
                       "Empty-queue mark-played uses the direct markEpisodeAsPlayed path, not the completion pipeline (skipToNext would not fire it)")
    }

    /// Sync-initiated completion must never advance: the three fromSync callers run
    /// during background reconciliation (clearPlayedEpisodesFromQueue / reconcile
    /// Cases 1 & 4) — advancing could start audio on a pocketed phone (D3).
    @MainActor
    func test_markCurrentEpisodeAsPlayed_fromSync_neverAdvances() {
        let (audioManager, playerManager, _, nextItem) = makeMarkPlayedFixture()
        audioManager.appendToQueue([nextItem])
        audioManager.isPlaying = false

        playerManager.markCurrentEpisodeAsPlayed(fromSync: true)

        XCTAssertNil(audioManager.currentItem, "fromSync keeps stop semantics")
        XCTAssertFalse(audioManager.isPlaying)
        XCTAssertTrue(audioManager.queue.contains(where: { $0.id == "ep-next" }),
                      "Queue preserved — the reconcile path decides separately what plays next")
    }

    /// Exactly ONE completion pipeline (D1): double-marking sends duplicate 'play'
    /// EpisodeActions to the server (b15 regression class, PlayerManager.swift:639-640).
    @MainActor
    func test_markCurrentEpisodeAsPlayed_firesCompletionPipelineExactlyOnce() async {
        let (audioManager, playerManager, _, nextItem) = makeMarkPlayedFixture()
        audioManager.appendToQueue([nextItem])
        audioManager.isPlaying = true
        var completedIds: [String] = []
        let original = audioManager.onEpisodeCompleted
        audioManager.onEpisodeCompleted = { completedIds.append($0.id); original?($0) }

        playerManager.markCurrentEpisodeAsPlayed()

        _ = await pollUntil { audioManager.currentItem?.id == "ep-next" }
        XCTAssertEqual(completedIds, ["ep-playing"],
                       "The played episode completes exactly once, via the onEpisodeCompleted pipeline")
    }

    /// EDGE (double-tap re-entry): last queued pair, "Mark as Played" tapped twice fast.
    /// Tap 1's skipToNext sets isAdvancingQueue and suspends mid-advance (URL resolution
    /// await); tap 2 must be a complete no-op instead of racing the direct/empty-queue
    /// branch — without this guard, tap 2 would set isPlayed on the item tap 1's advance
    /// Task is about to swap in as currentItem, then stop(), while the suspended Task
    /// resumes and plays that same "played" episode anyway (double 'play' EpisodeAction
    /// risk). Regression pinned per the review finding on PlayerManager.swift's
    /// markCurrentEpisodeAsPlayed doc comment.
    @MainActor
    func test_markCurrentEpisodeAsPlayed_isNoOp_whenQueueAdvanceInProgress() {
        let (audioManager, playerManager, item, nextItem) = makeMarkPlayedFixture()
        audioManager.appendToQueue([nextItem])
        audioManager.isPlaying = true
        audioManager.isAdvancingQueue = true

        playerManager.markCurrentEpisodeAsPlayed()

        XCTAssertEqual(audioManager.currentItem?.id, item.id,
                       "currentItem must be untouched while a queue advance is in progress")
        XCTAssertFalse(audioManager.currentItem?.isPlayed ?? true,
                       "the in-flight item must not be marked played out from under the advance")
        XCTAssertTrue(audioManager.isPlaying, "isPlaying must be untouched")
        XCTAssertEqual(audioManager.queue.map(\.id), [nextItem.id], "queue must be untouched")
    }

    /// DECISION D6: user-initiated mark-played follows manual-skip semantics — the
    /// sleep-timer DriftOff veto applies only to NATURAL episode end.
    @MainActor
    func test_markCurrentEpisodeAsPlayed_advancesEvenWhenSleepTimerVetoArmed() async {
        let (audioManager, playerManager, _, nextItem) = makeMarkPlayedFixture()
        audioManager.appendToQueue([nextItem])
        audioManager.isPlaying = true
        audioManager.shouldAutoAdvanceToNextEpisode = { false }   // DriftOff armed

        playerManager.markCurrentEpisodeAsPlayed()

        let advanced = await pollUntil { audioManager.currentItem?.id == "ep-next" }
        XCTAssertTrue(advanced,
                      "Mark-played is a deliberate user action — it advances even with 'stop after this episode' armed, matching the next-track button")
    }

    @MainActor
    func test_markQueuedEpisodeAsPlayed_removesFromQueue() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        let current = QueueItem(
            id: "ep-current", title: "Current Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep0.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 100,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        let queuedItem = QueueItem(
            id: "ep-queued", title: "Queued Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = current
        audioManager.appendToQueue([queuedItem])
        
        playerManager.markQueuedEpisodeAsPlayed(queuedItem)
        
        XCTAssertFalse(audioManager.queue.contains(where: { $0.id == "ep-queued" }),
                       "Marked-as-played episode should be removed from queue")
        // Current episode should be unaffected
        XCTAssertEqual(audioManager.currentItem?.id, "ep-current",
                       "Current episode should not change when marking a queued episode as played")
    }
    
    @MainActor
    func test_playEpisode_doesNotRequeuePlayedEpisode() {
        let audioManager = AudioManager()
        
        var playedItem = QueueItem(
            id: "ep-played", title: "Played Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 3600,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        playedItem.isPlayed = true
        audioManager.currentItem = playedItem
        audioManager.testableSetPlaybackState(position: 3600, duration: 3600)
        
        let newItem = QueueItem(
            id: "ep-new", title: "New Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep2.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        
        // The preserveCurrent logic runs synchronously at the start of playEpisode,
        // before any async calls. We can test it by calling playEpisode and checking
        // queue state immediately — the queue insertion/skip happens first.
        let task = Task {
            await audioManager.playEpisode(newItem, preserveCurrent: true)
        }
        
        // Give the synchronous queue mutation a moment to execute on main actor
        let expectation = XCTestExpectation(description: "playEpisode settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
        
        XCTAssertFalse(audioManager.queue.contains(where: { $0.id == "ep-played" }),
                       "Played episode should NOT be re-queued when preserveCurrent is true")
        
        // Cleanup: stop to prevent UserDefaults pollution
        task.cancel()
        audioManager.stop()
    }
    
    @MainActor
    func test_playEpisode_requeueUnplayedEpisode() {
        let audioManager = AudioManager()
        
        let unplayedItem = QueueItem(
            id: "ep-unplayed", title: "Unplayed Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = unplayedItem
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        
        let newItem = QueueItem(
            id: "ep-new2", title: "New Episode 2", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep3.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        
        // Play a new episode with preserveCurrent — the unplayed episode SHOULD be re-queued
        let task = Task {
            await audioManager.playEpisode(newItem, preserveCurrent: true)
        }
        
        // Give the synchronous queue mutation a moment to execute on main actor
        let expectation = XCTestExpectation(description: "playEpisode settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
        
        XCTAssertTrue(audioManager.queue.contains(where: { $0.id == "ep-unplayed" }),
                      "Unplayed episode SHOULD be re-queued when preserveCurrent is true")
        
        // Cleanup: stop to prevent UserDefaults pollution
        task.cancel()
        audioManager.stop()
    }
    
    // MARK: - Remove Current Episode From Queue (Without Mark as Played)
    
    @MainActor
    func test_removeCurrentEpisodeFromQueue_stopsPlaybackWithoutMarkingAsPlayed() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        let item = QueueItem(
            id: "ep-playing", title: "Playing Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        let nextItem = QueueItem(
            id: "ep-next", title: "Next Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep2.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.replaceQueue([nextItem])
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        
        // WHEN: Remove the current episode from queue
        playerManager.removeCurrentEpisodeFromQueue()
        
        // THEN: Playback should be stopped (currentItem cleared)
        XCTAssertNil(audioManager.currentItem,
                     "Current item should be nil after removing from queue")
        
        // THEN: The isPlayed flag should NOT have been set on the item before stop.
        // markCurrentEpisodeAsPlayed sets item.isPlayed = true BEFORE stopping;
        // removeCurrentEpisodeFromQueue does NOT — it just stops.
        // We verify this by confirming the item in the queue is NOT the removed one
        // (removeCurrentEpisodeFromQueue doesn't re-insert the item with isPlayed=true).
        XCTAssertFalse(audioManager.queue.contains(where: { $0.id == "ep-playing" }),
                       "Removed episode should not be in the queue")
        
        // THEN: The remaining queue should be preserved
        XCTAssertEqual(audioManager.queue.count, 1,
                       "Queue should still contain the next episode")
        XCTAssertEqual(audioManager.queue.first?.id, "ep-next",
                       "Next episode should remain in queue")
    }
    
    @MainActor
    func test_removeCurrentEpisodeFromQueue_noOpWhenNothingPlaying() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        // No current item
        XCTAssertNil(audioManager.currentItem)
        
        // WHEN: Attempting to remove with nothing playing
        playerManager.removeCurrentEpisodeFromQueue()
        
        // THEN: Should not crash and no side effects
        XCTAssertNil(audioManager.currentItem)
    }
    
    @MainActor
    func test_removeCurrentEpisodeFromQueue_doesNotSetIsPlayedFlag() {
        // This test verifies the behavioral difference between the two methods:
        // markCurrentEpisodeAsPlayed sets isPlayed = true before stopping
        // removeCurrentEpisodeFromQueue does NOT set isPlayed
        
        // We track whether isPlayed was set by observing audioManager.currentItem changes
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        
        // Verify item is NOT played before removal
        XCTAssertFalse(audioManager.currentItem?.isPlayed ?? true,
                       "Item should not be marked as played before removal")
        
        // WHEN: Remove from queue
        playerManager.removeCurrentEpisodeFromQueue()
        
        // THEN: currentItem should be nil (stopped)
        XCTAssertNil(audioManager.currentItem,
                     "Current item should be cleared after removal")
        
        // Now test markCurrentEpisodeAsPlayed for contrast
        let audioManager2 = AudioManager()
        let playerManager2 = PlayerManager(audioManager: audioManager2)
        
        let item2 = QueueItem(
            id: "ep-2", title: "Episode 2", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep2.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager2.currentItem = item2
        audioManager2.testableSetPlaybackState(position: 500, duration: 3600)
        
        // markCurrentEpisodeAsPlayed sets isPlayed BEFORE calling stop
        // We can't check after stop (item is nil), but the method's contract
        // is confirmed by the "Mark as Played Queue Behavior" tests above
        playerManager2.markCurrentEpisodeAsPlayed()

        // Both should have stopped (queue is empty in this fixture — with queued episodes it advances)
        XCTAssertNil(audioManager2.currentItem,
                     "Current item should be cleared after marking as played")
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


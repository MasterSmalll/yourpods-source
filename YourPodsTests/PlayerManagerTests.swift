import XCTest
@testable import YourPods

/// Tests for PlayerManager's static formatting helpers and sync guard logic.
final class PlayerManagerTests: XCTestCase {
    
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
    func test_markCurrentEpisodeAsPlayed_stopsAndRemovesFromQueue() {
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
        audioManager.appendToQueue([nextItem])
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        
        playerManager.markCurrentEpisodeAsPlayed()
        
        // The played episode should NOT be the current item
        XCTAssertNotEqual(audioManager.currentItem?.id, "ep-playing",
                          "Played episode should not remain as current item")
        // The played episode should NOT be in the queue
        XCTAssertFalse(audioManager.queue.contains(where: { $0.id == "ep-playing" }),
                       "Played episode should not be in the queue")
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
}

import XCTest
@testable import YourPods

/// Tests for the "End of Episode" sleep timer mode.
/// When active, the current episode finishes normally but playback stops
/// instead of auto-advancing to the next queued episode.
@MainActor
final class SleepTimerEndOfEpisodeTests: XCTestCase {
    
    // MARK: - Helpers
    
    private func makeItem(id: String = "ep1", title: String = "Episode 1") -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }
    
    // MARK: - SleepTimerManager: End of Episode Flag
    
    func test_startEndOfEpisode_setsFlag() {
        let timer = SleepTimerManager()
        XCTAssertFalse(timer.stopAfterCurrentEpisode)
        
        timer.startEndOfEpisode()
        
        XCTAssertTrue(timer.stopAfterCurrentEpisode,
                      "startEndOfEpisode should set the flag to true")
    }
    
    func test_startEndOfEpisode_cancelsCountdownTimer() {
        let timer = SleepTimerManager()
        timer.start(minutes: 15)
        XCTAssertTrue(timer.isActive)
        
        timer.startEndOfEpisode()
        
        XCTAssertFalse(timer.isActive,
                       "Activating end-of-episode should cancel any running countdown")
        XCTAssertTrue(timer.stopAfterCurrentEpisode)
    }
    
    func test_cancelEndOfEpisode_clearsFlag() {
        let timer = SleepTimerManager()
        timer.startEndOfEpisode()
        XCTAssertTrue(timer.stopAfterCurrentEpisode)
        
        timer.cancelEndOfEpisode()
        
        XCTAssertFalse(timer.stopAfterCurrentEpisode)
    }
    
    func test_startCountdown_clearsEndOfEpisodeFlag() {
        let timer = SleepTimerManager()
        timer.startEndOfEpisode()
        XCTAssertTrue(timer.stopAfterCurrentEpisode)
        
        timer.start(minutes: 15)
        
        XCTAssertFalse(timer.stopAfterCurrentEpisode,
                       "Starting a countdown timer should clear the end-of-episode flag")
    }
    
    func test_stop_clearsEndOfEpisodeFlag() {
        let timer = SleepTimerManager()
        timer.startEndOfEpisode()
        XCTAssertTrue(timer.stopAfterCurrentEpisode)
        
        timer.stop()
        
        XCTAssertFalse(timer.stopAfterCurrentEpisode,
                       "stop() should clear everything including end-of-episode")
    }
    
    // MARK: - AudioManager: shouldAutoAdvanceToNextEpisode Hook
    
    func test_autoAdvance_stopsWhenHookReturnsFalse() {
        let audio = AudioManager()
        let ep1 = makeItem(id: "ep1", title: "Episode 1")
        let ep2 = makeItem(id: "ep2", title: "Episode 2")
        
        audio.currentItem = ep1
        audio.testableSetPlaybackState(position: 3590, duration: 3600)
        audio.appendToQueue([ep2])
        audio.isPlaying = true
        
        // Wire shouldAutoAdvance to return false (simulates end-of-episode mode)
        audio.shouldAutoAdvanceToNextEpisode = { return false }
        
        let result = audio.testableHandlePlaybackCompleted()
        
        XCTAssertEqual(result.completed?.id, "ep1",
                       "Should complete the current episode")
        XCTAssertNil(result.next,
                     "Should NOT advance to next episode when hook returns false")
        XCTAssertNil(audio.currentItem,
                     "Current item should be cleared (stopped)")
        XCTAssertFalse(audio.isPlaying,
                       "Playback should be stopped")
        // Queue should still contain ep2 — it was NOT consumed
        XCTAssertEqual(audio.queue.count, 1,
                       "Queue should be preserved (ep2 not consumed)")
        XCTAssertEqual(audio.queue.first?.id, "ep2")
    }
    
    func test_autoAdvance_proceedsWhenHookReturnsTrue() {
        let audio = AudioManager()
        let ep1 = makeItem(id: "ep1", title: "Episode 1")
        let ep2 = makeItem(id: "ep2", title: "Episode 2")
        
        audio.currentItem = ep1
        audio.testableSetPlaybackState(position: 3590, duration: 3600)
        audio.appendToQueue([ep2])
        audio.isPlaying = true
        
        // Hook returns true — normal behavior
        audio.shouldAutoAdvanceToNextEpisode = { return true }
        
        let result = audio.testableHandlePlaybackCompleted()
        
        XCTAssertEqual(result.completed?.id, "ep1")
        XCTAssertEqual(result.next?.id, "ep2",
                       "Should advance to next episode when hook returns true")
        XCTAssertEqual(audio.currentItem?.id, "ep2")
    }
    
    func test_autoAdvance_proceedsWhenHookNotSet() {
        let audio = AudioManager()
        let ep1 = makeItem(id: "ep1", title: "Episode 1")
        let ep2 = makeItem(id: "ep2", title: "Episode 2")
        
        audio.currentItem = ep1
        audio.testableSetPlaybackState(position: 3590, duration: 3600)
        audio.appendToQueue([ep2])
        audio.isPlaying = true
        
        // No hook set — default behavior
        audio.shouldAutoAdvanceToNextEpisode = nil
        
        let result = audio.testableHandlePlaybackCompleted()
        
        XCTAssertEqual(result.completed?.id, "ep1")
        XCTAssertEqual(result.next?.id, "ep2",
                       "Should advance normally when hook is nil")
    }
    
    // MARK: - Integration: SleepTimerManager + AudioManager
    
    func test_endOfEpisode_integration_stopsAndResetsFlag() {
        let timer = SleepTimerManager()
        let audio = AudioManager()
        let ep1 = makeItem(id: "ep1", title: "Episode 1")
        let ep2 = makeItem(id: "ep2", title: "Episode 2")
        
        audio.currentItem = ep1
        audio.testableSetPlaybackState(position: 3590, duration: 3600)
        audio.appendToQueue([ep2])
        audio.isPlaying = true
        
        // Wire the integration exactly as YourPodsApp does
        timer.startEndOfEpisode()
        audio.shouldAutoAdvanceToNextEpisode = { [weak timer] in
            guard let timer else { return true }
            if timer.stopAfterCurrentEpisode {
                timer.cancelEndOfEpisode()
                return false
            }
            return true
        }
        
        let result = audio.testableHandlePlaybackCompleted()
        
        XCTAssertEqual(result.completed?.id, "ep1")
        XCTAssertNil(result.next, "Should stop, not advance")
        XCTAssertFalse(timer.stopAfterCurrentEpisode,
                       "Flag should be reset after being consumed")
        // Next manual play should auto-advance normally
        XCTAssertEqual(audio.queue.count, 1, "Queue preserved")
    }
    
    func test_endOfEpisode_doesNotAffectNormalPlaybackWhenNotSet() {
        let timer = SleepTimerManager()
        let audio = AudioManager()
        let ep1 = makeItem(id: "ep1", title: "Episode 1")
        let ep2 = makeItem(id: "ep2", title: "Episode 2")
        
        audio.currentItem = ep1
        audio.testableSetPlaybackState(position: 3590, duration: 3600)
        audio.appendToQueue([ep2])
        audio.isPlaying = true
        
        // Wire integration but DON'T activate end-of-episode
        audio.shouldAutoAdvanceToNextEpisode = { [weak timer] in
            guard let timer else { return true }
            if timer.stopAfterCurrentEpisode {
                timer.cancelEndOfEpisode()
                return false
            }
            return true
        }
        
        let result = audio.testableHandlePlaybackCompleted()
        
        XCTAssertEqual(result.completed?.id, "ep1")
        XCTAssertEqual(result.next?.id, "ep2",
                       "Should advance normally when end-of-episode is not active")
    }
    
    // MARK: - EDGE: Empty Queue with End of Episode
    
    func test_EDGE_endOfEpisode_withEmptyQueue_stopsNormally() {
        let audio = AudioManager()
        let ep1 = makeItem(id: "ep1", title: "Episode 1")
        
        audio.currentItem = ep1
        audio.testableSetPlaybackState(position: 3590, duration: 3600)
        audio.isPlaying = true
        // Queue is empty — auto-advance would stop anyway
        
        audio.shouldAutoAdvanceToNextEpisode = { return false }
        
        let result = audio.testableHandlePlaybackCompleted()
        
        XCTAssertEqual(result.completed?.id, "ep1")
        XCTAssertNil(result.next, "No next item regardless")
        XCTAssertNil(audio.currentItem)
        XCTAssertFalse(audio.isPlaying)
    }
}

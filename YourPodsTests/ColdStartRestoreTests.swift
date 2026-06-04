import XCTest
@testable import YourPods

// MARK: - Cold-Start Restore Tests

@MainActor
final class ColdStartRestoreTests: XCTestCase {

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

    // MARK: - Cold-Start Position Restore

    func test_restoreQueue_restoresCurrentPosition() {
        // GIVEN: A saved position of 120.5 seconds
        let encoder = JSONEncoder()
        let currentItem = makeItem(id: "cold-ep", title: "Cold Start Episode")
        defaults.set(try! encoder.encode(currentItem), forKey: currentItemKey)
        defaults.set(120.5, forKey: positionKey)

        // WHEN: restoreQueue is called
        let manager = AudioManager()
        manager.restoreQueue()

        // THEN: currentPosition should be restored (not 0)
        XCTAssertEqual(manager.currentPosition, 120.5, accuracy: 0.1,
                       "currentPosition must be restored from UserDefaults on cold start")
    }

    func test_restoreQueue_restoresCurrentPosition_zero_whenNothingSaved() {
        // GIVEN: No saved position
        // WHEN: restoreQueue is called
        let manager = AudioManager()
        manager.restoreQueue()

        // THEN: currentPosition should remain 0
        XCTAssertEqual(manager.currentPosition, 0, accuracy: 0.1,
                       "currentPosition should be 0 when nothing is saved")
    }

    // MARK: - Spurious Completion Guard

    func test_spuriousCompletion_doesNotFireAt92Percent() {
        // GIVEN: An episode at 92% (552s / 600s) — 48 seconds remaining
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-92")
        manager.testableSetPlaybackState(position: 552, duration: 600)

        // WHEN: Testing spurious completion detection
        // THEN: Should be detected as spurious (> 10 seconds remaining)
        XCTAssertTrue(manager.testableIsSpuriousCompletion(),
                      "92% with 48s remaining should be detected as spurious")
    }

    func test_completion_firesAt99Percent() {
        // GIVEN: An episode at 99% (594s / 600s) — 6 seconds remaining
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-99")
        manager.testableSetPlaybackState(position: 594, duration: 600)

        // WHEN: Testing spurious completion detection
        // THEN: Should NOT be spurious (< 10 seconds remaining)
        XCTAssertFalse(manager.testableIsSpuriousCompletion(),
                       "99% with 6s remaining should be treated as genuine completion")
    }

    func test_completion_shortEpisode_notSpuriousAt90Percent() {
        // GIVEN: A short 30-second episode at 27s (90%) — only 3 seconds remaining
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-short")
        manager.testableSetPlaybackState(position: 27, duration: 30)

        // THEN: Should NOT be spurious (< 10 seconds remaining even though < 97%)
        XCTAssertFalse(manager.testableIsSpuriousCompletion(),
                       "Short episode with 3s remaining should complete normally")
    }
    
    // MARK: - Stale Position Refresh (Background Auto-Advance Fix)
    
    func test_completion_advancesWhenPositionRefreshedFromPlayer() {
        // GIVEN: An episode where the periodic time observer is stale (at 50%)
        // but AVPlayer's actual position is at 99% (near the end).
        // This simulates background mode where the time observer hasn't fired
        // recently but the episode has actually reached the end.
        let manager = AudioManager()
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }
        
        let ep1 = makeItem(id: "ep-bg-1")
        let ep2 = makeItem(id: "ep-bg-2")
        manager.currentItem = ep1
        manager.appendToQueue([ep2])
        
        // Set stale position: 300s out of 600s — the time observer hasn't updated
        manager.testableSetPlaybackState(position: 300, duration: 600)
        
        // Simulate AVPlayer's real position being at 598s (near end)
        manager.testableOverridePosition = 598.0
        
        // WHEN: handlePlaybackCompleted fires (AVPlayerItemDidPlayToEndTime)
        let result = manager.testableHandlePlaybackCompleted()
        
        // THEN: Should advance — the refreshed position (598s) is near the end
        XCTAssertEqual(result.completed?.id, "ep-bg-1",
                       "Should complete the episode after position refresh shows near-end")
        XCTAssertEqual(result.next?.id, "ep-bg-2",
                       "Should advance to next episode")
        XCTAssertEqual(completedIds, ["ep-bg-1"],
                       "onEpisodeCompleted should fire for the completed episode")
    }
    
    func test_completion_stillSpuriousWhenRefreshedPositionFarFromEnd() {
        // GIVEN: Both the stale position AND AVPlayer's actual position are far from the end.
        // This is a genuine spurious completion (stream error).
        let manager = AudioManager()
        let ep1 = makeItem(id: "ep-spurious")
        let ep2 = makeItem(id: "ep-next")
        manager.currentItem = ep1
        manager.appendToQueue([ep2])
        
        // Set stale position at 50%
        manager.testableSetPlaybackState(position: 300, duration: 600)
        
        // AVPlayer also shows position far from end (stream error at 310s)
        manager.testableOverridePosition = 310.0
        
        // WHEN: handlePlaybackCompleted fires
        let result = manager.testableHandlePlaybackCompleted()
        
        // THEN: Should still be treated as spurious — both positions are far from end
        XCTAssertNil(result.completed, "Should NOT advance on genuine spurious completion")
        XCTAssertNil(result.next, "Should NOT advance when player position confirms far from end")
        XCTAssertEqual(manager.queue.count, 1, "Queue should be unchanged")
    }
}

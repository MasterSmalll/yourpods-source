import XCTest
@testable import YourPods

/// Tests for the mini player progress bar calculation.
/// Bug: progress bar doesn't calculate correctly — no clamping, edge cases uncovered.
final class MiniPlayerProgressTests: XCTestCase {
    
    // MARK: - playbackProgress: Normal Cases
    
    func test_playbackProgress_normalMidpoint() {
        // 50% through an episode
        let progress = PlayerManager.playbackProgress(position: 300, duration: 600)
        XCTAssertEqual(progress, 0.5, accuracy: 0.001,
                       "300/600 should be 0.5")
    }
    
    func test_playbackProgress_oneThird() {
        let progress = PlayerManager.playbackProgress(position: 1312, duration: 3712)
        let expected = 1312.0 / 3712.0
        XCTAssertEqual(progress, expected, accuracy: 0.001,
                       "1312/3712 should be ~0.353")
    }
    
    func test_playbackProgress_atStart() {
        let progress = PlayerManager.playbackProgress(position: 0, duration: 3600)
        XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                       "Position 0 should be 0% progress")
    }
    
    func test_playbackProgress_atEnd() {
        let progress = PlayerManager.playbackProgress(position: 3600, duration: 3600)
        XCTAssertEqual(progress, 1.0, accuracy: 0.001,
                       "Position == duration should be 100% progress")
    }
    
    // MARK: - playbackProgress: Edge Cases
    
    func test_playbackProgress_zeroDuration() {
        // Duration is 0 (not yet loaded or invalid) — progress should be 0
        let progress = PlayerManager.playbackProgress(position: 1312, duration: 0)
        XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                       "Zero duration should always return 0 progress")
    }
    
    func test_playbackProgress_negativeDuration() {
        // Invalid negative duration — progress should be 0
        let progress = PlayerManager.playbackProgress(position: 300, duration: -100)
        XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                       "Negative duration should return 0 progress")
    }
    
    func test_EDGE_playbackProgress_positionExceedsDuration() {
        // Position > duration (AVPlayer quirk during seeks) — should clamp to 1.0
        let progress = PlayerManager.playbackProgress(position: 3700, duration: 3600)
        XCTAssertEqual(progress, 1.0, accuracy: 0.001,
                       "Position beyond duration should clamp to 1.0, not overflow")
    }
    
    func test_EDGE_playbackProgress_negativePosition() {
        // Negative position — should clamp to 0.0
        let progress = PlayerManager.playbackProgress(position: -5, duration: 3600)
        XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                       "Negative position should clamp to 0.0")
    }
    
    func test_EDGE_playbackProgress_bothZero() {
        let progress = PlayerManager.playbackProgress(position: 0, duration: 0)
        XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                       "Both zero should return 0 progress")
    }
    
    func test_EDGE_playbackProgress_verySmallDuration() {
        // Duration very small, position larger — should clamp to 1.0
        let progress = PlayerManager.playbackProgress(position: 1312, duration: 0.001)
        XCTAssertEqual(progress, 1.0, accuracy: 0.001,
                       "Very small duration with larger position should clamp to 1.0")
    }
    
    func test_EDGE_playbackProgress_nanSafe() {
        // Ensure result is never NaN
        let progress = PlayerManager.playbackProgress(position: 0, duration: 0)
        XCTAssertFalse(progress.isNaN, "Progress must never be NaN")
    }
    
    // MARK: - Scenario: Restore + Play cycle
    
    @MainActor
    func test_Scenario_progressConsistencyAfterRestore() {
        // Simulates the mini player reading progress from AudioManager state
        // GIVEN: an episode at position 1312s with AVPlayer duration 3712s
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.testableSetPlaybackState(position: 1312, duration: 3712)
        
        // WHEN: calculating progress for the mini player bar
        let progress = PlayerManager.playbackProgress(
            position: playerManager.currentPosition,
            duration: playerManager.currentDuration
        )
        
        // THEN: progress should be ~35%, NOT 4% or 95%+
        XCTAssertEqual(progress, 1312.0 / 3712.0, accuracy: 0.001,
                       "Progress should match position/duration exactly")
        XCTAssertGreaterThan(progress, 0.3, "Should be more than 30%")
        XCTAssertLessThan(progress, 0.4, "Should be less than 40%")
    }
    
    @MainActor
    func test_Scenario_progressDuringDurationLoading() {
        // GIVEN: position is set but duration is still 0 (AVPlayer loading)
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.testableSetPlaybackState(position: 1312, duration: 0)
        
        // WHEN: calculating progress
        let progress = PlayerManager.playbackProgress(
            position: playerManager.currentPosition,
            duration: playerManager.currentDuration
        )
        
        // THEN: should be 0 (not infinity or NaN)
        XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                       "Progress should be 0 when duration hasn't loaded")
    }
    
    @MainActor
    func test_Scenario_progressWithRSSDurationMismatch() {
        // GIVEN: RSS says duration is 32800s (bad metadata), but AVPlayer says 3712s
        // After AVPlayer loads, duration should be the AVPlayer value
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        // Simulate restore with RSS duration
        audioManager.testableSetPlaybackState(position: 1312, duration: 32800)
        let progressWithRSS = PlayerManager.playbackProgress(
            position: playerManager.currentPosition,
            duration: playerManager.currentDuration
        )
        
        // Then AVPlayer updates duration to real value
        audioManager.testableSetPlaybackState(position: 1312, duration: 3712)
        let progressWithAVPlayer = PlayerManager.playbackProgress(
            position: playerManager.currentPosition,
            duration: playerManager.currentDuration
        )
        
        // The AVPlayer progress should be higher since the real duration is shorter
        XCTAssertGreaterThan(progressWithAVPlayer, progressWithRSS,
                             "Real AVPlayer duration should yield higher progress than inflated RSS duration")
        XCTAssertEqual(progressWithRSS, 1312.0 / 32800.0, accuracy: 0.001)
        XCTAssertEqual(progressWithAVPlayer, 1312.0 / 3712.0, accuracy: 0.001)
    }
}

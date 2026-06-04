import XCTest
@testable import YourPods

@MainActor
final class PositionResumeTests: XCTestCase {
    
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
    
    private func makeItem(id: String, positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: id,
            title: "Episode \(id)",
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }
    
    /// When initialPosition is nil and positionSeconds > 0,
    /// the player should resume from positionSeconds (the queue item's tracked position).
    func test_positionResume_fallsBackToPositionSeconds_whenInitialPositionIsNil() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1", positionSeconds: 300)
        
        // WHEN: playEpisode is called without explicit initialPosition
        let target = manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        // THEN: Should seek to positionSeconds (300), not stay at 0
        XCTAssertEqual(target, 300, "Should fall back to item.positionSeconds when initialPosition is nil")
        XCTAssertEqual(manager.currentPosition, 300, "currentPosition should reflect the resumed position")
    }
    
    /// When initialPosition IS provided, it should take precedence over positionSeconds.
    func test_positionResume_prefersInitialPosition_overPositionSeconds() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1", positionSeconds: 300)
        
        // WHEN: playEpisode is called with explicit initialPosition=600
        let target = manager.testablePlayEpisodePositionResume(item, initialPosition: 600)
        
        // THEN: Should use initialPosition (600), not positionSeconds (300)
        XCTAssertEqual(target, 600, "Explicit initialPosition should override positionSeconds")
        XCTAssertEqual(manager.currentPosition, 600)
    }
    
    /// When both initialPosition is nil AND positionSeconds is 0,
    /// position should stay at 0 (fresh episode).
    func test_positionResume_staysAtZero_whenBothAreZero() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1", positionSeconds: 0)
        
        let target = manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        XCTAssertEqual(target, 0, "Fresh episode should start at 0")
        XCTAssertEqual(manager.currentPosition, 0)
    }
    
    /// When positionSeconds > 0 but skipIntro is larger, skipIntro should win.
    func test_positionResume_skipIntroOverridesPositionSeconds_whenPositionIsBelowIntro() {
        let manager = AudioManager()
        var item = makeItem(id: "ep-1", positionSeconds: 10)
        item.skipIntroSeconds = 30
        
        manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        // positionSeconds=10, but skipIntro=30 — should jump to 30
        XCTAssertEqual(manager.currentPosition, 30,
                       "skipIntro should override when positionSeconds is below the intro threshold")
    }
    
    /// When positionSeconds is beyond skipIntro, skipIntro should NOT apply.
    func test_positionResume_skipIntroDoesNotApply_whenPositionIsBeyondIntro() {
        let manager = AudioManager()
        var item = makeItem(id: "ep-1", positionSeconds: 120)
        item.skipIntroSeconds = 30
        
        manager.testablePlayEpisodePositionResume(item, initialPosition: nil)
        
        // positionSeconds=120 > skipIntro=30 — should stay at 120
        XCTAssertEqual(manager.currentPosition, 120,
                       "When position is beyond skipIntro threshold, position should be preserved")
    }
}

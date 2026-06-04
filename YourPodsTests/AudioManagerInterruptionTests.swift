import XCTest
@testable import YourPods

// MARK: - Audio Session Interruption Tests

@MainActor
final class AudioManagerInterruptionTests: XCTestCase {

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

    func test_interruptionBegan_setsWasPlayingFlag() {
        // GIVEN: An AudioManager that is "playing" (isPlaying = true)
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        // Simulate the isPlaying state without AVPlayer
        manager.isPlaying = true

        // WHEN: An interruption begins
        manager.testableHandleInterruption(began: true)

        // THEN: wasPlayingBeforeInterruption should be true
        XCTAssertTrue(manager.wasPlayingBeforeInterruption,
                      "Should record that playback was active before interruption")
        XCTAssertFalse(manager.isPlaying,
                       "Playback should be paused during interruption")
    }

    func test_interruptionBegan_doesNotSetFlagWhenPaused() {
        // GIVEN: An AudioManager that is paused
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = false

        // WHEN: An interruption begins while already paused
        manager.testableHandleInterruption(began: true)

        // THEN: wasPlayingBeforeInterruption should be false
        XCTAssertFalse(manager.wasPlayingBeforeInterruption,
                       "Should record that playback was NOT active before interruption")
    }

    func test_interruptionEnded_withShouldResume_whenWasPlaying() {
        // GIVEN: An AudioManager that was playing before an interruption
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true
        manager.testableHandleInterruption(began: true)

        // WHEN: The interruption ends with shouldResume = true
        let willResume = manager.testableHandleInterruption(began: false, shouldResume: true)

        // THEN: Should indicate it will resume
        XCTAssertTrue(willResume,
                      "Should resume playback when system says shouldResume and we were playing")
        // Flag should be reset
        XCTAssertFalse(manager.wasPlayingBeforeInterruption,
                       "Flag should be reset after interruption ends")
    }

    func test_interruptionEnded_withShouldResume_whenWasPaused() {
        // GIVEN: An AudioManager that was paused before an interruption
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = false
        manager.testableHandleInterruption(began: true)

        // WHEN: The interruption ends with shouldResume = true
        let willResume = manager.testableHandleInterruption(began: false, shouldResume: true)

        // THEN: Should NOT resume (we weren't playing)
        XCTAssertFalse(willResume,
                       "Should NOT resume if we weren't playing before the interruption")
    }

    func test_interruptionEnded_withoutShouldResume_whenWasPlaying() {
        // GIVEN: An AudioManager that was playing before an interruption
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true
        manager.testableHandleInterruption(began: true)

        // WHEN: The interruption ends WITHOUT shouldResume
        let willResume = manager.testableHandleInterruption(began: false, shouldResume: false)

        // THEN: Should NOT resume (system didn't say to)
        XCTAssertFalse(willResume,
                       "Should NOT resume when system does not indicate shouldResume")
    }
}

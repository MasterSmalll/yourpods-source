import XCTest
@testable import YourPods

// MARK: - Force Sync Progress Tests

final class ForceSyncProgressTests: XCTestCase {

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

    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: id,
            title: "Episode",
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    @MainActor
    func test_forceSyncProgress_updatesQueueItemPosition() {
        // GIVEN: A PlayerManager with an audio manager at position 500
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1")
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)

        // WHEN: forceSyncProgress is called
        playerManager.forceSyncProgress()

        // THEN: The currentItem's positionSeconds is updated
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 500,
                       "forceSyncProgress must update currentItem.positionSeconds immediately")
    }

    /// AudioManager is now @MainActor — background-thread construction is a compile-time error.
    /// This test verifies main-actor init succeeds and the manager is functional.
    @MainActor
    func test_audioManagerInitOnMainActor_succeeds() {
        let manager = AudioManager()
        XCTAssertNil(manager.currentItem, "Fresh AudioManager should have no current item")
        XCTAssertTrue(manager.queue.isEmpty, "Fresh AudioManager should have empty queue")
    }
}

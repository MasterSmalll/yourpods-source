import XCTest
@testable import YourPods

// MARK: - Position Persistence Tests

@MainActor
final class PositionPersistenceTests: XCTestCase {

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

    private func makeItem(id: String, title: String = "Episode", positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    func test_persistQueue_updatesCurrentItemPositionSeconds() {
        // GIVEN: An AudioManager with a currentItem at positionSeconds=0
        // but currentPosition advanced to 500
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1", positionSeconds: 0)
        manager.testableSetPlaybackState(position: 500, duration: 3600)

        // WHEN: Triggering persist by mutating the queue
        manager.appendToQueue([makeItem(id: "ep-2")])

        // THEN: The saved currentItem should have positionSeconds=500
        let savedData = defaults.data(forKey: currentItemKey)
        let savedItem = savedData.flatMap { try? JSONDecoder().decode(QueueItem.self, from: $0) }
        XCTAssertEqual(savedItem?.positionSeconds, 500,
                       "persistQueue must update currentItem.positionSeconds from currentPosition before encoding")
    }

    func test_persistQueueToDisk_savesLatestPosition() {
        // GIVEN: An AudioManager with currentPosition at 750
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.testableSetPlaybackState(position: 750, duration: 3600)

        // WHEN: persistQueueToDisk is called
        manager.persistQueueToDisk()

        // THEN: savedCurrentPosition should be 750 (or close)
        let savedPos = defaults.double(forKey: positionKey)
        XCTAssertEqual(savedPos, 750, accuracy: 1.0,
                       "persistQueueToDisk must save the latest position")
    }
}

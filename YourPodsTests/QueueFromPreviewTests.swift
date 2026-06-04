import XCTest
@testable import YourPods

// MARK: - Queue from Preview (Search) Tests

/// Tests for adding individual episodes to the queue from podcast search preview,
/// without requiring a subscription or persisted Episode model.
@MainActor
final class QueueFromPreviewTests: XCTestCase {
    
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
    
    // MARK: - QueueItem from preview data
    
    func test_queueItem_from_preview_data() {
        // GIVEN: Preview episode data from a podcast search result (no persisted Episode)
        let item = QueueItem(
            id: "preview-ep-1",
            title: "Episode from Search",
            podcastTitle: "Search Result Podcast",
            audioUrl: "https://cdn.example.com/ep1.mp3",
            artworkUrl: "https://cdn.example.com/art.jpg",
            durationSeconds: nil,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed.xml",
            pubDate: Date()
        )
        
        // THEN: QueueItem has all expected fields populated
        XCTAssertEqual(item.id, "preview-ep-1")
        XCTAssertEqual(item.title, "Episode from Search")
        XCTAssertEqual(item.podcastTitle, "Search Result Podcast")
        XCTAssertEqual(item.audioUrl, "https://cdn.example.com/ep1.mp3")
        XCTAssertEqual(item.artworkUrl, "https://cdn.example.com/art.jpg")
        XCTAssertEqual(item.podcastUrl, "https://example.com/feed.xml")
        XCTAssertEqual(item.positionSeconds, 0)
        XCTAssertNotNil(item.pubDate)
    }
    
    func test_appendToQueue_preview_episode() {
        // GIVEN: An AudioManager with one existing queue item
        let manager = AudioManager()
        let existingItem = QueueItem(
            id: "existing-ep",
            title: "Already Queued",
            podcastTitle: "Some Podcast",
            audioUrl: "https://cdn.example.com/existing.mp3",
            artworkUrl: nil,
            durationSeconds: 1800,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed.xml",
            pubDate: nil
        )
        manager.appendToQueue([existingItem])
        XCTAssertEqual(manager.queue.count, 1, "Precondition: queue has 1 item")
        
        // WHEN: A preview episode is appended to the queue
        let previewItem = QueueItem(
            id: "preview-ep-1",
            title: "Episode from Search",
            podcastTitle: "Search Result Podcast",
            audioUrl: "https://cdn.example.com/ep1.mp3",
            artworkUrl: "https://cdn.example.com/art.jpg",
            durationSeconds: nil,
            positionSeconds: 0,
            podcastUrl: "https://example.com/search-feed.xml",
            pubDate: Date()
        )
        manager.appendToQueue([previewItem])
        
        // THEN: Queue has both items, preview at the end
        XCTAssertEqual(manager.queue.count, 2)
        XCTAssertEqual(manager.queue[0].id, "existing-ep",
                       "Existing item should remain at position 0")
        XCTAssertEqual(manager.queue[1].id, "preview-ep-1",
                       "Preview item should be appended at the end")
    }
    
    func test_insertNext_preview_episode() {
        // GIVEN: An AudioManager with one existing queue item
        let manager = AudioManager()
        let existingItem = QueueItem(
            id: "existing-ep",
            title: "Already Queued",
            podcastTitle: "Some Podcast",
            audioUrl: "https://cdn.example.com/existing.mp3",
            artworkUrl: nil,
            durationSeconds: 1800,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed.xml",
            pubDate: nil
        )
        manager.appendToQueue([existingItem])
        XCTAssertEqual(manager.queue.count, 1, "Precondition: queue has 1 item")
        
        // WHEN: A preview episode is inserted as "Play Next"
        let previewItem = QueueItem(
            id: "preview-ep-1",
            title: "Episode from Search",
            podcastTitle: "Search Result Podcast",
            audioUrl: "https://cdn.example.com/ep1.mp3",
            artworkUrl: "https://cdn.example.com/art.jpg",
            durationSeconds: nil,
            positionSeconds: 0,
            podcastUrl: "https://example.com/search-feed.xml",
            pubDate: Date()
        )
        manager.insertNext([previewItem])
        
        // THEN: Queue has both items, preview at position 0 (Play Next)
        XCTAssertEqual(manager.queue.count, 2)
        XCTAssertEqual(manager.queue[0].id, "preview-ep-1",
                       "Preview item should be inserted at position 0 (Play Next)")
        XCTAssertEqual(manager.queue[1].id, "existing-ep",
                       "Existing item should be pushed to position 1")
    }
}

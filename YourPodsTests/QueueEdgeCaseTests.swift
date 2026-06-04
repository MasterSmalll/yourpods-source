import XCTest
@testable import YourPods

@MainActor
final class QueueEdgeCaseTests: XCTestCase {
    
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
            id: id, title: "Episode \(id)", podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
    }
    
    // MARK: - appendToQueue
    
    func test_appendToQueue_emptyArray_noOp() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "existing")])
        let countBefore = manager.queue.count
        
        manager.appendToQueue([])
        
        XCTAssertEqual(manager.queue.count, countBefore,
                       "Appending empty array should not change the queue")
    }
    
    func test_appendToQueue_deduplicates() {
        let manager = AudioManager()
        let item = makeItem(id: "ep-1")
        manager.appendToQueue([item])
        
        manager.appendToQueue([item]) // Add same item again
        
        XCTAssertEqual(manager.queue.count, 1,
                       "Duplicate items should not be added to the queue")
    }
    
    func test_appendToQueue_deduplicatesAgainstCurrentItem() {
        let manager = AudioManager()
        let item = makeItem(id: "current-ep")
        manager.currentItem = item
        
        manager.appendToQueue([item])
        
        XCTAssertEqual(manager.queue.count, 0,
                       "Should not add the currently playing item to the queue")
    }
    
    // MARK: - removeFromQueue
    
    func test_removeFromQueue_nonExistent_noOp() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "ep-1")])
        let countBefore = manager.queue.count
        
        manager.removeFromQueue(makeItem(id: "unknown"))
        
        XCTAssertEqual(manager.queue.count, countBefore,
                       "Removing a non-existent item should be safe and change nothing")
    }
    
    func test_removeFromQueue_emptyQueue_noOp() {
        let manager = AudioManager()
        XCTAssertTrue(manager.queue.isEmpty)
        
        manager.removeFromQueue(makeItem(id: "whatever"))
        
        XCTAssertTrue(manager.queue.isEmpty,
                      "Removing from empty queue should not crash")
    }
    
    // MARK: - insertNext
    
    func test_insertNext_emptyArray_noOp() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "ep-1")])
        let countBefore = manager.queue.count
        
        manager.insertNext([])
        
        XCTAssertEqual(manager.queue.count, countBefore)
    }
    
    // MARK: - moveQueueItems
    
    func test_moveQueueItems_singleItem() {
        let manager = AudioManager()
        manager.appendToQueue([makeItem(id: "only")])
        
        manager.moveQueueItems(from: IndexSet(integer: 0), to: 0)
        
        XCTAssertEqual(manager.queue.count, 1)
        XCTAssertEqual(manager.queue[0].id, "only")
    }
    
    // MARK: - Stress test
    
    func test_queue_largeAppend_preservesOrdering() {
        let manager = AudioManager()
        let items = (1...100).map { makeItem(id: "ep-\($0)") }
        manager.appendToQueue(items)
        
        XCTAssertEqual(manager.queue.count, 100)
        for i in 0..<100 {
            XCTAssertEqual(manager.queue[i].id, "ep-\(i + 1)",
                           "Item at index \(i) should be ep-\(i + 1)")
        }
    }
    
    // MARK: - Fresh AudioManager defaults
    
    func test_freshManager_currentItemIsNil() {
        let manager = AudioManager()
        XCTAssertNil(manager.currentItem)
    }
    
    func test_freshManager_queueIsEmpty() {
        let manager = AudioManager()
        XCTAssertTrue(manager.queue.isEmpty)
    }
    
    func test_freshManager_positionAndDurationAreZero() {
        let manager = AudioManager()
        XCTAssertEqual(manager.currentPosition, 0)
        XCTAssertEqual(manager.currentDuration, 0)
    }
    
    func test_freshManager_isNotPlaying() {
        let manager = AudioManager()
        XCTAssertFalse(manager.isPlaying)
    }
    
    func test_freshManager_isAdvancingQueueIsFalse() {
        let manager = AudioManager()
        XCTAssertFalse(manager.isAdvancingQueue)
    }
}

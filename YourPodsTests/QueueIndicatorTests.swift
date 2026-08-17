import XCTest
@testable import YourPods

/// Tests for `PlayerManager.queuedEpisodeGuids` — the computed set of episode GUIDs
/// currently in the Up Next queue (including the now-playing item).
final class QueueIndicatorTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Clear persisted queue + current item to prevent restoreQueue() from loading stale data
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
    }
    
    // MARK: - Helpers
    
    private func makeItem(id: String, title: String = "Episode") -> QueueItem {
        QueueItem(
            id: id, title: title, podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(id).mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
    }
    
    // MARK: - queuedEpisodeGuids
    
    @MainActor
    func test_queuedEpisodeGuids_emptyWhenNoItems() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        XCTAssertTrue(playerManager.queuedEpisodeGuids.isEmpty,
                      "Should be empty when nothing is playing and queue is empty")
    }
    
    @MainActor
    func test_queuedEpisodeGuids_containsCurrentItem() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        audioManager.currentItem = makeItem(id: "ep-current")
        
        XCTAssertTrue(playerManager.queuedEpisodeGuids.contains("ep-current"),
                      "Should contain the currently playing episode GUID")
        XCTAssertEqual(playerManager.queuedEpisodeGuids.count, 1)
    }
    
    @MainActor
    func test_queuedEpisodeGuids_containsQueuedItems() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        audioManager.appendToQueue([
            makeItem(id: "ep-1"),
            makeItem(id: "ep-2"),
            makeItem(id: "ep-3")
        ])
        
        XCTAssertEqual(playerManager.queuedEpisodeGuids, Set(["ep-1", "ep-2", "ep-3"]),
                       "Should contain all queued episode GUIDs")
    }
    
    @MainActor
    func test_queuedEpisodeGuids_containsCurrentAndQueued() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        audioManager.currentItem = makeItem(id: "ep-playing")
        audioManager.appendToQueue([
            makeItem(id: "ep-next-1"),
            makeItem(id: "ep-next-2")
        ])
        
        XCTAssertEqual(playerManager.queuedEpisodeGuids,
                       Set(["ep-playing", "ep-next-1", "ep-next-2"]),
                       "Should contain both current item and all queued items")
    }
    
    @MainActor
    func test_queuedEpisodeGuids_excludesRemovedItems() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        let itemToRemove = makeItem(id: "ep-remove")
        audioManager.appendToQueue([
            makeItem(id: "ep-keep"),
            itemToRemove
        ])
        
        // Verify it's there first
        XCTAssertTrue(playerManager.queuedEpisodeGuids.contains("ep-remove"))
        
        // Remove it
        audioManager.removeFromQueue(itemToRemove)
        
        XCTAssertFalse(playerManager.queuedEpisodeGuids.contains("ep-remove"),
                       "Should not contain removed episode GUID")
        XCTAssertTrue(playerManager.queuedEpisodeGuids.contains("ep-keep"),
                      "Should still contain remaining episode GUID")
    }
}

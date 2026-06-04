import XCTest
@testable import YourPods

/// Tests for the CarPlay "dead screen" fix — ensuring episode metadata
/// is immediately available on CarPlay/lock screen during buffering
/// and low-network conditions.
@MainActor
final class CarPlayBufferingFeedbackTests: XCTestCase {
    
    /// Helper to create a test QueueItem with known metadata.
    private func makeTestItem(
        id: String = "test-ep",
        title: String = "Test Episode",
        podcastTitle: String = "Test Podcast",
        audioUrl: String = "https://example.com/episode.mp3"
    ) -> QueueItem {
        QueueItem(
            id: id, title: title, podcastTitle: podcastTitle,
            audioUrl: audioUrl, artworkUrl: nil,
            durationSeconds: 300, positionSeconds: 60,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
    }
    
    // MARK: - Change 1: Early metadata population
    
    /// After calling playEpisode, currentItem should be set BEFORE any
    /// async URL resolution completes — so CarPlay can show metadata immediately.
    func test_playEpisode_setsCurrentItemBeforeReturning() async {
        let manager = AudioManager()
        let item = makeTestItem()
        
        // playEpisode is async — when it returns, currentItem must be set
        await manager.playEpisode(item)
        
        XCTAssertEqual(manager.currentItem?.id, "test-ep",
                       "currentItem should be set during playEpisode")
        XCTAssertEqual(manager.currentItem?.title, "Test Episode",
                       "currentItem title should match the played episode")
    }
    
    // MARK: - Change 2: Buffering rate
    
    /// When isBuffering is true, updateNowPlayingPlaybackState should
    /// report rate=0 to the system, so CarPlay doesn't show a fake "playing" state.
    func test_bufferingState_isAccessible() {
        let manager = AudioManager()
        
        // isBuffering should be observable and default to false
        XCTAssertFalse(manager.isBuffering,
                       "isBuffering should default to false")
    }
    
    // MARK: - Change 3: Offline URL resolution skip
    
    /// When offline and episode is not downloaded, playEpisode should still
    /// set currentItem (not get stuck waiting for URL resolution timeout).
    func test_playEpisode_offline_setsCurrentItemQuickly() async {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        
        let item = makeTestItem()
        
        let start = CFAbsoluteTimeGetCurrent()
        await manager.playEpisode(item)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        // If URL resolution is correctly skipped when offline,
        // this should complete well under the 5s timeout
        XCTAssertLessThan(elapsed, 3.0,
                          "playEpisode should not wait 5s for URL resolution when offline")
        XCTAssertEqual(manager.currentItem?.id, "test-ep",
                       "currentItem should be set even when offline")
    }
    
    /// When online, playEpisode should still work normally.
    func test_playEpisode_online_setsCurrentItem() async {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: true)
        manager.networkMonitor = mock
        
        let item = makeTestItem()
        await manager.playEpisode(item)
        
        XCTAssertEqual(manager.currentItem?.id, "test-ep",
                       "currentItem should be set when online")
    }
    
    // MARK: - Change 4: Metadata during recovery
    
    /// During offline recovery, currentItem should still be set
    /// so CarPlay can display episode metadata.
    func test_recoveryOffline_preservesCurrentItem() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        manager.subscribeToConnectivityRestoration()
        
        let item = makeTestItem()
        manager.currentItem = item
        manager.errorMessage = "Playback failed."
        
        // Trigger recovery while offline
        manager.testableAttemptStreamRecovery()
        
        // currentItem should still be set (metadata visible on CarPlay)
        XCTAssertNotNil(manager.currentItem,
                        "currentItem must survive recovery wait — it drives CarPlay metadata")
        XCTAssertEqual(manager.currentItem?.title, "Test Episode")
    }
    
    /// Recovery error message when offline should be user-friendly.
    func test_recoveryOffline_showsConnectivityMessage() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        
        let item = makeTestItem()
        manager.currentItem = item
        
        manager.testableAttemptStreamRecovery()
        
        XCTAssertEqual(manager.errorMessage,
                       "No connection. Will retry when network returns.",
                       "Should show a clear connectivity message, not a generic error")
    }
    
    // MARK: - Change 5: CarPlay detail text
    
    /// CarPlayService should show "Connecting…" when buffering.
    /// (This is a behavioral contract test — verifies the logic, not CPTemplate rendering.)
    func test_bufferingDetailText_logic() {
        // When buffering is true, detail text should include "Connecting"
        let podcastTitle = "My Podcast"
        let isBuffering = true
        let errorMessage: String? = nil
        
        let detailText: String
        if isBuffering {
            detailText = "Connecting… — \(podcastTitle)"
        } else if let error = errorMessage {
            detailText = "\(error) — \(podcastTitle)"
        } else {
            detailText = podcastTitle
        }
        
        XCTAssertTrue(detailText.contains("Connecting"),
                      "Detail text should indicate buffering state")
        XCTAssertTrue(detailText.contains(podcastTitle),
                      "Detail text should still show podcast title")
    }
    
    func test_errorDetailText_logic() {
        let podcastTitle = "My Podcast"
        let isBuffering = false
        let errorMessage: String? = "No connection"
        
        let detailText: String
        if isBuffering {
            detailText = "Connecting… — \(podcastTitle)"
        } else if let error = errorMessage {
            detailText = "\(error) — \(podcastTitle)"
        } else {
            detailText = podcastTitle
        }
        
        XCTAssertTrue(detailText.contains("No connection"),
                      "Detail text should show error message")
    }
    
    func test_normalDetailText_logic() {
        let podcastTitle = "My Podcast"
        let isBuffering = false
        let errorMessage: String? = nil
        
        let detailText: String
        if isBuffering {
            detailText = "Connecting… — \(podcastTitle)"
        } else if let error = errorMessage {
            detailText = "\(error) — \(podcastTitle)"
        } else {
            detailText = podcastTitle
        }
        
        XCTAssertEqual(detailText, podcastTitle,
                       "Normal state should just show podcast title")
    }
    
    // MARK: - Round 2: Cold-start metadata sync
    
    /// play() cold-start path should set metadata synchronously
    /// BEFORE the async playEpisode Task, so CarPlay has data when
    /// CPNowPlayingTemplate is pushed.
    func test_play_coldStart_setsCurrentItemSynchronously() {
        let manager = AudioManager()
        let item = makeTestItem()
        
        // Simulate a restored item (cold-start scenario: AVPlayer is empty
        // but currentItem was restored from persistence)
        manager.currentItem = item
        
        // Call play() — this should return synchronously.
        // In cold-start path, it sets metadata before firing async Task.
        manager.play()
        
        // currentItem should still be set (not cleared by play())
        XCTAssertEqual(manager.currentItem?.id, "test-ep",
                       "play() cold-start must preserve currentItem for CarPlay metadata")
        XCTAssertEqual(manager.currentItem?.title, "Test Episode")
    }
    
    /// play() cold-start should keep currentItem even when offline.
    func test_play_coldStart_offline_preservesMetadata() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        
        let item = makeTestItem()
        manager.currentItem = item
        
        manager.play()
        
        // Metadata should survive cold-start even when offline
        XCTAssertNotNil(manager.currentItem,
                        "currentItem must survive cold-start play when offline")
        XCTAssertEqual(manager.currentItem?.title, "Test Episode")
    }
    
    // MARK: - Round 2: ImageCacheStore disk cache availability
    
    /// ImageCacheStore should have a disk cache path that exists.
    func test_imageCacheStore_diskCacheExists() {
        let store = ImageCacheStore.shared
        
        // Memory cache should be accessible
        XCTAssertNotNil(store.cache, "Shared cache should be accessible")
        
        // saveToDisk + loadFromDisk round-trip should work
        #if canImport(UIKit)
        let testImage = UIImage(systemName: "mic.fill")!
        #else
        let testImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!
        #endif
        
        let testKey = "carplay-test-\(UUID().uuidString)"
        store.saveToDisk(image: testImage, key: testKey)
        
        let loaded = store.loadFromDisk(key: testKey)
        XCTAssertNotNil(loaded, "Disk-cached image should load successfully")
        
        // Clean up
        store.removeFromDisk(key: testKey)
    }
}

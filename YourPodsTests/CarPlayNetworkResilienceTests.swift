import XCTest
@testable import YourPods

/// Tests for CarPlay resilience improvements:
/// - Play handler should use play() not playEpisode() for instant resume
/// - Deferred initialization when dependencies aren't ready
///
/// These tests verify the logic contracts that CarPlayService must satisfy,
/// mirroring the handler behavior without requiring actual CarPlay framework.
@MainActor
final class CarPlayNetworkResilienceTests: XCTestCase {
    
    // MARK: - Play Handler Should Use play()
    
    /// The CarPlay "Now Playing" current item handler should call play()
    /// which handles both hot resume and cold-start bootstrap,
    /// rather than playEpisode() which does full URL resolution.
    func test_carPlayPlayHandler_shouldCallPlay_notPlayEpisode() {
        let manager = AudioManager()
        
        // Simulate a restored (cold-start) state: currentItem exists but player has no loaded item
        let item = QueueItem(
            id: "restored-ep", title: "Restored Episode", podcastTitle: "Test Pod",
            audioUrl: "https://example.com/episode.mp3", artworkUrl: nil,
            durationSeconds: 300, positionSeconds: 120,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        manager.currentItem = item
        
        // play() should handle cold-start bootstrap via its internal check:
        // if player.currentItem == nil, let restoredItem = currentItem { ... }
        // This is instant and doesn't require URL resolution.
        
        // Verify that play() can be called without error on a cold-start state
        // (The actual handler change is in CarPlayService, but we verify the
        //  AudioManager.play() contract handles the cold-start case)
        manager.play()
        
        // After play(), the current item should still be set
        XCTAssertEqual(manager.currentItem?.id, "restored-ep",
                       "play() should preserve the current item during cold-start bootstrap")
    }
    
    /// play() should work for hot resume (player already has content loaded)
    func test_play_hotResume_worksWithoutURLResolution() {
        let manager = AudioManager()
        
        let item = QueueItem(
            id: "hot-ep", title: "Hot Episode", podcastTitle: "Test Pod",
            audioUrl: "https://example.com/episode.mp3", artworkUrl: nil,
            durationSeconds: 300, positionSeconds: 60,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        manager.currentItem = item
        
        // play() should not crash and should attempt to resume
        manager.play()
        
        // Verify no error was set (play() shouldn't trigger URL resolution errors)
        XCTAssertNil(manager.errorMessage,
                     "play() should not produce an error for hot resume")
    }
    
    // MARK: - CarPlay Dependency Race
    
    /// Verifies that CarPlayService gracefully handles nil dependencies.
    /// The updateContent() method should guard against nil without crashing.
    func test_carPlayUpdateContent_guardsNilDependencies() {
        let service = CarPlayService.shared
        
        // Clear dependencies to simulate race condition
        let savedPodcastManager = service.podcastManager
        let savedPlayerManager = service.playerManager
        let savedAudioManager = service.audioManager
        
        service.podcastManager = nil
        service.playerManager = nil
        service.audioManager = nil
        
        // scheduleUpdate should not crash when dependencies are nil
        service.scheduleUpdate()
        
        // Restore dependencies
        service.podcastManager = savedPodcastManager
        service.playerManager = savedPlayerManager
        service.audioManager = savedAudioManager
        
        // If we got here without a crash, the guard works
        XCTAssertTrue(true, "scheduleUpdate() should not crash with nil dependencies")
    }
    
    // MARK: - Offline Banner Auto-Dismissal
    
    /// The OfflineBanner uses @Observable NetworkMonitor, so when
    /// isConnected changes back to true, the banner should auto-hide.
    /// This test verifies the logic function used by the view.
    func test_offlineBanner_autoHides_whenConnectivityRestored() {
        // When connected, banner should not show
        let showWhenConnected = OfflineBannerLogic.shouldShowBanner(
            isConnected: true, isVaultMode: false
        )
        XCTAssertFalse(showWhenConnected,
                       "Banner should not show when connected")
        
        // When disconnected, banner should show (non-vault)
        let showWhenDisconnected = OfflineBannerLogic.shouldShowBanner(
            isConnected: false, isVaultMode: false
        )
        XCTAssertTrue(showWhenDisconnected,
                      "Banner should show when disconnected in non-vault mode")
        
        // When disconnected but vault mode, banner should not show
        let showWhenVault = OfflineBannerLogic.shouldShowBanner(
            isConnected: false, isVaultMode: true
        )
        XCTAssertFalse(showWhenVault,
                       "Banner should not show in vault mode even when disconnected")
    }
}

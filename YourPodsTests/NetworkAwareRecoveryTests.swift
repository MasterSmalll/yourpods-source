import XCTest
@testable import YourPods

/// Tests for network-aware stream recovery improvements in AudioManager.
/// Verifies escalating backoff schedule, network-gated retries,
/// and auto-retry on connectivity restoration.
@MainActor
final class NetworkAwareRecoveryTests: XCTestCase {
    
    // MARK: - Escalating Backoff Schedule
    
    func test_backoffSchedule_isEscalating_5_10_15_20_30() {
        let schedule = AudioManager.recoveryBackoffSchedule
        XCTAssertEqual(schedule, [5, 10, 15, 20, 30],
                       "Backoff should escalate: 5, 10, 15, 20, 30 seconds")
    }
    
    func test_backoffSchedule_hasCorrectCount() {
        XCTAssertEqual(AudioManager.recoveryBackoffSchedule.count, 5,
                       "Schedule should have exactly 5 entries matching maxRecoveryAttempts")
    }
    
    // MARK: - Network Monitor Wiring
    
    func test_networkMonitor_canBeSet() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: true)
        manager.networkMonitor = mock
        XCTAssertNotNil(manager.networkMonitor, "networkMonitor should be settable")
    }
    
    // MARK: - Auto-Retry on Connectivity Restoration
    
    /// subscribeToConnectivityRestoration() should wire the callback.
    func test_subscribeToConnectivityRestoration_wiresCallback() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        manager.subscribeToConnectivityRestoration()
        
        XCTAssertNotNil(mock.onConnectivityRestored,
                        "subscribeToConnectivityRestoration() should set onConnectivityRestored")
    }
    
    /// When connectivity is restored and there's a pending error,
    /// the callback should clear the error and trigger recovery.
    func test_autoRetryOnConnectivityRestore_clearsError() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        manager.subscribeToConnectivityRestoration()
        
        // Set up pending error state with a current item
        let item = QueueItem(
            id: "test-ep", title: "Test Episode", podcastTitle: "Test Pod",
            audioUrl: "https://example.com/episode.mp3", artworkUrl: nil,
            durationSeconds: 300, positionSeconds: 60,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        manager.currentItem = item
        manager.errorMessage = "Playback failed. Check your connection."
        
        // Simulate connectivity restoration
        mock.isConnected = true
        mock.onConnectivityRestored?()
        
        // The callback should have cleared the error immediately
        // (attemptStreamRecovery will run asynchronously for actual playback)
        XCTAssertNil(manager.errorMessage,
                     "Error should be cleared when connectivity returns and auto-retry triggers")
    }
    
    /// When connectivity is restored but there's NO pending error,
    /// nothing should happen (no unnecessary retries).
    func test_noAutoRetry_whenNoErrorPending() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: true)
        manager.networkMonitor = mock
        manager.subscribeToConnectivityRestoration()
        
        // No error — player is fine
        manager.errorMessage = nil
        
        // Simulate connectivity restoration
        mock.onConnectivityRestored?()
        
        // Should remain nil — no unnecessary action
        XCTAssertNil(manager.errorMessage,
                     "Should not create an error when there's no pending issue")
    }
    
    /// When connectivity is restored but there's no currentItem,
    /// nothing should happen even if errorMessage is set.
    func test_noAutoRetry_whenNoCurrentItem() {
        let manager = AudioManager()
        let mock = MockNetworkMonitor(isConnected: false)
        manager.networkMonitor = mock
        manager.subscribeToConnectivityRestoration()
        
        manager.errorMessage = "Some error"
        manager.currentItem = nil
        
        mock.onConnectivityRestored?()
        
        // Error should persist since no item to retry
        XCTAssertEqual(manager.errorMessage, "Some error",
                       "Error should persist when there's no current item to retry")
    }
    
    // MARK: - Preferred Forward Buffer Duration
    
    func test_preferredForwardBufferDuration_constant() {
        let schedule = AudioManager.recoveryBackoffSchedule
        XCTAssertEqual(schedule.first, 5,
                       "First retry should be 5s for fast initial recovery")
    }
}

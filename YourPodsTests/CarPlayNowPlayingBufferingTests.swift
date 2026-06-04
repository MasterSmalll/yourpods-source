import XCTest
@testable import YourPods

/// Tests for CarPlay Now Playing screen buffering/recovery feedback.
///
/// When a user is on the CarPlay Now Playing screen (CPNowPlayingTemplate),
/// they should see status feedback when:
/// 1. Audio is buffering (initial connect) → "Connecting…"
/// 2. Stream recovery is in progress → "Reconnecting…"
/// 3. Stream recovery has failed → "No connection"
///
/// This feedback is shown in the MPNowPlayingInfoCenter artist field,
/// which is visible on CarPlay Now Playing, Lock Screen, and Dynamic Island.
@MainActor
final class CarPlayNowPlayingBufferingTests: XCTestCase {
    
    /// Helper to create a test QueueItem with known metadata.
    private func makeTestItem(
        id: String = "test-ep",
        title: String = "Test Episode",
        podcastTitle: String = "Test Podcast",
        podcastAuthor: String? = "Test Author",
        audioUrl: String = "https://example.com/episode.mp3"
    ) -> QueueItem {
        QueueItem(
            id: id, title: title, podcastTitle: podcastTitle,
            audioUrl: audioUrl, artworkUrl: nil,
            durationSeconds: 300, positionSeconds: 60,
            podcastUrl: "https://example.com/feed", pubDate: nil,
            podcastAuthor: podcastAuthor
        )
    }
    
    // MARK: - Now Playing subtitle (artist field) state logic
    
    /// When buffering, the now-playing artist field should include "Connecting…"
    /// so users see feedback on CarPlay Now Playing, Lock Screen, etc.
    func test_nowPlayingSubtitle_showsConnectingWhenBuffering() {
        let manager = AudioManager()
        let item = makeTestItem()
        manager.currentItem = item
        
        // Simulate buffering state
        manager.isBuffering = true
        manager.errorMessage = nil
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertTrue(subtitle.contains("Connecting"),
                      "Now Playing subtitle should show 'Connecting…' during buffering, got: \(subtitle)")
        XCTAssertTrue(subtitle.contains("Test Author"),
                      "Now Playing subtitle should still include the podcast author, got: \(subtitle)")
    }
    
    /// When recovering from a stream error, the now-playing artist field should
    /// show "Reconnecting…" so users know recovery is in progress.
    func test_nowPlayingSubtitle_showsReconnectingDuringRecovery() {
        let manager = AudioManager()
        let item = makeTestItem()
        manager.currentItem = item
        
        // Simulate recovery state (not buffering, but actively recovering)
        manager.isBuffering = false
        manager.errorMessage = nil
        manager.setRecoveringForTest(true)
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertTrue(subtitle.contains("Reconnecting"),
                      "Now Playing subtitle should show 'Reconnecting…' during recovery, got: \(subtitle)")
        XCTAssertTrue(subtitle.contains("Test Author"),
                      "Now Playing subtitle should still include the podcast author, got: \(subtitle)")
    }
    
    /// When there's an error message (recovery exhausted or offline), the
    /// now-playing artist field should reflect the error.
    func test_nowPlayingSubtitle_showsErrorMessage() {
        let manager = AudioManager()
        let item = makeTestItem()
        manager.currentItem = item
        
        manager.isBuffering = false
        manager.setRecoveringForTest(false)
        manager.errorMessage = "No connection. Will retry when network returns."
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertTrue(subtitle.contains("No connection"),
                      "Now Playing subtitle should show error, got: \(subtitle)")
        XCTAssertTrue(subtitle.contains("Test Author"),
                      "Now Playing subtitle should still include the podcast author, got: \(subtitle)")
    }
    
    /// When playback is normal (not buffering, not recovering, no error),
    /// the now-playing artist field should show just the podcast author or title.
    func test_nowPlayingSubtitle_showsNormalTextWhenIdle() {
        let manager = AudioManager()
        let item = makeTestItem()
        manager.currentItem = item
        
        manager.isBuffering = false
        manager.setRecoveringForTest(false)
        manager.errorMessage = nil
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        // When no status, should return the author (or podcast title if no author)
        XCTAssertEqual(subtitle, "Test Author",
                       "Normal state should show author, got: \(subtitle)")
    }
    
    /// When there's no author, the normal subtitle should fall back to podcast title.
    func test_nowPlayingSubtitle_fallsToPodcastTitleWhenNoAuthor() {
        let manager = AudioManager()
        let item = makeTestItem(podcastAuthor: nil)
        manager.currentItem = item
        
        manager.isBuffering = false
        manager.setRecoveringForTest(false)
        manager.errorMessage = nil
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertEqual(subtitle, "Test Podcast",
                       "Normal state without author should show podcast title, got: \(subtitle)")
    }
    
    /// Buffering state should take priority over recovery state
    /// (they shouldn't both be true normally, but if they are, buffering wins).
    func test_nowPlayingSubtitle_bufferingTakesPriorityOverRecovery() {
        let manager = AudioManager()
        let item = makeTestItem()
        manager.currentItem = item
        
        manager.isBuffering = true
        manager.setRecoveringForTest(true)
        manager.errorMessage = nil
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertTrue(subtitle.contains("Connecting"),
                      "Buffering should take priority over recovery, got: \(subtitle)")
    }
    
    /// Error message should take priority over recovery state.
    func test_nowPlayingSubtitle_errorTakesPriorityOverRecovery() {
        let manager = AudioManager()
        let item = makeTestItem()
        manager.currentItem = item
        
        manager.isBuffering = false
        manager.setRecoveringForTest(true)
        manager.errorMessage = "Playback failed. Check your connection."
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertTrue(subtitle.contains("Playback failed"),
                      "Error should take priority over recovery, got: \(subtitle)")
    }
    
    /// When there's no current item, subtitle should return empty string.
    func test_nowPlayingSubtitle_emptyWhenNoCurrentItem() {
        let manager = AudioManager()
        manager.currentItem = nil
        
        let subtitle = manager.nowPlayingStatusSubtitle
        
        XCTAssertEqual(subtitle, "",
                       "Subtitle should be empty when no current item")
    }
}

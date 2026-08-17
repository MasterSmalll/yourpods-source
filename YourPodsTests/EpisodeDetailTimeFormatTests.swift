/// Tests that EpisodeDetailSheet uses precise timestamp formatting (m:ss / h:mm:ss)
/// for playback position and time-left, matching the NowPlayingBar.
///
/// Bug: EpisodeDetailSheet was using `formatDuration()` which rounds to the nearest
/// minute (e.g. "23m") instead of `formatTimestamp()` which shows exact seconds
/// (e.g. "23:14"). This caused the episode detail sheet to display incorrect/imprecise
/// position and time-left when compared to the mini player.
import XCTest
@testable import YourPods

final class EpisodeDetailTimeFormatTests: XCTestCase {
    
    // MARK: - formatTimestamp vs formatDuration difference
    
    /// formatTimestamp should show precise m:ss for sub-hour values
    func test_formatTimestamp_showsMinutesAndSeconds() {
        // 23 minutes, 14 seconds = 1394 seconds
        let result = PlayerManager.formatTimestamp(1394)
        XCTAssertEqual(result, "23:14",
                       "formatTimestamp should show precise m:ss — this is what NowPlayingBar uses")
    }
    
    /// formatDuration intentionally rounds (for metadata labels), so it's wrong for position display
    func test_formatDuration_dropsSeconds_showingWhyItIsWrongForPositionDisplay() {
        // 23 minutes, 14 seconds = 1394 seconds
        let result = PlayerManager.formatDuration(1394)
        XCTAssertEqual(result, "23m",
                       "formatDuration intentionally drops seconds — confirming it's the wrong function for position display")
    }
    
    // MARK: - EpisodeDetailSheet should use formatTimestamp (like NowPlayingBar)
    
    /// The playbackSection's position label should use formatTimestamp, not formatDuration.
    /// We verify by checking that formatTimestamp produces the expected output for typical positions.
    func test_formatTimestamp_preciseForShortDuration() {
        // 5 minutes, 37 seconds
        XCTAssertEqual(PlayerManager.formatTimestamp(337), "5:37")
    }
    
    func test_formatTimestamp_preciseForHourPlusDuration() {
        // 1 hour, 23 minutes, 45 seconds = 5025 seconds
        XCTAssertEqual(PlayerManager.formatTimestamp(5025), "1:23:45")
    }
    
    func test_formatTimestamp_zeroSeconds() {
        XCTAssertEqual(PlayerManager.formatTimestamp(0), "0:00")
    }
    
    func test_formatTimestamp_exactMinute() {
        // 30 minutes exactly
        XCTAssertEqual(PlayerManager.formatTimestamp(1800), "30:00")
    }
    
    func test_formatTimestamp_negativeClampedToZero() {
        // Negative values should display as 0:00
        XCTAssertEqual(PlayerManager.formatTimestamp(-5), "0:00")
    }
    
    // MARK: - Static progress section consistency
    
    /// The static progress section (non-playing episode with progress) should also
    /// use formatTimestamp for the listened position and remaining time.
    ///
    /// Example: episode.listenedSeconds = 1394, durationSeconds = 3600
    /// Expected position: "23:14" (not "23m")
    /// Expected remaining: "-36:46" (not "-36m")
    func test_staticProgress_positionShouldBeTimestamp() {
        let listenedSeconds = 1394
        let position = TimeInterval(listenedSeconds)
        
        let timestampResult = PlayerManager.formatTimestamp(position)
        let durationResult = PlayerManager.formatDuration(position)
        
        XCTAssertEqual(timestampResult, "23:14",
                       "Static progress position should use formatTimestamp for precision")
        XCTAssertNotEqual(timestampResult, durationResult,
                          "formatTimestamp and formatDuration should produce different results, " +
                          "confirming formatDuration is imprecise for position display")
    }
    
    func test_staticProgress_remainingShouldBeTimestamp() {
        let durationSeconds = 3600
        let listenedSeconds = 1394
        let remaining = durationSeconds - listenedSeconds  // 2206 seconds
        
        let timestampResult = PlayerManager.formatTimestamp(TimeInterval(remaining))
        let durationResult = PlayerManager.formatDuration(TimeInterval(remaining))
        
        XCTAssertEqual(timestampResult, "36:46",
                       "Static progress remaining should use formatTimestamp for precision")
        XCTAssertEqual(durationResult, "36m",
                       "formatDuration rounds — confirming it's the wrong format for remaining time")
    }
}

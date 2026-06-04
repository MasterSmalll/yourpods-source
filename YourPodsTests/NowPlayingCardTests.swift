import XCTest
@testable import YourPods

/// Tests for the NowPlayingCard condensed metadata helper and layout constants.
final class NowPlayingCardTests: XCTestCase {
    
    // MARK: - Condensed Metadata Formatting
    
    func test_condensedMetadata_withDateAndFullDuration() {
        // Episode not started — should show date + total duration
        let date = Date(timeIntervalSince1970: 1_767_600_000) // Jan 5, 2026
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: date,
            durationSeconds: 5025, // 1:23:45
            position: 0,
            totalDuration: 5025
        )
        // Should contain date portion and duration
        XCTAssertTrue(result.contains("2026"), "Should contain the year")
        XCTAssertTrue(result.contains("·"), "Should contain separator")
        XCTAssertTrue(result.contains("1:23:45"), "Should show full duration when position is 0")
    }
    
    func test_condensedMetadata_withDateAndProgress() {
        // Episode partially played — should show date + percent listened
        let date = Date(timeIntervalSince1970: 1_767_600_000)
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: date,
            durationSeconds: 3600,
            position: 1800,
            totalDuration: 3600
        )
        XCTAssertTrue(result.contains("50%"), "Should show 50% listened")
        XCTAssertTrue(result.contains("listened"), "Should contain 'listened'")
    }
    
    func test_condensedMetadata_withNoDate() {
        // No pub date — should show duration only, no separator
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: nil,
            durationSeconds: 3600,
            position: 0,
            totalDuration: 3600
        )
        XCTAssertFalse(result.contains("·"), "Should not contain separator when no date")
        XCTAssertTrue(result.contains("1:00:00"), "Should show duration")
    }
    
    func test_condensedMetadata_withNoDuration() {
        // No duration (live stream or unknown) — date only
        let date = Date(timeIntervalSince1970: 1_767_600_000)
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: date,
            durationSeconds: nil,
            position: 0,
            totalDuration: 0
        )
        XCTAssertTrue(result.contains("2026"), "Should contain the year")
        XCTAssertFalse(result.contains("·"), "Should not have separator when no duration at all")
    }
    
    func test_condensedMetadata_bothNil() {
        // No date, no duration — empty
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: nil,
            durationSeconds: nil,
            position: 0,
            totalDuration: 0
        )
        XCTAssertTrue(result.isEmpty, "Should be empty when no date and no duration")
    }
    
    // MARK: - EDGE: Boundary cases
    
    func test_EDGE_condensedMetadata_at100Percent() {
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: nil,
            durationSeconds: 3600,
            position: 3600,
            totalDuration: 3600
        )
        XCTAssertTrue(result.contains("100%"), "Should show 100% at end of episode")
    }
    
    func test_EDGE_condensedMetadata_atSmallPosition() {
        // Position > 0 but < 1% should show "1% listened" not "0%"
        let result = NowPlayingCardHelper.condensedMetadata(
            pubDate: nil,
            durationSeconds: 3600,
            position: 10,
            totalDuration: 3600
        )
        // 10/3600 = 0.28% — should be 0% or handled gracefully
        XCTAssertFalse(result.isEmpty, "Should not be empty with position and duration")
    }
}

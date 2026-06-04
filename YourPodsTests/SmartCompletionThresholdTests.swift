import XCTest
@testable import YourPods

/// Tests for the smart completion threshold that accounts for skipOutroSeconds.
///
/// The static 95% threshold can miss episodes with large outros — if a user
/// has skipOutroSeconds = 300 on a 3600s episode, position 3300 means they've
/// heard all the content (91.7%). The smart threshold lowers it accordingly.
@MainActor
final class SmartCompletionThresholdTests: XCTestCase {

    // MARK: - effectiveCompletionThreshold tests

    /// With no skipOutro, default is 95%.
    func test_threshold_noSkipOutro_returns95Percent() {
        let threshold = EpisodeActionSyncService.effectiveCompletionThreshold(
            totalDuration: 3600, skipOutroSeconds: 0
        )
        XCTAssertEqual(threshold, Int(3600.0 * 0.95),
                       "Without skipOutro, threshold should be 95% of total duration")
    }

    /// With skipOutro = 300s on a 3600s episode (8.3%), the threshold should be
    /// total - skipOutro = 3300 (lower than 95% = 3420).
    func test_threshold_withSkipOutro_lowersThreshold() {
        let threshold = EpisodeActionSyncService.effectiveCompletionThreshold(
            totalDuration: 3600, skipOutroSeconds: 300
        )
        XCTAssertEqual(threshold, 3300,
                       "With 300s skipOutro on 3600s episode, threshold should be 3300 (not 3420)")
    }

    /// When skipOutro would lower the threshold below 80%, clamp at 80%.
    func test_threshold_largeSkipOutro_clampsAt80Percent() {
        // skipOutro = 1000 on 3600s → threshold would be 2600 (72.2%)
        // Should be clamped to 80% = 2880
        let threshold = EpisodeActionSyncService.effectiveCompletionThreshold(
            totalDuration: 3600, skipOutroSeconds: 1000
        )
        XCTAssertEqual(threshold, Int(3600.0 * 0.80),
                       "Threshold must never go below 80% even with large skipOutro")
    }

    /// When skipOutro is small (e.g. 30s on 3600s episode), 95% threshold
    /// is already lower — keep the standard 95%.
    func test_threshold_smallSkipOutro_keeps95Percent() {
        // skipOutro = 30 on 3600s → total - 30 = 3570 > 95% (3420)
        // 95% is lower so use 95%
        let threshold = EpisodeActionSyncService.effectiveCompletionThreshold(
            totalDuration: 3600, skipOutroSeconds: 30
        )
        XCTAssertEqual(threshold, Int(3600.0 * 0.95),
                       "Small skipOutro should not affect the standard 95% threshold")
    }

    /// Very short episodes (<=60s) should never trigger the threshold.
    func test_threshold_shortEpisode_returnsTotal() {
        let threshold = EpisodeActionSyncService.effectiveCompletionThreshold(
            totalDuration: 45, skipOutroSeconds: 0
        )
        XCTAssertEqual(threshold, 45,
                       "Short episodes should return total duration (never auto-complete)")
    }
}

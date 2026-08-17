import XCTest
@testable import YourPods

/// Tests for strategy-bypass cleanup.
///
/// Ensures:
/// - No call site can silently bypass the user's conflict strategy
/// - Conflict thresholds are consistent between pull and apply phases
@MainActor
final class StrategyBypassTests: XCTestCase {

    /// SyncThresholds.applyConflictGapSeconds must equal pullConflictGapSeconds.
    /// If they differ, some conflicts are caught in pull but not apply, or vice versa.
    func test_conflictThresholds_consistentBetweenPullAndApply() {
        XCTAssertEqual(
            SyncThresholds.pullConflictGapSeconds,
            SyncThresholds.applyConflictGapSeconds,
            "Pull and apply conflict thresholds must be identical to prevent inconsistent conflict detection"
        )
    }

    /// Default conflict strategy in SettingsManager is .ask.
    func test_defaultConflictStrategy_isAsk() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.syncConflictStrategy, .ask,
                       "Default strategy must be .ask to ensure user is prompted for conflicts")
    }
}

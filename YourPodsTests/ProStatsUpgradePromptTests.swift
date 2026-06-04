import XCTest
@testable import YourPods

/// Ensures the ProStatsView does NOT show an "Upgrade to Pro" prompt.
/// Pro is not public yet — any upsell leaking into the stats screen
/// violates the "Pro features must not leak" rule from GEMINI.md.
final class ProStatsUpgradePromptTests: XCTestCase {

    // MARK: - Upgrade Prompt Suppressed

    /// The stats view must never show an upgrade prompt (Pro is not public).
    func test_upgradePrompt_isNeverShown() {
        XCTAssertFalse(
            ProStatsView.showsUpgradePrompt,
            "ProStatsView must NOT show an upgrade prompt — Pro is not public"
        )
    }

    /// Even for sync-tier responses, no upgrade prompt should appear.
    func test_syncTierResponse_noUpgradePromptText() {
        let syncResponse = ProStatsResponse(
            tier: "sync",
            since: nil,
            streak: 5,
            stats: ProStats(
                totalListenTimeSec: 3600,
                totalContentTimeSec: nil,
                totalSkippedSec: nil,
                manualSkipsSec: nil,
                autoSkipsSec: nil,
                chapterSkipsSec: nil,
                manualSkipCount: nil,
                autoSkipCount: nil,
                chapterSkipCount: nil,
                uniqueEpisodes: 10,
                uniquePodcasts: 3
            ),
            topPodcasts: nil,
            dailyTrend: nil
        )
        // Sync tier should not trigger any upgrade prompt logic
        XCTAssertEqual(syncResponse.tier, "sync")
        XCTAssertFalse(
            ProStatsView.showsUpgradePrompt,
            "Sync-tier users must not see an upgrade prompt"
        )
    }
}

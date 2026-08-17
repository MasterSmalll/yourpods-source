import XCTest
@testable import YourPods

/// Tests for `SyncCoalescing` — the single-flight join decision in `refreshAndSync`.
///
/// A user-initiated FOREGROUND refresh (pull-to-refresh / Refresh & Sync button)
/// must NOT silently adopt an in-flight BACKGROUND sync. The background pipeline
/// defers RSS refresh to last (Priority 5) and is cancellation-prone (BGTask
/// expiry), so a foreground caller that joins it inherits a sync that never
/// reaches RSS — the user pulls to refresh and no new episodes ever land.
final class SyncCoalescingTests: XCTestCase {

    /// Foreground joining an in-flight background sync is the bug — must NOT join.
    func test_foreground_mustNotJoin_inflightBackgroundSync() {
        XCTAssertFalse(
            SyncCoalescing.canJoinInFlight(incomingIsBackground: false, inFlightIsBackground: true),
            "A foreground refresh must not adopt an in-flight background sync (RSS is deferred to last and cancellation-prone)"
        )
    }

    /// Background joining background is fine — coalesce duplicate background work.
    func test_background_mayJoin_inflightBackgroundSync() {
        XCTAssertTrue(
            SyncCoalescing.canJoinInFlight(incomingIsBackground: true, inFlightIsBackground: true)
        )
    }

    /// Foreground joining foreground is fine — both run RSS early (Step 3).
    func test_foreground_mayJoin_inflightForegroundSync() {
        XCTAssertTrue(
            SyncCoalescing.canJoinInFlight(incomingIsBackground: false, inFlightIsBackground: false)
        )
    }

    /// Background joining an in-flight foreground sync is fine — the foreground
    /// pipeline refreshes RSS early, so the background caller's needs are met.
    func test_background_mayJoin_inflightForegroundSync() {
        XCTAssertTrue(
            SyncCoalescing.canJoinInFlight(incomingIsBackground: true, inFlightIsBackground: false)
        )
    }
}

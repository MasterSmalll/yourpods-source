import XCTest
@testable import YourPods

/// Tests for `SyncLifecyclePolicy` — the runtime decision of which iOS
/// suspension-defense behaviors apply.
///
/// Root cause ("Mac stays stale"): the `.background` scenePhase handler cancels
/// all in-flight sync to satisfy the 0xDEAD10CC / 0x8BADF00D defenses. On a real
/// iOS device that is correct — `.background` is the last beat before the process
/// is suspended, and a SQLite write straddling suspension (or a heavy save that
/// blocks the 5s termination watchdog) is killed.
///
/// The SAME binary runs as a "Designed for iPad" app on Apple Silicon Macs, where
/// `scenePhase` flips to `.background` whenever the window merely loses key focus
/// (e.g. the user switching to a browser to confirm a sync landed). macOS never
/// suspension-kills a process for a held SQLite lock — it App-Naps / petrifies and
/// resumes — so cancelling there is all cost: the LATE playback-reconcile step
/// never runs and the Mac never ingests server now-playing / queue.
final class SyncLifecyclePolicyTests: XCTestCase {

    func test_cancelsInFlightSyncOnBackground_trueOnIOSDevice() {
        // Real iOS hardware: .background precedes suspension — MUST cancel.
        XCTAssertTrue(
            SyncLifecyclePolicy.cancelsInFlightSyncOnBackground(isiOSAppOnMac: false),
            "On a real iOS device, .background precedes suspension — in-flight sync must be cancelled to avoid 0xDEAD10CC / 0x8BADF00D."
        )
    }

    func test_cancelsInFlightSyncOnBackground_falseOnIOSAppOnMac() {
        // iOS-app-on-Mac: .background is just focus loss, no suspension kill.
        XCTAssertFalse(
            SyncLifecyclePolicy.cancelsInFlightSyncOnBackground(isiOSAppOnMac: true),
            "On the iOS-app-on-Mac, cancelling on focus-loss starves the late reconcile step — the Mac stays stale."
        )
    }

    // MARK: - Foreground sync debounce (cross-device handoff freshness)
    //
    // Root cause (pull side): the `.active` foreground sync is debounced 5 minutes,
    // sized for the iPhone's app-open cadence. On the iOS-app-on-Mac, `.active`
    // fires on every window refocus, so switching iPhone → Mac inside 5 min is
    // silently suppressed and the Mac never pulls the iPhone's just-changed state.

    func test_foregroundSyncDebounceInterval_iOSDevice_isFiveMinutes() {
        XCTAssertEqual(
            SyncLifecyclePolicy.foregroundSyncDebounceInterval(isiOSAppOnMac: false),
            5 * 60,
            accuracy: 0.001,
            "Real iOS devices debounce foreground sync at the app-open cadence (5 min)."
        )
    }

    func test_foregroundSyncDebounceInterval_iOSAppOnMac_isTinyCoalescingWindow() {
        let interval = SyncLifecyclePolicy.foregroundSyncDebounceInterval(isiOSAppOnMac: true)
        XCTAssertLessThanOrEqual(
            interval, 5,
            "iOS-app-on-Mac fires .active on every window refocus; the debounce must be a tiny coalescing window so switching to the Mac pulls fresh state effectively immediately."
        )
        XCTAssertGreaterThan(
            interval, 0,
            "A small non-zero window still coalesces a burst of duplicate .active focus events."
        )
    }

    func test_shouldPerformForegroundSync_onMac_syncsOnRefocusWithinFiveMinutes() {
        let bg = BackgroundRefreshService()
        let last = Date(timeIntervalSinceReferenceDate: 1000)
        bg.lastForegroundSyncDate = last
        // 30s after the last sync — far inside the iOS 5-min debounce, but the Mac
        // MUST still sync (this is exactly the "switched to the Mac window" case).
        let now = last.addingTimeInterval(30)
        XCTAssertTrue(
            bg.shouldPerformForegroundSync(isiOSAppOnMac: true, now: now),
            "On the iOS-app-on-Mac, refocusing the window 30s after the last sync MUST pull fresh state — the iOS 5-min debounce would wrongly suppress it (the 'Mac stays stale' handoff bug)."
        )
    }

    func test_shouldPerformForegroundSync_oniOS_debouncesWithinFiveMinutes() {
        let bg = BackgroundRefreshService()
        let last = Date(timeIntervalSinceReferenceDate: 1000)
        bg.lastForegroundSyncDate = last
        let now = last.addingTimeInterval(30)
        XCTAssertFalse(
            bg.shouldPerformForegroundSync(isiOSAppOnMac: false, now: now),
            "On a real iOS device, foregrounding 30s after the last sync stays debounced (app-open cadence)."
        )
    }

    func test_shouldPerformForegroundSync_onMac_coalescesDuplicateFocusEvents() {
        let bg = BackgroundRefreshService()
        let last = Date(timeIntervalSinceReferenceDate: 1000)
        bg.lastForegroundSyncDate = last
        // A duplicate .active fired within the coalescing window must not double-sync.
        let now = last.addingTimeInterval(0.5)
        XCTAssertFalse(
            bg.shouldPerformForegroundSync(isiOSAppOnMac: true, now: now),
            "Two .active events within the tiny coalescing window should still produce a single sync."
        )
    }

    func test_shouldPerformForegroundSync_returnsTrueWhenNeverSynced() {
        let bg = BackgroundRefreshService()
        bg.lastForegroundSyncDate = nil
        XCTAssertTrue(
            bg.shouldPerformForegroundSync(isiOSAppOnMac: true),
            "A fresh launch (no prior sync) always syncs, on Mac and iOS alike."
        )
        XCTAssertTrue(
            bg.shouldPerformForegroundSync(isiOSAppOnMac: false),
            "A fresh launch (no prior sync) always syncs, on Mac and iOS alike."
        )
    }
}

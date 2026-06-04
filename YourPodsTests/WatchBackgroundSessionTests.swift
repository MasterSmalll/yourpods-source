import XCTest
@testable import YourPods

/// TDD tests for watch background URL session crash fix — CAROUSEL watchdog kills.
///
/// Root cause: Both crash reports (F5230ADA, D9447DC9) show the same termination:
///   Namespace CAROUSEL, Code 3306925314
///   CSLHandleBackgroundURLSessionAction watchdog transgression
///   Exhausted wall time allowance of 15.00 seconds
///
/// Bug 1: Safety timeout was 30s — DOUBLE the 15s watchdog limit.
/// Bug 2: Race condition — completion handler set AFTER session reconnect,
///         so urlSessionDidFinishEvents could fire into a nil handler.
/// Bug 3: BackgroundRefreshManager calls completion() before sendMessage reply,
///         causing queue updates during suspension → CAROUSEL kill.
final class WatchBackgroundSessionTests: XCTestCase {

    // MARK: - Bug 1: Safety Timeout Must Be Under Watchdog Limit

    func test_safetyTimeout_isStrictlyUnderWatchdogLimit() {
        XCTAssertLessThan(
            WatchBackgroundSessionConfig.safetyTimeout,
            WatchBackgroundSessionConfig.watchdogLimit,
            "Safety timeout (\(WatchBackgroundSessionConfig.safetyTimeout)s) must be " +
            "strictly less than CAROUSEL watchdog limit (\(WatchBackgroundSessionConfig.watchdogLimit)s). " +
            "See crashes F5230ADA, D9447DC9."
        )
    }

    func test_safetyTimeout_hasReasonableMargin() {
        // At least 3 seconds of margin for URLSession event delivery + cleanup
        let margin = WatchBackgroundSessionConfig.watchdogLimit - WatchBackgroundSessionConfig.safetyTimeout
        XCTAssertGreaterThanOrEqual(
            margin,
            3.0,
            "Need ≥3s margin between safety timeout and watchdog limit for event delivery"
        )
    }

    func test_backgroundRefreshTimeout_isUnderBudget() {
        // watchOS background refresh budget is ~15 seconds
        XCTAssertLessThan(
            WatchBackgroundSessionConfig.backgroundRefreshTimeout,
            WatchBackgroundSessionConfig.backgroundRefreshBudget,
            "Background refresh timeout must be under the system budget"
        )
    }

    // MARK: - Bug 2: Handler-Before-Reconnect Ordering Invariant

    /// Verifies the BackgroundSessionSequencer enforces the correct ordering:
    /// 1. Set completion handler
    /// 2. Reconnect session
    /// 3. Start safety timeout
    func test_sequencer_mustSetHandlerBeforeReconnect() {
        var sequencer = BackgroundSessionSequencer()

        // Reconnecting before setting handler is an error
        XCTAssertFalse(
            sequencer.canReconnect,
            "Must not reconnect before handler is set — race condition"
        )

        sequencer.markHandlerSet()

        XCTAssertTrue(
            sequencer.canReconnect,
            "Reconnect should be allowed after handler is set"
        )
    }

    func test_sequencer_resetClearsState() {
        var sequencer = BackgroundSessionSequencer()
        sequencer.markHandlerSet()
        XCTAssertTrue(sequencer.canReconnect)

        sequencer.reset()

        XCTAssertFalse(
            sequencer.canReconnect,
            "After reset, must set handler again before reconnecting"
        )
    }

    func test_sequencer_completionFiresExactlyOnce() {
        var sequencer = BackgroundSessionSequencer()
        var completionCount = 0

        sequencer.markHandlerSet()
        sequencer.markCompleted { completionCount += 1 }
        sequencer.markCompleted { completionCount += 1 }

        XCTAssertEqual(completionCount, 1,
                       "Completion must fire exactly once — duplicate calls are ignored")
    }

    // MARK: - Persistence Throttle (debounce saves)

    func test_persistenceThrottle_firstSaveNotDeferred() {
        let throttle = WatchPersistenceThrottle()
        XCTAssertFalse(throttle.shouldDeferSave(),
                       "First save should never be deferred")
    }

    func test_persistenceThrottle_deferredWithinInterval() {
        var throttle = WatchPersistenceThrottle()
        throttle.recordSave()
        XCTAssertTrue(throttle.shouldDeferSave(),
                      "Save within debounce interval should be deferred")
    }

    func test_persistenceThrottle_allowedAfterInterval() {
        var throttle = WatchPersistenceThrottle()
        // Simulate a save that happened longer ago than the debounce interval
        throttle.overrideLastSaveTime(Date().addingTimeInterval(-1.0))

        XCTAssertFalse(throttle.shouldDeferSave(),
                       "Save should be allowed after debounce interval passes")
    }

    func test_persistenceThrottle_resetAllowsImmediateSave() {
        var throttle = WatchPersistenceThrottle()
        throttle.recordSave()
        XCTAssertTrue(throttle.shouldDeferSave())

        throttle.reset()

        XCTAssertFalse(throttle.shouldDeferSave(),
                       "After reset, save should be allowed immediately")
    }
}

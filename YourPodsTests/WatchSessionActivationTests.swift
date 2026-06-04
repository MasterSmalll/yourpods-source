import XCTest
@testable import YourPods

/// TDD tests for watch session activation ordering — crash fix for intermittent
/// launch crash in YourPodsWatch_Watch_AppApp.$main().
///
/// **Root cause:** WatchSessionManager.init() called WCSession.activate() and
/// registered NotificationCenter observers during App struct construction.
/// With the singleton pattern (`private let ... = .shared`), this runs BEFORE
/// SwiftUI's observation infrastructure is ready. If WCSession delivers pending
/// applicationContext immediately after activation, @Published property mutations
/// hit un-wired Combine publishers → double-free / use-after-free.
///
/// **Fix:** Defer activation to onAppear via WatchSessionActivationSequencer.
/// init() must produce zero side effects — no WCSession, no observers.
final class WatchSessionActivationTests: XCTestCase {

    // MARK: - Invariant: init() must NOT activate

    func test_freshSequencer_isNotActivated() {
        let sequencer = WatchSessionActivationSequencer()

        XCTAssertFalse(
            sequencer.activated,
            "A freshly created sequencer must NOT be activated — " +
            "this mirrors WatchSessionManager.init() which must not call WCSession.activate()"
        )
    }

    func test_freshSequencer_cannotMutatePublishedProperties() {
        let sequencer = WatchSessionActivationSequencer()

        XCTAssertFalse(
            sequencer.canMutatePublishedProperties,
            "Before activation, @Published properties must not be mutated — " +
            "SwiftUI's observation infrastructure is not ready during init()"
        )
    }

    func test_freshSequencer_observersNotRegistered() {
        let sequencer = WatchSessionActivationSequencer()

        XCTAssertFalse(
            sequencer.observersRegistered,
            "NotificationCenter observers must not be registered during init() — " +
            "they can deliver events before SwiftUI is ready"
        )
    }

    // MARK: - activate() enables mutation

    func test_activate_enablesMutation() {
        var sequencer = WatchSessionActivationSequencer()

        sequencer.activate()

        XCTAssertTrue(
            sequencer.activated,
            "After activate() is called (from onAppear), the session should be activated"
        )
        XCTAssertTrue(
            sequencer.canMutatePublishedProperties,
            "After activation, @Published mutations are safe"
        )
    }

    // MARK: - activate() is idempotent

    func test_activate_isIdempotent() {
        var sequencer = WatchSessionActivationSequencer()

        sequencer.activate()
        sequencer.activate()
        sequencer.activate()

        XCTAssertEqual(
            sequencer.totalActivations, 1,
            "activate() must be idempotent — WCSession.activate() should only be called once"
        )
    }

    // MARK: - Observer registration requires activation

    func test_registerObservers_requiresActivation() {
        var sequencer = WatchSessionActivationSequencer()

        // Try to register without activating first
        sequencer.registerObservers()

        XCTAssertFalse(
            sequencer.observersRegistered,
            "registerObservers() must be a no-op if activate() hasn't been called — " +
            "prevents observers from firing during init()"
        )
    }

    func test_registerObservers_succedsAfterActivation() {
        var sequencer = WatchSessionActivationSequencer()

        sequencer.activate()
        sequencer.registerObservers()

        XCTAssertTrue(
            sequencer.observersRegistered,
            "After activation, observers can be registered safely"
        )
    }

    // MARK: - Full lifecycle mirrors app startup

    func test_fullLifecycle_matchesAppStartupOrder() {
        // This test mirrors the exact startup sequence in YourPodsWatchApp:
        //
        //   1. App struct created  → WatchSessionManager.shared init()
        //   2. body evaluated      → SwiftUI sets up observation
        //   3. onAppear fires      → activate() called
        //
        // At step 1, nothing should be activated.
        // At step 3, activation should succeed.

        var sequencer = WatchSessionActivationSequencer()

        // Step 1: init() — verify clean state
        XCTAssertFalse(sequencer.activated)
        XCTAssertFalse(sequencer.canMutatePublishedProperties)
        XCTAssertFalse(sequencer.observersRegistered)

        // Step 3: onAppear → activate()
        sequencer.activate()
        sequencer.registerObservers()

        XCTAssertTrue(sequencer.activated)
        XCTAssertTrue(sequencer.canMutatePublishedProperties)
        XCTAssertTrue(sequencer.observersRegistered)
        XCTAssertEqual(sequencer.totalActivations, 1)
    }
}

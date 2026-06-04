import Foundation

/// Enforces the correct activation ordering for watchOS WatchSessionManager.
///
/// **Race condition (intermittent crash at $main()):**
/// When WatchSessionManager was @StateObject, SwiftUI deferred creation to the
/// first body evaluation — observation infrastructure was already ready.
/// After migrating to `private let ... = .shared` singletons (CAROUSEL fix),
/// the singleton is created during App struct construction. If WCSession.activate()
/// runs in init(), pending applicationContext can be delivered before SwiftUI
/// wires its ObservableObjectPublisher → double-free/use-after-free in Combine.
///
/// **The fix:** Defer WCSession activation to onAppear via this sequencer:
/// 1. init()    → create singleton, NO side effects (no WCSession, no observers)
/// 2. onAppear  → call activate() which sets `activated = true`
/// 3. Only AFTER activate() can WCSession deliver data to @Published properties
///
/// **Invariant:** init() must NEVER set `activated = true`.
struct WatchSessionActivationSequencer {
    private(set) var activated = false
    private(set) var observersRegistered = false
    private var activationCount = 0

    /// Whether it is safe to mutate @Published properties on the ObservableObject.
    /// Only true after activate() has been called from onAppear.
    var canMutatePublishedProperties: Bool { activated }

    /// Mark the session as activated. Call from onAppear, NOT from init().
    /// Idempotent — calling multiple times is safe.
    mutating func activate() {
        guard !activated else { return }
        activated = true
        activationCount += 1
    }

    /// Register NotificationCenter observers. Call from activate(), NOT from init().
    mutating func registerObservers() {
        guard activated else { return }
        observersRegistered = true
    }

    /// How many times activate() actually performed activation (should be exactly 1).
    var totalActivations: Int { activationCount }

    /// Reset for testing.
    mutating func reset() {
        activated = false
        observersRegistered = false
        activationCount = 0
    }
}

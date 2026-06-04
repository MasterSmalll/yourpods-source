import Foundation

/// Configuration constants for watch background URL session handling.
///
/// The CAROUSEL watchdog enforces a hard 15-second wall-time limit for
/// background URL session tasks on watchOS. These constants encode that
/// constraint so it can be validated by tests.
///
/// **Crash reference:** F5230ADA, D9447DC9 — both CAROUSEL watchdog
/// kills with "Exhausted wall time allowance of 15.00 seconds."
enum WatchBackgroundSessionConfig {
    /// Maximum wall-time the CAROUSEL watchdog allows for background URL session tasks.
    static let watchdogLimit: TimeInterval = 15.0

    /// Safety timeout for background URL session tasks.
    /// Must be strictly less than `watchdogLimit`.
    ///
    /// Set to 10.0 — safely under the 15s CAROUSEL watchdog limit,
    /// with 5s margin for URLSession event delivery and cleanup.
    static let safetyTimeout: TimeInterval = 10.0

    /// Maximum wall-time budget for background app refresh tasks.
    static let backgroundRefreshBudget: TimeInterval = 15.0

    /// Safety timeout for background refresh handler completion.
    /// Must be strictly less than `backgroundRefreshBudget`.
    static let backgroundRefreshTimeout: TimeInterval = 10.0
}

/// Enforces the correct ordering for background URL session handling:
/// 1. Set completion handler  (markHandlerSet)
/// 2. Reconnect session       (canReconnect becomes true)
/// 3. Signal completion        (markCompleted — fires exactly once)
///
/// This prevents the race condition where `urlSessionDidFinishEvents`
/// fires before the completion handler is set.
struct BackgroundSessionSequencer {
    private var handlerSet = false
    private var completed = false

    /// Whether the session can be reconnected (handler must be set first).
    var canReconnect: Bool { handlerSet }

    /// Mark that the completion handler has been set.
    mutating func markHandlerSet() {
        handlerSet = true
    }

    /// Attempt to fire the completion callback. Only fires once.
    mutating func markCompleted(action: () -> Void) {
        guard !completed else { return }
        completed = true
        action()
    }

    /// Reset for the next background task invocation.
    mutating func reset() {
        handlerSet = false
        completed = false
    }
}

/// Debounces UserDefaults persistence writes on watchOS.
///
/// On watchOS, synchronous JSON encoding + UserDefaults writes on the main
/// thread block the run loop. When queue updates arrive rapidly from the
/// iPhone, each one triggers saveEpisodes() → JSON encode → UserDefaults write.
/// This throttle ensures saves are coalesced within a debounce window.
struct WatchPersistenceThrottle {
    private var lastSaveTime: Date?

    /// Minimum interval between persistence writes.
    static let debounceInterval: TimeInterval = 0.5

    /// Whether the save should be deferred (another save happened recently).
    func shouldDeferSave() -> Bool {
        guard let last = lastSaveTime else { return false }
        return Date().timeIntervalSince(last) < Self.debounceInterval
    }

    /// Record that a save was performed.
    mutating func recordSave() {
        lastSaveTime = Date()
    }

    /// Test helper: override the last save timestamp.
    mutating func overrideLastSaveTime(_ date: Date) {
        lastSaveTime = date
    }

    /// Reset the throttle (e.g., on app termination).
    mutating func reset() {
        lastSaveTime = nil
    }
}

/// Tracks download stall timer lifecycle across background/foreground transitions.
///
/// Problem: Stall timers use `lastBytesReceived` timestamps to detect stalled downloads.
/// When the app is suspended, time passes but no bytes are received. On resume, every
/// active download appears "stalled" because `Date().timeIntervalSince(lastReceived)` is
/// huge — causing immediate false cancellations.
///
/// Fix: Suspend timers on background entry, reset `lastBytesReceived` on foreground resume.
struct WatchStallTimerLifecycle {
    
    /// Whether stall timers are currently active.
    private(set) var isActive: Bool = true
    
    /// Called when the app enters the background.
    /// Stall timers should be invalidated to prevent false stall detection on resume.
    mutating func suspend() {
        isActive = false
    }
    
    /// Called when the app returns to the foreground.
    /// Stall timers should be restarted with fresh timestamps.
    mutating func resume() {
        isActive = true
    }
}


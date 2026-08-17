import Foundation

/// Decides which iOS suspension-defense behaviors apply at runtime.
///
/// The 0xDEAD10CC / 0x8BADF00D defenses — most importantly *cancelling in-flight
/// sync* on `scenePhase == .background` — exist because on a real iOS device,
/// `.background` is the last beat before the process is suspended:
///   - a SQLite write that straddles suspension is killed with `0xDEAD10CC`
///     (the store lives in the app-group container), and
///   - a heavy save that blocks the 5-second termination watchdog is killed
///     with `0x8BADF00D`.
///
/// The same binary also runs as a "Designed for iPad" app on Apple Silicon Macs
/// (`ProcessInfo.processInfo.isiOSAppOnMac == true`). There, `scenePhase` flips
/// to `.background` whenever the window merely loses key focus — e.g. the user
/// switching to a browser to confirm a sync landed. macOS never suspension-kills
/// a process for holding a SQLite lock (it App-Naps / petrifies and resumes), so
/// cancelling sync there is all cost and no benefit: the playback reconcile is a
/// LATE sync step, so an early cancel means the Mac never adopts the server's
/// now-playing / queue. That is the "Mac stays stale" handoff bug.
///
/// This type isolates that runtime decision behind a pure function so it is unit
/// testable without actually running on a Mac (the `.background` scenePhase
/// handler that consumes it lives in a SwiftUI `Scene` and cannot be exercised
/// directly).
enum SyncLifecyclePolicy {

    /// Whether a `scenePhase == .background` transition should cancel in-flight
    /// sync work.
    ///
    /// - Returns: `true` on a real iOS device (suspension is imminent — the
    ///   in-flight sync *must* be cancelled), `false` on the iOS-app-on-Mac
    ///   (no suspension kill; cancelling only starves the reconcile).
    /// - Parameter isiOSAppOnMac: pass `ProcessInfo.processInfo.isiOSAppOnMac`
    ///   at the call site; injected here so the decision is testable.
    static func cancelsInFlightSyncOnBackground(isiOSAppOnMac: Bool) -> Bool {
        !isiOSAppOnMac
    }

    /// The minimum interval between automatic `scenePhase == .active` foreground
    /// syncs (the debounce that `BackgroundRefreshService.shouldPerformForegroundSync`
    /// enforces).
    ///
    /// On a real iOS device, `.active` fires when the user *opens the app* — a
    /// naturally-spaced event — so a 5-minute debounce avoids redundant syncs on
    /// rapid foreground/background flaps (e.g. answering a notification) without
    /// hurting freshness.
    ///
    /// On the iOS-app-on-Mac, `.active` fires every time the window regains key
    /// focus (clicking back from the browser, Cmd-Tab, returning to the app to
    /// check that a handoff landed) — potentially many times a minute. Applying
    /// the iOS 5-minute debounce there means switching from the iPhone to the Mac
    /// window does NOT pull the iPhone's just-changed now-playing / queue: the
    /// Mac silently stays stale until the debounce expires or the user manually
    /// pull-to-refreshes. The product contract is "whatever played most recently
    /// follows to the device I switch to," so on Mac we use a tiny debounce — just
    /// enough to coalesce a burst of duplicate focus events. Sync storms are not a
    /// concern: `refreshAndSync` is single-flight (a second caller joins the
    /// in-flight task), and macOS has no suspension-kill / background-budget cost.
    static func foregroundSyncDebounceInterval(isiOSAppOnMac: Bool) -> TimeInterval {
        isiOSAppOnMac ? macForegroundSyncDebounce : iOSForegroundSyncDebounce
    }

    /// Real-iOS debounce: app-open cadence, generous.
    static let iOSForegroundSyncDebounce: TimeInterval = 5 * 60

    /// iOS-app-on-Mac debounce: only coalesces duplicate focus events so a
    /// window refocus pulls fresh server state effectively immediately.
    static let macForegroundSyncDebounce: TimeInterval = 2
}

import SwiftUI
import WatchKit
import os

@main
struct YourPodsWatch_Watch_AppApp: App {
    /// Singleton references — NOT @StateObject — because both managers must
    /// survive SwiftUI App struct recreation during watchOS background wakes.
    /// @StateObject creates new instances each time, but WCSession.delegate
    /// still points to the old WatchSessionManager → split-brain where the
    /// new UI never receives data and appears frozen.
    /// Same pattern as BackgroundRefreshManager (see comment below).
    private let sessionManager = WatchSessionManager.shared
    private let audioManager = WatchAudioManager.shared
    /// Plain reference — not @StateObject — because BackgroundRefreshManager is a
    /// singleton. @StateObject + singleton causes undefined lifecycle behavior when
    /// watchOS relaunches the app for background tasks.
    private let backgroundRefresh = BackgroundRefreshManager.shared

    /// Whether persisted data has already been loaded in this process lifetime.
    /// Guards against redundant loads during background wakes (onAppear fires again).
    @State private var hasLoadedPersistedData = false
    
    /// Observe scene phase transitions to refresh state on foreground resume.
    /// CAROUSEL FIX: Without this, applicationContext that arrived during
    /// suspension is never processed → stale UI → appears frozen.
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .environmentObject(audioManager)
                .onAppear {
                    WatchDiagnosticLog.shared.log("APP_APPEAR")
                    // Wire the audio manager's session manager reference
                    audioManager.sessionManager = sessionManager
                    // CRASH FIX: Activate WCSession and register observers HERE,
                    // not in init(). During init(), SwiftUI's observation infra
                    // isn't ready — WCSession can deliver pending data that mutates
                    // @Published properties on an un-wired publisher → crash.
                    sessionManager.activate()
                    // CAROUSEL FIX: Load persisted data only once per process.
                    // Without this guard, background wakes re-decode large JSON
                    // payloads, adding main-thread work during the critical
                    // background launch window.
                    if !hasLoadedPersistedData {
                        hasLoadedPersistedData = true
                        sessionManager.loadPersistedData()
                    }
                    // Schedule first background refresh on launch
                    backgroundRefresh.scheduleNextRefresh()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    WatchDiagnosticLog.shared.log("SCENE_PHASE_\(newPhase)")
                    if newPhase == .active {
                        // CAROUSEL FIX: Re-read receivedApplicationContext on
                        // foreground resume. The delegate callback fires once at
                        // delivery time — if we were suspended, the @Published
                        // properties were never updated → stale/frozen UI.
                        sessionManager.refreshFromApplicationContext()
                        backgroundRefresh.scheduleNextRefresh()
                    }
                }
        }

        .backgroundTask(.appRefresh(BackgroundRefreshManager.refreshTaskId)) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    // Cold background launch: onAppear has NOT run. activate() is
                    // idempotent — make sure WCSession is live before refreshing.
                    WatchSessionManager.shared.activate()
                    BackgroundRefreshManager.shared.handleRefresh {
                        continuation.resume()
                    }
                }
            }
        }
        .backgroundTask(.urlSession(WatchDownloadManager.backgroundSessionId)) {
            // CAROUSEL WATCHDOG FIX (crashes F5230ADA, D9447DC9)
            // Two bugs fixed:
            // 1. Handler must be set BEFORE reconnect — urlSessionDidFinishEvents
            //    can fire immediately after reconnect, and if the handler is nil,
            //    the continuation is never resumed → watchdog kill.
            // 2. Timeout must be < 15s CAROUSEL limit (was 30s → guaranteed kill).
            
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumer = OnceResumer(continuation: continuation)
                
                // 1. Set handler FIRST — before any events can be delivered
                WatchDownloadManager.backgroundSessionCompletionHandler = {
                    resumer.resume()
                }
                
                // 2. NOW reconnect — if events are already pending, the handler
                //    will fire on the next main run loop iteration
                DispatchQueue.main.async {
                    WatchDownloadManager.shared.reconnectBackgroundSession()
                }
                
                // 3. Safety timeout: 10s is safely under the 15-second CAROUSEL
                //    watchdog. Previous value of 30s EXCEEDED the limit.
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    resumer.resume()
                }
            }
            // Clear the handler in case timeout won
            WatchDownloadManager.backgroundSessionCompletionHandler = nil
        }
    }
}

// MARK: - Once-Only Continuation Guard

/// Ensures a `CheckedContinuation` is resumed exactly once, even when
/// multiple code paths (completion handler + timeout) race to call it.
/// Uses `OSAllocatedUnfairLock` for thread-safe single-fire semantics.
private final class OnceResumer: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>
    
    init(continuation: CheckedContinuation<Void, Never>) {
        state = OSAllocatedUnfairLock(initialState: continuation)
    }
    
    func resume() {
        let cont = state.withLock { stored -> CheckedContinuation<Void, Never>? in
            let c = stored
            stored = nil
            return c
        }
        cont?.resume()
    }
}

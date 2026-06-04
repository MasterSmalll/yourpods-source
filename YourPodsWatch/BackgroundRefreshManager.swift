import Foundation
import WatchKit
import WatchConnectivity
import Combine
import os

/// Manages watchOS background app refresh tasks.
///
/// Schedules periodic `WKApplicationRefreshBackgroundTask` to keep the
/// watch app's queue data fresh by reading the latest application context
/// from WatchConnectivity.
class BackgroundRefreshManager: ObservableObject {
    static let shared = BackgroundRefreshManager()
    
    /// The background refresh task identifier.
    static let refreshTaskId = "com.asecretcompany.yourpods.watch.refresh"
    
    /// Minimum interval between refreshes (15 minutes).
    private let refreshInterval: TimeInterval = 15 * 60
    
    private let logger = Logger(subsystem: "com.yourpods", category: "WatchBackgroundRefresh")
    
    /// CAROUSEL FIX: Guard against overlapping refresh handlers.
    /// If the system delivers multiple background wakes before the previous one
    /// completes, processing both would double the main-thread work.
    private var isProcessing = false
    
    private init() {}
    
    // MARK: - Scheduling
    
    /// Schedule the next background refresh.
    /// Call on app launch and after each completed refresh.
    func scheduleNextRefresh() {
        let preferredDate = Date(timeIntervalSinceNow: refreshInterval)
        
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferredDate,
            userInfo: nil
        ) { [self] error in
            if let error = error {
                logger.error("Failed to schedule: \(error.localizedDescription)")
            } else {
                logger.debug("Scheduled next refresh for \(preferredDate)")
            }
        }
    }
    
    // MARK: - Handling
    
    /// Handle a background refresh task.
    /// Reads the latest application context from WatchConnectivity.
    ///
    /// IMPORTANT: completion() must be called exactly once, AFTER all processing
    /// is done. Calling it too early causes queue updates to arrive during
    /// app suspension → CAROUSEL watchdog kill.
    func handleRefresh(completion: @escaping () -> Void) {
        // Guard against overlapping refresh handlers
        guard !isProcessing else {
            logger.warning("Refresh already in progress — skipping")
            completion()
            return
        }
        isProcessing = true
        logger.info("Handling background refresh")
        
        guard WCSession.default.activationState == .activated else {
            logger.warning("WCSession not activated, skipping")
            isProcessing = false
            scheduleNextRefresh()
            completion()
            return
        }
        
        // Read the latest application context (queue data from iPhone)
        let context = WCSession.default.receivedApplicationContext
        
        if let queue = context["queue"] as? [[String: Any]] {
            logger.info("Refreshed queue with \(queue.count) items from application context")
            
            // Post notification so WatchSessionManager can process the update
            NotificationCenter.default.post(
                name: .backgroundQueueRefresh,
                object: nil,
                userInfo: ["queue": queue]
            )
        } else {
            logger.debug("No queue data in application context")
        }
        
        // Try to request fresh data from iPhone if reachable.
        // Wait for the reply before signaling completion — otherwise the reply
        // arrives during suspension and triggers CAROUSEL watchdog kills.
        if WCSession.default.isReachable {
            // Once-only guard: completion must fire exactly once
            // (either reply, error, or timeout — whichever comes first).
            var completionFired = false
            let fireOnce: () -> Void = { [self] in
                guard !completionFired else { return }
                completionFired = true
                isProcessing = false
                scheduleNextRefresh()
                completion()
            }
            
            WCSession.default.sendMessage(
                ["command": "refresh_queue"],
                replyHandler: { [self] reply in
                    logger.info("Received fresh data from iPhone")
                    DispatchQueue.main.async { fireOnce() }
                },
                errorHandler: { [self] error in
                    logger.error("Failed to reach iPhone: \(error.localizedDescription)")
                    DispatchQueue.main.async { fireOnce() }
                }
            )
            
            // Safety timeout: 10s is under the watchOS background budget.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                fireOnce()
            }
        } else {
            // iPhone not reachable — complete immediately
            isProcessing = false
            scheduleNextRefresh()
            completion()
        }
    }
}

// MARK: - Notification Name
extension Notification.Name {
    static let backgroundQueueRefresh = Notification.Name("backgroundQueueRefresh")
}

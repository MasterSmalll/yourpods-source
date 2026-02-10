import Foundation
import WatchKit
import WatchConnectivity
import Combine

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
    
    private init() {}
    
    // MARK: - Scheduling
    
    /// Schedule the next background refresh.
    /// Call on app launch and after each completed refresh.
    func scheduleNextRefresh() {
        let preferredDate = Date(timeIntervalSinceNow: refreshInterval)
        
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferredDate,
            userInfo: nil
        ) { error in
            if let error = error {
                print("[WatchBackgroundRefresh] Failed to schedule: \(error.localizedDescription)")
            } else {
                print("[WatchBackgroundRefresh] Scheduled next refresh for \(preferredDate)")
            }
        }
    }
    
    // MARK: - Handling
    
    /// Handle a background refresh task.
    /// Reads the latest application context from WatchConnectivity.
    func handleRefresh(completion: @escaping () -> Void) {
        print("[WatchBackgroundRefresh] Handling background refresh")
        
        guard WCSession.default.activationState == .activated else {
            print("[WatchBackgroundRefresh] WCSession not activated, skipping")
            scheduleNextRefresh()
            completion()
            return
        }
        
        // Read the latest application context (queue data from iPhone)
        let context = WCSession.default.receivedApplicationContext
        
        if let queue = context["queue"] as? [[String: Any]] {
            print("[WatchBackgroundRefresh] Refreshed queue with \(queue.count) items from application context")
            
            // Post notification so WatchSessionManager can process the update
            NotificationCenter.default.post(
                name: .backgroundQueueRefresh,
                object: nil,
                userInfo: ["queue": queue]
            )
        } else {
            print("[WatchBackgroundRefresh] No queue data in application context")
        }
        
        // Try to request fresh data from iPhone if reachable
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(
                ["command": "refresh_queue"],
                replyHandler: { reply in
                    print("[WatchBackgroundRefresh] Received fresh data from iPhone")
                },
                errorHandler: { error in
                    print("[WatchBackgroundRefresh] Failed to reach iPhone: \(error.localizedDescription)")
                }
            )
        }
        
        // Schedule next refresh
        scheduleNextRefresh()
        completion()
    }
}

// MARK: - Notification Name
extension Notification.Name {
    static let backgroundQueueRefresh = Notification.Name("backgroundQueueRefresh")
}

import Foundation
import os
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Posts local notifications when new podcast episodes are discovered during background sync.
///
/// Key design decisions:
/// - Notifications post LAST in the sync pipeline (after sync, auto-queue, auto-download)
///   so background task time is prioritized for data operations.
/// - Grouped by podcast using `threadIdentifier` so iOS collapses per-podcast.
/// - Foreground-suppressed: no notifications when the app is actively visible.
/// - Default OFF: users must opt in (privacy-first).
///
/// Usage: Called from `PodcastManager.processNewEpisodes()` after all data operations.
final class NewEpisodeNotificationService: @unchecked Sendable {
    static let shared = NewEpisodeNotificationService()
    
    private let logger = Logger(subsystem: "com.yourpods", category: "Notifications")
    static let categoryIdentifier = "NEW_EPISODE"
    
    /// Episodes published more than this many seconds ago are considered "stale"
    /// and will trigger notifications even when the app is in the foreground.
    /// This prevents the scenario where a podcast publishes at 2pm, iOS doesn't
    /// run a background refresh until overnight, and the user opens the app at 6pm —
    /// in that case, the episode is 4 hours old and the user would never be notified.
    /// Default: 30 minutes (1800 seconds).
    static let foregroundStaleThreshold: TimeInterval = 30 * 60
    
    /// Injected for testing. Defaults to the real notification center.
    var notificationCenter: NotificationCenterProtocol = UNUserNotificationCenterWrapper()
    
    /// Injected for testing. Returns the current app state.
    /// Must be safe to call from any thread — production impl uses @MainActor.
    var applicationStateProvider: @Sendable () async -> ApplicationState = {
        #if os(iOS)
        if NSClassFromString("XCTestCase") != nil {
            return .background
        }
        return await MainActor.run {
            UIApplication.shared.applicationState == .active ? .active : .background
        }
        #else
        return .background
        #endif
    }
    
    /// Request notification permission from the user.
    /// Returns `true` if permission was granted.
    func requestPermissionIfNeeded() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if granted {
                logger.info("Notification permission granted")
            } else {
                logger.info("Notification permission denied")
            }
            return granted
        } catch {
            logger.error("Failed to request notification permission: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Register notification categories with the system.
    func registerCategories() {
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        logger.debug("Registered notification category: \(Self.categoryIdentifier)")
    }
    
    /// Post local notifications for newly discovered episodes.
    ///
    /// Groups episodes by podcast and posts one notification per podcast.
    /// Skips posting if:
    /// - The episode list is empty
    /// - The app is in the foreground
    /// - Notification authorization is not granted
    ///
    /// This method is designed to be called at the VERY END of `processNewEpisodes()`,
    /// after auto-queue and auto-download, so background task time is prioritized
    /// for data operations.
    ///
    /// - Parameter episodes: New episodes discovered during the current sync cycle.
    func postNewEpisodeNotifications(_ episodes: [Episode]) async {
        // Guard: nothing to notify about
        guard !episodes.isEmpty else {
            logger.debug("Notification: skipped — no episodes to notify about")
            return
        }
        
        logger.info("Notification: processing \(episodes.count) episode(s) for notification")
        
        // Determine which episodes to notify about based on app state.
        // - Background: notify for ALL new episodes (unchanged behavior).
        // - Foreground: only notify for "stale" episodes — those published more than
        //   `foregroundStaleThreshold` ago. This prevents notification spam when the user
        //   opens the app and a foreground sync fires, while still alerting them about
        //   episodes they missed (e.g., published hours ago, no background refresh ran).
        let appState = await applicationStateProvider()
        let episodesToNotify: [Episode]
        
        if appState == .active {
            let threshold = Self.foregroundStaleThreshold
            let now = Date()
            episodesToNotify = episodes.filter { episode in
                guard let pubDate = episode.pubDate else {
                    // No pubDate — treat as fresh, suppress in foreground
                    logger.debug("Notification: skipping '\(episode.title)' — no pubDate, treating as fresh")
                    return false
                }
                let age = now.timeIntervalSince(pubDate)
                let isStale = age > threshold
                if !isStale {
                    logger.debug("Notification: skipping '\(episode.title)' — published \(Int(age))s ago (threshold: \(Int(threshold))s)")
                }
                return isStale
            }
            
            guard !episodesToNotify.isEmpty else {
                logger.info("Notification: skipped — app is in foreground and all \(episodes.count) episode(s) are fresh (published within \(Int(threshold / 60)) min). This is expected during manual Refresh & Sync.")
                return
            }
            
            logger.info("Notification: foreground — \(episodesToNotify.count)/\(episodes.count) episode(s) are stale, posting notifications for missed episodes")
        } else {
            episodesToNotify = episodes
        }
        
        // Guard: check notification authorization before attempting to post.
        // UNUserNotificationCenter.add() silently drops notifications when
        // authorization is not granted — it does NOT throw an error.
        let isAuthorized = await notificationCenter.isAuthorized()
        guard isAuthorized else {
            logger.warning("Notification: skipped — authorization not granted. User must grant permission in Settings → YourPods → Notifications, or enable the global toggle in Settings → Background Refresh → New Episode Notifications.")
            return
        }
        
        logger.info("Notification: authorized, posting for \(episodesToNotify.count) episode(s)")
        
        // Group episodes by their parent podcast
        let grouped = Dictionary(grouping: episodesToNotify) { episode -> String in
            episode.podcast?.url ?? "unknown"
        }
        
        for (podcastUrl, podcastEpisodes) in grouped {
            let podcastTitle = podcastEpisodes.first?.podcast?.title ?? "Podcast"
            
            let content = UNMutableNotificationContent()
            content.title = podcastTitle
            content.threadIdentifier = podcastUrl
            content.categoryIdentifier = Self.categoryIdentifier
            content.sound = .default
            
            if podcastEpisodes.count == 1, let episode = podcastEpisodes.first {
                content.body = episode.title
            } else {
                content.body = "\(podcastEpisodes.count) new episodes"
            }
            
            let requestId = "new-episode-\(podcastUrl)-\(Date().timeIntervalSince1970)"
            let request = UNNotificationRequest(
                identifier: requestId,
                content: content,
                trigger: nil  // Deliver immediately
            )
            
            do {
                try await notificationCenter.add(request)
                logger.info("Notification: ✅ posted for '\(podcastTitle)': \(content.body)")
            } catch {
                logger.error("Notification: ❌ failed to post for '\(podcastTitle)': \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Abstractions for Testing

/// Represents application foreground/background state.
enum ApplicationState {
    case active
    case background
}

/// Protocol wrapping `UNUserNotificationCenter` for testability.
protocol NotificationCenterProtocol: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func isAuthorized() async -> Bool
}

/// Production wrapper around `UNUserNotificationCenter`.
final class UNUserNotificationCenterWrapper: NotificationCenterProtocol {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
    
    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }
    
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
    
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
}

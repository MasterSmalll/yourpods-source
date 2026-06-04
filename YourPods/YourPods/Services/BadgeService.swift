import Foundation
import os
import UserNotifications

/// Manages the app icon badge count showing unplayed episodes.
///
/// Badge count = total unplayed episodes across all subscriptions.
/// Independent from notifications — users can enable badges, notifications, or both.
///
/// Integration points:
/// - `processNewEpisodes()` — update after new episodes discovered
/// - `scenePhase == .active` — recalculate on foreground
/// - Episode marked as played — decrement
///
/// iOS-only: macOS doesn't support numbered app icon badges in the same way.
@MainActor
final class BadgeService {
    static let shared = BadgeService()
    
    private let logger = Logger(subsystem: "com.yourpods", category: "BadgeService")
    
    /// Injected for testing. Defaults to the real notification center.
    var notificationCenter: BadgeNotificationCenterProtocol = BadgeNotificationCenterWrapper()
    
    weak var podcastManager: PodcastManager?
    weak var settingsManager: SettingsManager?
    
    /// Update the app icon badge count based on the current unplayed episode count.
    ///
    /// - When `appBadgeEnabled` is true: badge = total unplayed episodes
    /// - When `appBadgeEnabled` is false: badge = 0 (cleared)
    func updateBadgeCount() async {
        guard let settingsManager else {
            logger.warning("BadgeService: settingsManager not available — clearing badge")
            await setBadge(0)
            return
        }
        
        guard settingsManager.appBadgeEnabled else {
            logger.debug("BadgeService: badge disabled — clearing")
            await setBadge(0)
            return
        }
        
        let count = calculateUnplayedCount()
        logger.info("BadgeService: updating badge to \(count) unplayed episodes")
        await setBadge(count)
    }
    
    /// Calculate the number of unplayed episodes across all subscriptions.
    func calculateUnplayedCount() -> Int {
        guard let podcastManager else {
            logger.debug("BadgeService: podcastManager not available — returning 0")
            return 0
        }
        
        var total = 0
        for podcast in podcastManager.subscriptions {
            for episode in podcast.episodes {
                if !episode.isPlayed && !episode.isStale {
                    total += 1
                }
            }
        }
        return total
    }
    
    // MARK: - Private
    
    private func setBadge(_ count: Int) async {
        do {
            try await notificationCenter.setBadgeCount(count)
        } catch {
            logger.error("BadgeService: failed to set badge count: \(error.localizedDescription)")
        }
    }
}

// MARK: - Badge Notification Center Protocol

/// Protocol wrapping badge-setting capability for testability.
protocol BadgeNotificationCenterProtocol: Sendable {
    func setBadgeCount(_ count: Int) async throws
}

/// Production wrapper using UNUserNotificationCenter.
final class BadgeNotificationCenterWrapper: BadgeNotificationCenterProtocol {
    func setBadgeCount(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

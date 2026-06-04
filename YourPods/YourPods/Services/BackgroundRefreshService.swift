import Foundation
#if os(iOS)
import BackgroundTasks
#endif
import os

/// Background refresh service using BGTaskScheduler.
/// Runs in the same memory space as the app — can directly update the audio queue.
final class BackgroundRefreshService {
    static let shared = BackgroundRefreshService()
    #if os(iOS)
    static let refreshTaskId = "com.asecretcompany.yourpods.refresh"
    #endif
    
    private let logger = Logger(subsystem: "com.yourpods", category: "BackgroundRefresh")
    
    var podcastManager: PodcastManager?
    var audioManager: AudioManager?
    var settingsManager: SettingsManager?
    var downloadManager: DownloadManager?
    var networkMonitor: NetworkMonitoring?
    var playerManager: PlayerManager?
    
    /// Tracks the last time a foreground sync ran, for debounce logic.
    var lastForegroundSyncDate: Date?
    
    /// Minimum interval between foreground syncs (5 minutes).
    private static let foregroundSyncInterval: TimeInterval = 5 * 60
    
    /// Whether a foreground sync should run based on the debounce interval.
    func shouldPerformForegroundSync() -> Bool {
        guard let lastSync = lastForegroundSyncDate else {
            // Never synced before — should sync
            return true
        }
        return Date().timeIntervalSince(lastSync) >= Self.foregroundSyncInterval
    }
    
    /// Compute the refresh interval in seconds from the user's setting.
    /// Returns the `backgroundRefreshInterval` (in minutes) converted to seconds.
    /// Falls back to 60 minutes if `settingsManager` is nil.
    func computeRefreshInterval() -> TimeInterval {
        let intervalMinutes = settingsManager?.backgroundRefreshInterval ?? 60
        return TimeInterval(intervalMinutes) * 60
    }
    
    /// Whether the background task should run a sync.
    /// Checks the user's `backgroundRefreshEnabled` setting.
    /// Returns `false` when `settingsManager` is nil (safety guard).
    func shouldPerformBackgroundSync() -> Bool {
        guard let settingsManager else {
            logger.warning("shouldPerformBackgroundSync: settingsManager not available")
            return false
        }
        return settingsManager.backgroundRefreshEnabled
    }
    
    /// Perform a foreground sync cycle.
    /// Always runs regardless of `backgroundRefreshEnabled` — the user explicitly
    /// opened the app, so they expect fresh data.
    func performForegroundSync() async {
        guard let podcastManager else {
            logger.warning("performForegroundSync: podcastManager not available")
            return
        }
        guard let playerManager else {
            logger.warning("performForegroundSync: playerManager not available")
            return
        }
        guard let downloadManager else {
            logger.warning("performForegroundSync: downloadManager not available")
            return
        }
        guard let settingsManager else {
            logger.warning("performForegroundSync: settingsManager not available")
            return
        }
        
        logger.info("performForegroundSync: starting foreground sync cycle")
        
        let userStrategy = settingsManager.syncConflictStrategy
        _ = await podcastManager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: userStrategy
        )
        
        lastForegroundSyncDate = Date()
        logger.info("performForegroundSync: complete")
    }
    
    /// Perform a background sync cycle (subscription sync + feed refresh + episode actions).
    /// Only runs if the user has background refresh enabled.
    /// Called by `handleRefresh()` (the `BGAppRefreshTask` handler).
    func performSync() async {
        // Gate: respect the user's background refresh toggle
        guard shouldPerformBackgroundSync() else {
            logger.info("performSync: skipped — backgroundRefreshEnabled is false")
            return
        }
        
        guard let podcastManager else {
            logger.warning("performSync: podcastManager not available")
            return
        }
        guard let playerManager else {
            logger.warning("performSync: playerManager not available")
            return
        }
        guard let downloadManager else {
            logger.warning("performSync: downloadManager not available")
            return
        }
        guard let settingsManager else {
            logger.warning("performSync: settingsManager not available")
            return
        }
        
        logger.info("performSync: starting background sync cycle")
        
        // Honor the user's conflict strategy preference.
        // In background context, .ask can't show UI — fall back to .deviceWins
        // (preserves local positions; conflicts surface on next foreground sync).
        let userStrategy = settingsManager.syncConflictStrategy
        let backgroundSafeStrategy: SyncStrategy = (userStrategy == .ask) ? .deviceWins : userStrategy
        
        _ = await podcastManager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: backgroundSafeStrategy
        )
        
        lastForegroundSyncDate = Date()
        logger.info("performSync: background sync cycle complete")
    }
    
    func registerTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleRefresh(task: task as! BGAppRefreshTask)
        }
        #endif
    }
    
    func scheduleRefresh() {
        #if os(iOS)
        // Don't schedule if the user has disabled background refresh
        guard shouldPerformBackgroundSync() else {
            logger.info("scheduleRefresh: skipped — backgroundRefreshEnabled is false")
            return
        }
        
        let interval = computeRefreshInterval()
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Background refresh scheduled with interval: \(Int(interval / 60)) minutes")
        } catch {
            logger.error("Failed to schedule refresh: \(error.localizedDescription)")
        }
        #endif
    }
    
    /// Cancel all pending background refresh tasks.
    /// Called when the user disables background refresh.
    func cancelScheduledRefresh() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskId)
        logger.info("Background refresh cancelled")
        #endif
    }
    
    #if os(iOS)
    private func handleRefresh(task: BGAppRefreshTask) {
        // Check if the user has disabled background refresh
        guard shouldPerformBackgroundSync() else {
            logger.info("Background refresh: skipped — user has disabled background refresh")
            task.setTaskCompleted(success: true)
            // Don't schedule the next refresh — it's disabled
            return
        }
        
        // Schedule the next refresh (uses the user's configured interval)
        scheduleRefresh()
        
        let refreshTask = Task {
            guard podcastManager != nil else {
                logger.warning("Background refresh: podcastManager not available")
                task.setTaskCompleted(success: false)
                return
            }
            
            // Perform a full sync cycle (feeds + subscriptions + episode actions + queue)
            await performSync()
            
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            refreshTask.cancel()
        }
    }
    #endif
}

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
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Background refresh scheduled")
        } catch {
            logger.error("Failed to schedule refresh: \(error.localizedDescription)")
        }
        #endif
    }
    
    #if os(iOS)
    private func handleRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh
        scheduleRefresh()
        
        let refreshTask = Task {
            guard let podcastManager else {
                task.setTaskCompleted(success: false)
                return
            }
            
            do {
                let newEpisodes = await podcastManager.refreshAllFeeds()
                
                // Auto-queue new episodes directly into the active AVQueuePlayer
                // This is the KEY advantage over Flutter: same memory space!
                if let audioManager, !newEpisodes.isEmpty {
                    let globalDefault = self.settingsManager?.defaultAutoQueueMode ?? .off
                    let autoQueueItems = newEpisodes.compactMap { episode -> QueueItem? in
                        guard let podcast = episode.podcast else { return nil }
                        // Skip already-played or interacted episodes
                        guard !episode.isPlayed, !episode.isInteracted else { return nil }
                        // Must have audio
                        guard episode.audioUrl != nil else { return nil }
                        let effectiveMode = podcast.effectiveSettings.autoQueueMode ?? globalDefault
                        guard effectiveMode != .off else { return nil }
                        return QueueItem.from(episode: episode)
                    }
                    
                    if !autoQueueItems.isEmpty {
                        logger.info("Background: auto-queueing \(autoQueueItems.count) new episodes")
                        audioManager.appendToQueue(autoQueueItems)
                    }
                }
                
                // Also auto-queue the most recent unplayed episode for each subscription.
                // Only the latest episode — future new episodes come via refreshAllFeeds().
                if let audioManager {
                    let globalDefault = self.settingsManager?.defaultAutoQueueMode ?? .off
                    let existingItems: [QueueItem] = await MainActor.run {
                        var items: [QueueItem] = []
                        for podcast in podcastManager.subscriptions {
                            let candidates = podcastManager.getAutoQueueCandidates(for: podcast, globalDefault: globalDefault)
                            // Only take the most recent (candidates are sorted newest-first)
                            if let mostRecent = candidates.first,
                               let item = QueueItem.from(episode: mostRecent) {
                                items.append(item)
                            }
                        }
                        return items
                    }
                    if !existingItems.isEmpty {
                        logger.info("Background: auto-queueing \(existingItems.count) latest episodes")
                        audioManager.appendToQueue(existingItems)
                    }
                }
                
                // P1: gPodder background sync — push local actions and pull server state
                do {
                    let _ = try await podcastManager.syncEpisodeActions()
                    logger.info("Background: gPodder sync complete")
                } catch {
                    logger.warning("Background: gPodder sync failed: \(error.localizedDescription)")
                }
                
                task.setTaskCompleted(success: true)
            }
        }
        
        task.expirationHandler = {
            refreshTask.cancel()
        }
    }
    #endif
}

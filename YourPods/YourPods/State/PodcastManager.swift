import Foundation
import SwiftData
import os

/// Manages podcast subscriptions, episode data, feed refreshing, and gPodder sync.
/// Native port of podcast_provider.dart.
@Observable
@MainActor
final class PodcastManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "PodcastManager")
    
    var subscriptions: [Podcast] = []
    var isRefreshing = false
    
    private let modelContext: ModelContext
    private let rssService = RSSService()
    private var gpodderClient: GPodderClient?
    private var deviceId = "swift-client"
    
    /// Map of episodeGuid → latest EpisodeAction (for sync lookups)
    private(set) var actionMap: [String: EpisodeAction] = [:]
    
    /// Interacted episode GUIDs per podcast URL (marks episodes as "seen")
    private var interactedKeys: [String: Set<String>] = [:]
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadSubscriptions()
    }
    
    func setGPodderClient(_ client: GPodderClient?, deviceId: String) {
        self.gpodderClient = client
        self.deviceId = deviceId
    }
    
    // MARK: - Profile-scoped Subscription URLs
    
    /// The currently active profile ID (read from SettingsManager's UserDefaults key).
    private var activeProfileId: String? {
        UserDefaults.standard.string(forKey: "activeProfileId")
    }
    
    /// Get the set of podcast URLs associated with a profile.
    private func subscriptionUrls(for profileId: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "subscriptionUrls_\(profileId)"),
              let urls = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return urls
    }
    
    /// Save the set of podcast URLs for a profile.
    private func saveSubscriptionUrls(_ urls: Set<String>, for profileId: String) {
        if let data = try? JSONEncoder().encode(urls) {
            UserDefaults.standard.set(data, forKey: "subscriptionUrls_\(profileId)")
        }
    }
    
    /// Associate a podcast URL with the current active profile.
    func associateWithCurrentProfile(url: String) {
        guard let profileId = activeProfileId else { return }
        var urls = subscriptionUrls(for: profileId)
        urls.insert(url)
        saveSubscriptionUrls(urls, for: profileId)
    }
    
    /// Remove a podcast URL from the current active profile.
    func disassociateFromCurrentProfile(url: String) {
        guard let profileId = activeProfileId else { return }
        var urls = subscriptionUrls(for: profileId)
        urls.remove(url)
        saveSubscriptionUrls(urls, for: profileId)
    }
    
    // MARK: - Subscriptions
    
    func loadSubscriptions() {
        do {
            let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.sortOrder)])
            let allPodcasts = try modelContext.fetch(descriptor)
            
            // Filter by active profile's subscription set
            if let profileId = activeProfileId {
                let profileUrls = subscriptionUrls(for: profileId)
                if profileUrls.isEmpty {
                    // Only adopt all existing podcasts if this is the very first profile
                    // (migration from pre-profile era). Otherwise start clean.
                    let otherProfilesExist = Self.hasOtherProfiles(excluding: profileId)
                    if !otherProfilesExist && !allPodcasts.isEmpty {
                        let allUrls = Set(allPodcasts.map(\.url))
                        saveSubscriptionUrls(allUrls, for: profileId)
                        subscriptions = allPodcasts
                    } else {
                        subscriptions = []
                    }
                } else {
                    subscriptions = allPodcasts.filter { profileUrls.contains($0.url) }
                }
            } else {
                // No active profile — show empty
                subscriptions = []
            }
        } catch {
            logger.error("Failed to load subscriptions: \(error.localizedDescription)")
        }
    }
    
    /// Reorder subscriptions — supports reordering within a filtered subset.
    func reorderSubscriptions(from source: IndexSet, to destination: Int, filteredList: [Podcast]) {
        var working = filteredList
        working.move(fromOffsets: source, toOffset: destination)
        
        // Rebuild sort order for moved items
        for (index, podcast) in working.enumerated() {
            podcast.sortOrder = index
        }
        
        try? modelContext.save()
        loadSubscriptions()
    }
    
    func addSubscription(url: String) async throws {
        // Check if already subscribed
        guard !subscriptions.contains(where: { $0.url == url }) else { return }
        
        // Fetch the feed to get metadata
        let (parsed, episodes) = try await rssService.fetchFeed(url: url)
        
        let podcast = Podcast(
            url: url,
            title: parsed.title,
            podcastDescription: parsed.description,
            logoUrl: parsed.logoUrl,
            website: parsed.website,
            author: parsed.author
        )
        podcast.sortOrder = subscriptions.count
        
        // Set markedPlayedBefore to now so we don't flood the queue with back catalog
        podcast.effectiveSettings.markedPlayedBefore = Date()
        
        modelContext.insert(podcast)
        
        // Insert episodes
        for ep in episodes {
            let episode = Episode(
                guid: ep.guid,
                title: ep.title,
                episodeDescription: ep.description,
                audioUrl: ep.audioUrl,
                pubDate: ep.pubDate,
                imageUrl: ep.imageUrl,
                durationSeconds: ep.durationSeconds,
                link: ep.link,
                chaptersUrl: ep.chaptersUrl,
                transcriptUrl: ep.transcriptUrl,
                podcast: podcast
            )
            modelContext.insert(episode)
        }
        
        try modelContext.save()
        associateWithCurrentProfile(url: url)
        loadSubscriptions()
        
        // Sync to server
        if let client = gpodderClient {
            try? await client.updateSubscriptions(deviceId: deviceId, add: [url])
        }
        
        logger.info("Subscribed to \(parsed.title) with \(episodes.count) episodes")
    }
    
    func removeSubscription(_ podcast: Podcast) async {
        let url = podcast.url
        disassociateFromCurrentProfile(url: url)
        modelContext.delete(podcast)
        try? modelContext.save()
        loadSubscriptions()
        
        if let client = gpodderClient {
            try? await client.updateSubscriptions(deviceId: deviceId, remove: [url])
        }
    }
    
    // MARK: - Feed Refresh
    
    func refreshAllFeeds() async -> [Episode] {
        isRefreshing = true
        defer { isRefreshing = false }
        
        var newEpisodes: [Episode] = []
        
        for podcast in subscriptions {
            do {
                let new = try await refreshFeed(for: podcast)
                newEpisodes.append(contentsOf: new)
            } catch {
                logger.error("Failed to refresh \(podcast.title): \(error.localizedDescription)")
            }
        }
        
        logger.info("Refreshed all feeds: \(newEpisodes.count) new episodes found")
        return newEpisodes
    }
    
    /// Refresh feeds, auto-queue new episodes, and auto-download based on per-podcast settings.
    /// This is the "Refresh & Sync" button action.
    func refreshAndSync(
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager
    ) async {
        let newEpisodes = await refreshAllFeeds()
        
        // Group new episodes by podcast URL
        let byPodcast = Dictionary(grouping: newEpisodes, by: { $0.podcastUrl ?? "" })
        
        for (podcastUrl, episodes) in byPodcast {
            guard let podcast = subscriptions.first(where: { $0.url == podcastUrl }) else { continue }
            let podSettings = podcast.effectiveSettings
            
            // Filter to only truly "new" episodes (after markedPlayedBefore)
            let markedBefore = podSettings.markedPlayedBefore
            let newOnly = episodes.filter { ep in
                guard let pubDate = ep.pubDate else { return true }
                if let markedBefore { return pubDate > markedBefore }
                return true
            }
            
            // Auto-queue
            let queueMode = podSettings.autoQueueMode ?? settingsManager.defaultAutoQueueMode
            if queueMode != .off {
                for episode in newOnly {
                    playerManager.addToQueue(episode, playNext: queueMode == .priority)
                }
            }
            
            // Auto-download
            let shouldDownload = podSettings.autoDownloadNewEpisodes ?? settingsManager.defaultAutoDownload
            if shouldDownload {
                await withTaskGroup(of: Void.self) { group in
                    for episode in newOnly {
                        if let audioUrl = episode.audioUrl, !downloadManager.isDownloaded(episode.guid) {
                            group.addTask {
                                try? await downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl)
                            }
                        }
                    }
                }
            }
        }
        
        // Sync episode actions with server
        do {
            _ = try await syncEpisodeActions()
        } catch {
            logger.error("Sync failed during refreshAndSync: \(error.localizedDescription)")
        }
    }
    
    func refreshFeed(for podcast: Podcast) async throws -> [Episode] {
        let authHeader: String? = nil  // TODO: build auth header from GPodder credentials for protected feeds
        let (parsed, parsedEpisodes) = try await rssService.fetchFeed(url: podcast.url, authHeader: authHeader)
        
        // Update podcast metadata
        podcast.title = parsed.title
        podcast.podcastDescription = parsed.description
        podcast.logoUrl = parsed.logoUrl
        podcast.website = parsed.website
        podcast.author = parsed.author
        
        // Find existing episode GUIDs
        let existingGuids = Set(podcast.episodes.map(\.guid))
        
        var newEpisodes: [Episode] = []
        for ep in parsedEpisodes where !existingGuids.contains(ep.guid) {
            let episode = Episode(
                guid: ep.guid,
                title: ep.title,
                episodeDescription: ep.description,
                audioUrl: ep.audioUrl,
                pubDate: ep.pubDate,
                imageUrl: ep.imageUrl,
                durationSeconds: ep.durationSeconds,
                link: ep.link,
                chaptersUrl: ep.chaptersUrl,
                transcriptUrl: ep.transcriptUrl,
                podcast: podcast
            )
            modelContext.insert(episode)
            newEpisodes.append(episode)
        }
        
        try modelContext.save()
        return newEpisodes
    }
    
    // MARK: - Episode Queries
    
    func getEpisodes(for podcastUrl: String) -> [Episode] {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.url == podcastUrl },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    // MARK: - Auto-Queue Candidates
    
    func getAutoQueueCandidates(for podcast: Podcast) -> [Episode] {
        let settings = podcast.effectiveSettings
        guard let mode = settings.autoQueueMode, mode != .off else { return [] }
        
        let markedBefore = settings.markedPlayedBefore
        let interacted = interactedKeys[podcast.url] ?? []
        
        return podcast.episodes.filter { episode in
            // Skip if already interacted
            guard !interacted.contains(episode.guid) else { return false }
            // Skip if published before markedPlayedBefore
            if let markedBefore, let pubDate = episode.pubDate, pubDate <= markedBefore {
                return false
            }
            // Must have audio
            return episode.audioUrl != nil
        }.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }
    
    /// Update listen progress for an episode during playback.
    /// Called periodically by PlayerManager to keep the SwiftData model in sync with audio position.
    func updateEpisodeProgress(podcastUrl: String, episodeGuid: String, position: Int) {
        guard let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
              let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }),
              episode.listenedSeconds != position else { return }
        episode.listenedSeconds = position
        try? modelContext.save()
    }
    
    /// Update episode progress by guid only (used for conflict resolution where podcastUrl is unknown).
    func updateEpisodeProgressByGuid(episodeGuid: String, position: Int) {
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }),
               episode.listenedSeconds != position {
                episode.listenedSeconds = position
                try? modelContext.save()
                return
            }
        }
    }
    
    func markEpisodeAsInteracted(_ podcastUrl: String, _ episodeGuid: String) {
        var keys = interactedKeys[podcastUrl] ?? []
        keys.insert(episodeGuid)
        interactedKeys[podcastUrl] = keys
        
        // Also update the SwiftData model so HomeView's recentEpisodes filter sees the change
        if let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
           let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }) {
            episode.isInteracted = true
            try? modelContext.save()
        }
    }
    
    /// Mark an episode as fully played (syncs with gPodder and marks as interacted).
    func markEpisodeAsPlayed(podcastUrl: String, episodeGuid: String) {
        // Mark as interacted locally
        markEpisodeAsInteracted(podcastUrl, episodeGuid)
        
        // Find the episode to get its audio URL and duration
        let podcast = subscriptions.first { $0.url == podcastUrl }
        let episode = podcast?.episodes.first { $0.guid == episodeGuid }
        
        // Update model
        episode?.isPlayed = true
        if let total = episode?.durationSeconds {
            episode?.listenedSeconds = total
        }
        try? modelContext.save()
        
        let audioUrl = episode?.audioUrl ?? ""
        let total = episode?.durationSeconds ?? 0
        
        let action = EpisodeAction(
            podcast: podcastUrl,
            episode: audioUrl,
            guid: episodeGuid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: total,
            started: 0,
            total: total,
            device: deviceId
        )
        
        Task {
            await sendEpisodeAction(action)
        }
        
        logger.info("Marked episode \(episodeGuid) as played")
    }
    
    /// Mark an episode as unplayed (resets position)
    func markEpisodeAsUnplayed(podcastUrl: String, episodeGuid: String) {
        let podcast = subscriptions.first { $0.url == podcastUrl }
        let episode = podcast?.episodes.first { $0.guid == episodeGuid }
        
        episode?.isPlayed = false
        episode?.listenedSeconds = 0
        try? modelContext.save()
        
        let audioUrl = episode?.audioUrl ?? ""
        
        let action = EpisodeAction(
            podcast: podcastUrl,
            episode: audioUrl,
            guid: episodeGuid,
            action: "new",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 0,
            started: 0,
            total: episode?.durationSeconds ?? 0,
            device: deviceId
        )
        
        Task {
            await sendEpisodeAction(action)
        }
        
        logger.info("Marked episode \(episodeGuid) as unplayed")
    }
    
    /// Mark ALL episodes for a podcast as played, with server sync.
    /// Works for any number of episodes — batches the server upload.
    func markAllEpisodesAsPlayed(for podcast: Podcast) {
        let now = Int(Date().timeIntervalSince1970)
        var actions: [EpisodeAction] = []
        
        for episode in podcast.episodes where !episode.isPlayed {
            episode.isPlayed = true
            if let total = episode.durationSeconds {
                episode.listenedSeconds = total
            }
            
            let action = EpisodeAction(
                podcast: podcast.url,
                episode: episode.audioUrl ?? "",
                guid: episode.guid,
                action: "play",
                timestamp: now,
                position: episode.durationSeconds ?? 0,
                started: 0,
                total: episode.durationSeconds ?? 0,
                device: deviceId
            )
            actions.append(action)
            actionMap[episode.guid] = action
        }
        
        try? modelContext.save()
        persistActionMap()
        
        let count = actions.count
        logger.info("Marked \(count) episodes as played for \(podcast.title)")
        
        // Batch upload to server
        guard !actions.isEmpty else { return }
        Task {
            guard let client = gpodderClient else { return }
            // Upload in batches of 50 to avoid oversized requests
            for batch in stride(from: 0, to: actions.count, by: 50) {
                let end = min(batch + 50, actions.count)
                let slice = Array(actions[batch..<end])
                try? await client.uploadEpisodeActions(slice)
            }
            logger.info("Uploaded \(count) play actions to server")
        }
    }
    
    // MARK: - gPodder Sync
    
    /// Pull subscription list from server and subscribe to any missing feeds.
    /// Also pushes any local-only subscriptions to the server.
    func syncSubscriptions() async throws {
        guard let client = gpodderClient else {
            logger.info("No gPodder client configured, skipping subscription sync")
            return
        }
        
        let profileId = activeProfileId ?? "global"
        let since = UserDefaults.standard.integer(forKey: "lastSubscriptionSync_\(profileId)")
        logger.info("Syncing subscriptions since \(since)...")
        
        let delta = try await client.getSubscriptionChanges(deviceId: deviceId, since: since)
        
        // Remove unsubscribed feeds
        for removeUrl in delta.remove {
            disassociateFromCurrentProfile(url: removeUrl)
            if let podcast = subscriptions.first(where: { $0.url == removeUrl }) {
                modelContext.delete(podcast)
                logger.info("Removed subscription: \(removeUrl)")
            }
        }
        
        // Add new subscriptions from server
        var addedCount = 0
        for feedUrl in delta.add {
            // Associate with profile even if already in SwiftData (may be from another profile)
            associateWithCurrentProfile(url: feedUrl)
            guard !subscriptions.contains(where: { $0.url == feedUrl }) else { continue }
            do {
                try await addSubscription(url: feedUrl)
                addedCount += 1
                logger.info("Added subscription from server: \(feedUrl)")
            } catch {
                logger.error("Failed to add \(feedUrl): \(error.localizedDescription)")
            }
        }
        
        // Push any local subscriptions the server doesn't know about
        // (for since == 0 full sync, delta.add is the full list)
        if since > 0 {
            let serverUrls = Set(delta.add)
            let localOnly = subscriptions.filter { !serverUrls.contains($0.url) }
            if !localOnly.isEmpty {
                let urls = localOnly.map(\.url)
                try? await client.updateSubscriptions(deviceId: deviceId, add: urls)
                logger.info("Pushed \(urls.count) local subscriptions to server")
            }
        }
        
        UserDefaults.standard.set(delta.timestamp, forKey: "lastSubscriptionSync_\(profileId)")
        try? modelContext.save()
        loadSubscriptions()
        
        logger.info("Subscription sync complete: \(addedCount) added, \(delta.remove.count) removed")
    }
    
    func syncEpisodeActions(force: Bool = true, strategy: SyncStrategy = .serverWins) async throws -> [SyncConflict] {
        guard let client = gpodderClient else {
            logger.info("No gPodder client — skipping episode action sync")
            return []
        }
        
        // When force=true, pull ALL history (since=0).
        // Otherwise use the last sync timestamp for incremental sync.
        let epProfileId = activeProfileId ?? "global"
        let since = force ? 0 : UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(epProfileId)")
        logger.info("Fetching episode actions since \(since) (force=\(force))...")
        
        let actions = try await client.getEpisodeActions(since: since)
        logger.info("Received \(actions.count) episode actions from server")
        
        var conflicts: [SyncConflict] = []
        
        for action in actions {
            let key = action.guid ?? action.episode
            let existing = actionMap[key]
            
            if let existing, let existingPos = existing.position, let newPos = action.position {
                if abs(existingPos - newPos) > 5 {
                    conflicts.append(SyncConflict(
                        episodeGuid: key,
                        episodeTitle: nil,
                        podcastTitle: nil,
                        localPosition: existingPos,
                        serverPosition: newPos,
                        serverTimestamp: action.timestamp
                    ))
                }
            }
            
            actionMap[key] = action
        }
        
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: "lastEpisodeActionSync_\(epProfileId)")
        persistActionMap()
        
        // Apply synced positions to Episode objects using the configured strategy
        let applyConflicts = applyEpisodeActions(strategy: strategy)
        
        // Merge conflicts from action map diff + apply phase
        let allConflicts = conflicts + applyConflicts
        
        let totalStored = self.actionMap.count
        logger.info("Episode action sync complete: \(actions.count) received, \(totalStored) total stored, \(allConflicts.count) conflicts")
        return allConflicts
    }
    
    /// Apply the action map to Episode model objects to update listen progress.
    /// Call after syncing, on app launch, and after subscription refresh.
    ///
    /// - Parameter strategy: How to resolve conflicts between local and server positions.
    ///   Defaults to `.serverWins` (original behavior). Pass `.deviceWins` to never go backward,
    ///   or `.ask` to collect conflicts for user resolution without overwriting.
    /// - Returns: Episodes with unresolved conflicts (only populated when strategy is `.ask`).
    @discardableResult
    func applyEpisodeActions(strategy: SyncStrategy = .serverWins) -> [SyncConflict] {
        var updatedCount = 0
        var unresolvedConflicts: [SyncConflict] = []
        
        /// Threshold in seconds — differences below this are auto-resolved.
        let conflictThreshold = 10
        
        for podcast in subscriptions {
            for episode in podcast.episodes {
                // Look up by guid first, then by audioUrl
                let action = actionMap[episode.guid] ?? (episode.audioUrl.flatMap { actionMap[$0] })
                guard let action else { continue }
                
                if let serverPosition = action.position, serverPosition > 0 {
                    let localPosition = episode.listenedSeconds
                    
                    switch strategy {
                    case .serverWins:
                        // Always apply server position (original behavior)
                        episode.listenedSeconds = serverPosition
                        
                    case .deviceWins:
                        // Only apply if server is ahead (never go backward)
                        if serverPosition > localPosition {
                            episode.listenedSeconds = serverPosition
                        }
                        
                    case .ask:
                        // If positions differ significantly, collect as conflict
                        if abs(serverPosition - localPosition) > conflictThreshold {
                            unresolvedConflicts.append(SyncConflict(
                                episodeGuid: episode.guid,
                                episodeTitle: episode.title,
                                podcastTitle: podcast.title,
                                localPosition: localPosition,
                                serverPosition: serverPosition,
                                serverTimestamp: action.timestamp
                            ))
                            // Don't overwrite — let user decide
                        } else {
                            // Close enough — auto-resolve with the higher value
                            episode.listenedSeconds = max(localPosition, serverPosition)
                        }
                    }
                }
                
                // Mark as played if position >= total (or very close)
                if let position = action.position, let total = action.total, total > 0 {
                    let progress = Double(position) / Double(total)
                    if progress >= 0.95 {
                        episode.isPlayed = true
                    }
                }
                
                updatedCount += 1
            }
        }
        
        try? modelContext.save()
        logger.info("Applied listen status to \(updatedCount) episodes (strategy: \(strategy.rawValue), \(unresolvedConflicts.count) unresolved)")
        return unresolvedConflicts
    }
    
    func sendEpisodeAction(_ action: EpisodeAction) async {
        actionMap[action.guid ?? action.episode] = action
        persistActionMap()
        guard let client = gpodderClient else { return }
        try? await client.uploadEpisodeActions([action])
    }
    
    func getLatestAction(for guid: String) -> EpisodeAction? {
        actionMap[guid]
    }
    
    // MARK: - Action Map Persistence
    
    func loadActionMap() {
        guard let data = UserDefaults.standard.data(forKey: "episodeActionMap"),
              let decoded = try? JSONDecoder().decode([String: EpisodeAction].self, from: data) else {
            return
        }
        self.actionMap = decoded
        let count = self.actionMap.count
        logger.info("Loaded \(count) persisted episode actions")
    }
    
    private func persistActionMap() {
        if let data = try? JSONEncoder().encode(actionMap) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
    }
    
    // MARK: - Profile Cleanup
    
    /// Remove all UserDefaults data associated with a profile.
    /// Call this before or after removing the profile from the profiles list.
    func clearProfileData(profileId: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "subscriptionUrls_\(profileId)")
        defaults.removeObject(forKey: "lastSubscriptionSync_\(profileId)")
        defaults.removeObject(forKey: "lastEpisodeActionSync_\(profileId)")
        logger.info("Cleared data for profile \(profileId)")
    }
    
    /// Check whether other profiles exist (to distinguish migration from fresh profile).
    static func hasOtherProfiles(excluding profileId: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "serverProfiles"),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return false
        }
        return profiles.contains { $0.id != profileId }
    }
}

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
    
    /// Tracks how many times each episode's sync conflict has been detected.
    /// Persisted to UserDefaults so counts survive app restarts.
    private var conflictCounts: [String: Int] = [:]
    
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
    
    func addSubscription(url: String, username: String? = nil, password: String? = nil) async throws {
        // Check if already subscribed
        guard !subscriptions.contains(where: { $0.url == url }) else { return }
        
        // Build auth header if credentials provided
        var authHeader: String? = nil
        if let username, let password {
            let combined = "\(username):\(password)"
            let encoded = Data(combined.utf8).base64EncodedString()
            authHeader = "Basic \(encoded)"
        }
        
        // Fetch the feed to get metadata
        let (parsed, episodes) = try await rssService.fetchFeed(url: url, authHeader: authHeader)
        
        let podcast = Podcast(
            url: url,
            title: parsed.title,
            podcastDescription: parsed.description,
            logoUrl: parsed.logoUrl,
            website: parsed.website,
            author: parsed.author,
            requiresAuth: username != nil
        )
        podcast.feedUsername = username
        podcast.sortOrder = subscriptions.count
        
        // Map new spec fields
        mapParsedPodcastMetadata(parsed, to: podcast)
        
        // Store feed credentials in Keychain
        if let username, let password {
            KeychainHelper.shared.saveFeedCredentials(username: username, password: password, forPodcastUrl: url)
        }
        
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
            mapParsedEpisodeMetadata(ep, to: episode)
            modelContext.insert(episode)
        }
        
        try modelContext.save()
        associateWithCurrentProfile(url: url)
        loadSubscriptions()
        
        // Sync to server
        if let client = gpodderClient {
            _ = try? await client.updateSubscriptions(deviceId: deviceId, add: [url])
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
            _ = try? await client.updateSubscriptions(deviceId: deviceId, remove: [url])
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
    ///
    /// - Parameter strategy: How to handle conflicts between local and server positions.
    ///   Pass the user's configured `syncConflictStrategy` so the setting is honored.
    /// - Returns: Unresolved conflicts (only populated when strategy is `.ask`).
    @discardableResult
    func refreshAndSync(
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager,
        strategy: SyncStrategy = .serverWins
    ) async -> [SyncConflict] {
        let newEpisodes = await refreshAllFeeds()
        
        // Group new episodes by podcast URL
        let byPodcast = Dictionary(grouping: newEpisodes, by: { $0.podcastUrl ?? "" })
        
        for (podcastUrl, episodes) in byPodcast {
            guard let podcast = subscriptions.first(where: { $0.url == podcastUrl }) else { continue }
            let podSettings = podcast.effectiveSettings
            
            // Filter to only truly "new" unplayed episodes
            let markedBefore = podSettings.markedPlayedBefore
            let sessionInteracted = interactedKeys[podcastUrl] ?? []
            let newOnly = episodes.filter { ep in
                // Skip already-played episodes
                guard !ep.isPlayed else { return false }
                // Skip episodes the user already interacted with (queued, dismissed)
                guard !ep.isInteracted else { return false }
                guard !sessionInteracted.contains(ep.guid) else { return false }
                // Skip if published before markedPlayedBefore
                if let markedBefore, let pubDate = ep.pubDate, pubDate <= markedBefore {
                    return false
                }
                // Must have audio
                return ep.audioUrl != nil
            }
            
            // Auto-queue new episodes from RSS
            let queueMode = podSettings.autoQueueMode ?? settingsManager.defaultAutoQueueMode
            if queueMode != .off {
                // Sort newest first so priority inserts show newest at top of Up Next
                let sorted = newOnly.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                playerManager.addToQueue(sorted, playNext: queueMode == .priority)
            }
            
            // Auto-download
            let shouldDownload = podSettings.autoDownloadNewEpisodes ?? settingsManager.defaultAutoDownload
            if shouldDownload {
                for episode in newOnly {
                    if let audioUrl = episode.audioUrl, !downloadManager.isDownloaded(episode.guid) {
                        let authHeaders: [String: String]? = podcast.requiresAuth
                            ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: podcast.url)
                                .map { ["Authorization": $0] }
                            : nil
                        downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl, authHeaders: authHeaders)
                    }
                }
            }
        }
        
        // Auto-queue existing unplayed episodes for all subscriptions
        autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // Sync episode actions with server, honoring the user's conflict resolution strategy
        var conflicts: [SyncConflict] = []
        do {
            conflicts = try await syncEpisodeActions(strategy: strategy)
        } catch {
            logger.error("Sync failed during refreshAndSync: \(error.localizedDescription)")
            // Even if network sync failed, apply local actionMap with the configured strategy
            conflicts = applyEpisodeActions(strategy: strategy)
        }
        return conflicts
    }
    
    func refreshFeed(for podcast: Podcast) async throws -> [Episode] {
        let authHeader = podcast.requiresAuth
            ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: podcast.url)
            : nil
        let (parsed, parsedEpisodes) = try await rssService.fetchFeed(url: podcast.url, authHeader: authHeader)
        
        // Update podcast metadata
        podcast.title = parsed.title
        podcast.podcastDescription = parsed.description
        podcast.logoUrl = parsed.logoUrl
        podcast.website = parsed.website
        podcast.author = parsed.author
        
        // Map new spec fields
        mapParsedPodcastMetadata(parsed, to: podcast)
        
        // Handle feed URL migration (itunes:new-feed-url)
        if let newUrl = parsed.newFeedUrl, !newUrl.isEmpty, newUrl != podcast.url {
            logger.warning("Feed \(podcast.title) declares new URL: \(newUrl). Auto-migrating.")
            let oldUrl = podcast.url
            podcast.url = newUrl
            podcast.newFeedUrl = nil  // Clear after migration
            // Update profile associations
            disassociateFromCurrentProfile(url: oldUrl)
            associateWithCurrentProfile(url: newUrl)
            // Sync change to server
            if let client = gpodderClient {
                _ = try? await client.updateSubscriptions(deviceId: deviceId, add: [newUrl], remove: [oldUrl])
            }
        }
        
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
            mapParsedEpisodeMetadata(ep, to: episode)
            modelContext.insert(episode)
            newEpisodes.append(episode)
        }
        
        // Update existing episodes with new metadata fields
        for ep in parsedEpisodes where existingGuids.contains(ep.guid) {
            if let existing = podcast.episodes.first(where: { $0.guid == ep.guid }) {
                mapParsedEpisodeMetadata(ep, to: existing)
            }
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
    
    func getAutoQueueCandidates(for podcast: Podcast, globalDefault: AutoQueueMode = .off) -> [Episode] {
        let settings = podcast.effectiveSettings
        let mode = settings.autoQueueMode ?? globalDefault
        guard mode != .off else { return [] }
        
        let markedBefore = settings.markedPlayedBefore
        let interacted = interactedKeys[podcast.url] ?? []
        
        return podcast.episodes.filter { episode in
            // Skip if already played
            guard !episode.isPlayed else { return false }
            // Skip if already interacted (persisted in SwiftData)
            guard !episode.isInteracted else { return false }
            // Skip if interacted this session (in-memory, covers current session before SwiftData save)
            guard !interacted.contains(episode.guid) else { return false }
            // Skip if published before markedPlayedBefore
            if let markedBefore, let pubDate = episode.pubDate, pubDate <= markedBefore {
                return false
            }
            // Must have audio
            return episode.audioUrl != nil
        }.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }
    
    /// Auto-queue the most recent unplayed episode for each subscription.
    /// This covers the initial subscribe case — only the latest episode is queued,
    /// not the entire back-catalog. Future new episodes are handled by refreshAllFeeds().
    /// Extracted for testability — called by refreshAndSync.
    func autoQueueExistingEpisodes(playerManager: PlayerManager, settingsManager: SettingsManager) {
        let globalDefault = settingsManager.defaultAutoQueueMode
        for podcast in subscriptions {
            let candidates = getAutoQueueCandidates(for: podcast, globalDefault: globalDefault)
            // Only queue the most recent episode (candidates are sorted newest-first)
            guard let mostRecent = candidates.first else { continue }
            let mode = podcast.effectiveSettings.autoQueueMode ?? globalDefault
            playerManager.addToQueue([mostRecent], playNext: mode == .priority)
        }
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
    
    /// Mark an episode as played locally (sets isPlayed flag only, no server action).
    /// Used by handleEpisodeCompleted which sends its own EpisodeAction separately.
    func markEpisodePlayedLocally(podcastUrl: String, episodeGuid: String) {
        markEpisodeAsInteracted(podcastUrl, episodeGuid)
        
        if let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
           let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }) {
            episode.isPlayed = true
            try? modelContext.save()
            logger.info("Marked episode \(episodeGuid) as played (local only)")
        }
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
                _ = try? await client.uploadEpisodeActions(slice)
            }
            logger.info("Uploaded \(count) play actions to server")
        }
    }
    
    // MARK: - gPodder Sync
    
    /// Pull subscription list from server and subscribe to any missing feeds.
    /// Also pushes any local-only subscriptions to the server.
    /// Returns any URL rewrites from the server that need to be handled.
    func syncSubscriptions() async throws -> [URLRewriteConflict] {
        guard let client = gpodderClient else {
            logger.info("No gPodder client configured, skipping subscription sync")
            return []
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
        var allRewrites: [URLRewrite] = []
        if since > 0 {
            let serverUrls = Set(delta.add)
            let localOnly = subscriptions.filter { !serverUrls.contains($0.url) }
            if !localOnly.isEmpty {
                let urls = localOnly.map(\.url)
                let rewrites = (try? await client.updateSubscriptions(deviceId: deviceId, add: urls)) ?? []
                allRewrites.append(contentsOf: rewrites)
                logger.info("Pushed \(urls.count) local subscriptions to server")
            }
        }
        
        UserDefaults.standard.set(delta.timestamp, forKey: "lastSubscriptionSync_\(profileId)")
        try? modelContext.save()
        loadSubscriptions()
        
        logger.info("Subscription sync complete: \(addedCount) added, \(delta.remove.count) removed")
        
        // Convert URL rewrites to user-facing conflicts
        return allRewrites.map { rewrite in
            let podcast = subscriptions.first(where: { $0.url == rewrite.oldUrl })
            return URLRewriteConflict(
                oldUrl: rewrite.oldUrl,
                newUrl: rewrite.newUrl,
                podcastTitle: podcast?.title,
                artworkUrl: podcast?.logoUrl
            )
        }
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
                // Only overwrite actionMap when the server action is newer
                if action.timestamp >= existing.timestamp {
                    actionMap[key] = action
                }
                
                if abs(existingPos - newPos) > 5 {
                    // Look up episode/podcast metadata for the conflict UI
                    let (epTitle, podTitle, podUrl, artUrl, audioUrl, totalDur) = lookupEpisodeMetadata(guid: key)
                    
                    // Skip conflict for episodes already marked as played
                    let isAlreadyPlayed = isEpisodePlayed(guid: key)
                    
                    // Skip conflict for episodes that are effectively complete
                    // (either position is ≥95% of total duration)
                    let isEffectivelyComplete: Bool = {
                        guard let total = totalDur, total > 60 else { return false }
                        let threshold = Int(Double(total) * 0.95)
                        return existingPos >= threshold || newPos >= threshold
                    }()
                    
                    if !isAlreadyPlayed && !isEffectivelyComplete {
                        let count = incrementConflictCount(for: key)
                        conflicts.append(SyncConflict(
                            episodeGuid: key,
                            episodeTitle: epTitle,
                            podcastTitle: podTitle,
                            podcastUrl: podUrl,
                            artworkUrl: artUrl,
                            audioUrl: audioUrl,
                            localPosition: existingPos,
                            serverPosition: newPos,
                            serverTimestamp: action.timestamp,
                            totalDuration: totalDur,
                            occurrenceCount: count
                        ))
                    }
                }
            } else {
                // No existing entry — just store the server action
                actionMap[key] = action
            }
        }
        
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: "lastEpisodeActionSync_\(epProfileId)")
        persistActionMap()
        
        // Apply synced positions to Episode objects using the configured strategy
        let applyConflicts = applyEpisodeActions(strategy: strategy)
        
        // Merge conflicts — deduplicate by episodeGuid, prefer applyConflicts (has richer metadata)
        let applyGuids = Set(applyConflicts.map(\.episodeGuid))
        let uniqueActionMapConflicts = conflicts.filter { !applyGuids.contains($0.episodeGuid) }
        let allConflicts = uniqueActionMapConflicts + applyConflicts
        
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
                        // Skip conflict for episodes already marked as played —
                        // completed episodes should never generate conflicts
                        if episode.isPlayed {
                            episode.listenedSeconds = max(localPosition, serverPosition)
                        } else {
                            // Also skip if episode is effectively complete
                            // (position is ≥95% of total duration)
                            let total = episode.durationSeconds ?? 0
                            let isEffectivelyComplete = total > 60 && (
                                localPosition >= Int(Double(total) * 0.95) ||
                                serverPosition >= Int(Double(total) * 0.95)
                            )
                            
                            if isEffectivelyComplete {
                                // Auto-resolve: take the higher position
                                episode.listenedSeconds = max(localPosition, serverPosition)
                            } else if abs(serverPosition - localPosition) > conflictThreshold {
                                let count = incrementConflictCount(for: episode.guid)
                                unresolvedConflicts.append(SyncConflict(
                                    episodeGuid: episode.guid,
                                    episodeTitle: episode.title,
                                    podcastTitle: podcast.title,
                                    podcastUrl: podcast.url,
                                    artworkUrl: episode.imageUrl ?? podcast.logoUrl,
                                    audioUrl: episode.audioUrl,
                                    localPosition: localPosition,
                                    serverPosition: serverPosition,
                                    serverTimestamp: action.timestamp,
                                    totalDuration: episode.durationSeconds,
                                    occurrenceCount: count
                                ))
                                // Don't overwrite — let user decide
                            } else {
                                // Close enough — auto-resolve with the higher value
                                episode.listenedSeconds = max(localPosition, serverPosition)
                            }
                        }
                    }
                }
                
                // Mark as played if position >= total (or very close)
                // Guard: require both position and total > 60s to avoid marking episodes
                // as played from corrupt sync data (e.g., stale position during auto-advance)
                if let position = action.position, let total = action.total, total > 60, position > 60 {
                    let progress = Double(position) / Double(total)
                    if progress >= 0.95 {
                        episode.isPlayed = true
                    }
                }
                
                updatedCount += 1
            }
        }
        
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save episode actions (possible store corruption): \(error.localizedDescription)")
        }
        logger.info("Applied listen status to \(updatedCount) episodes (strategy: \(strategy.rawValue), \(unresolvedConflicts.count) unresolved)")
        return unresolvedConflicts
    }
    
    func sendEpisodeAction(_ action: EpisodeAction) async {
        actionMap[action.guid ?? action.episode] = action
        persistActionMap()
        guard let client = gpodderClient else { return }
        _ = try? await client.uploadEpisodeActions([action])
    }
    
    func getLatestAction(for guid: String) -> EpisodeAction? {
        actionMap[guid]
    }
    
    // MARK: - Conflict Resolution
    
    /// Look up episode metadata from subscriptions for conflict display.
    private func lookupEpisodeMetadata(guid: String) -> (episodeTitle: String?, podcastTitle: String?, podcastUrl: String?, artworkUrl: String?, audioUrl: String?, totalDuration: Int?) {
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == guid }) {
                return (
                    episode.title,
                    podcast.title,
                    podcast.url,
                    episode.imageUrl ?? podcast.logoUrl,
                    episode.audioUrl,
                    episode.durationSeconds
                )
            }
        }
        return (nil, nil, nil, nil, nil, nil)
    }
    
    /// Check if an episode is already marked as played (used to skip conflict detection).
    private func isEpisodePlayed(guid: String) -> Bool {
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == guid }) {
                return episode.isPlayed
            }
        }
        return false
    }
    
    /// Resolve a sync conflict by updating the local model, actionMap, and server.
    /// This prevents the conflict from reappearing on next sync.
    func resolveConflict(_ conflict: SyncConflict, chosenPosition: Int) {
        // 1. Update local Episode.listenedSeconds
        updateEpisodeProgressByGuid(episodeGuid: conflict.episodeGuid, position: chosenPosition)
        
        // 2. Build an EpisodeAction with the resolved position
        let action = EpisodeAction(
            podcast: conflict.podcastUrl ?? "",
            episode: conflict.audioUrl ?? "",
            guid: conflict.episodeGuid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: chosenPosition,
            started: 0,
            total: conflict.totalDuration ?? chosenPosition,
            device: deviceId
        )
        
        // 3. Update actionMap so next sync won't re-detect this conflict
        actionMap[conflict.episodeGuid] = action
        persistActionMap()
        
        // 4. Clear conflict count since user resolved it
        clearConflictCount(for: conflict.episodeGuid)
        
        // 5. Upload to server
        Task {
            guard let client = gpodderClient else { return }
            do {
                _ = try await client.uploadEpisodeActions([action])
                logger.info("Uploaded conflict resolution for \(conflict.episodeGuid) at position \(chosenPosition)")
            } catch {
                logger.error("Failed to upload conflict resolution: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - URL Rewrite Resolution
    
    /// Accept a server URL rewrite — update the local podcast's feed URL.
    func acceptUrlRewrite(_ rewrite: URLRewriteConflict) {
        guard let podcast = subscriptions.first(where: { $0.url == rewrite.oldUrl }) else {
            logger.warning("Cannot apply URL rewrite: no podcast found for \(rewrite.oldUrl)")
            return
        }
        
        let oldUrl = podcast.url
        podcast.url = rewrite.newUrl
        
        // Update profile associations
        disassociateFromCurrentProfile(url: oldUrl)
        associateWithCurrentProfile(url: rewrite.newUrl)
        
        try? modelContext.save()
        loadSubscriptions()
        
        logger.info("Accepted URL rewrite: \(oldUrl) → \(rewrite.newUrl)")
    }
    
    /// Reject a server URL rewrite — keep the local URL unchanged.
    func rejectUrlRewrite(_ rewrite: URLRewriteConflict) {
        logger.info("Rejected URL rewrite for \(rewrite.oldUrl) → \(rewrite.newUrl). Keeping local URL.")
        // No action needed — the local URL stays as-is.
        // This may cause drift if the server has already updated its records.
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
    
    // MARK: - Conflict Count Tracking
    
    /// Load conflict counts from UserDefaults.
    func loadConflictCounts() {
        if let data = UserDefaults.standard.data(forKey: "syncConflictCounts"),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            conflictCounts = decoded
        }
    }
    
    /// Increment and persist the conflict count for an episode. Returns the new count.
    @discardableResult
    private func incrementConflictCount(for guid: String) -> Int {
        let count = (conflictCounts[guid] ?? 0) + 1
        conflictCounts[guid] = count
        persistConflictCounts()
        return count
    }
    
    /// Clear the conflict count for a resolved episode.
    private func clearConflictCount(for guid: String) {
        conflictCounts.removeValue(forKey: guid)
        persistConflictCounts()
    }
    
    private func persistConflictCounts() {
        if let data = try? JSONEncoder().encode(conflictCounts) {
            UserDefaults.standard.set(data, forKey: "syncConflictCounts")
        }
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
    
    // MARK: - Parsed Metadata Mapping
    
    /// Map new RSS/iTunes/Podcasting 2.0 fields from parsed data to a Podcast model.
    private func mapParsedPodcastMetadata(_ parsed: ParsedPodcast, to podcast: Podcast) {
        podcast.language = parsed.language
        podcast.copyright = parsed.copyright
        podcast.categories = parsed.categories
        podcast.subcategory = parsed.subcategory
        podcast.explicit = parsed.explicit
        podcast.showType = parsed.showType
        podcast.isComplete = parsed.isComplete
        podcast.newFeedUrl = parsed.newFeedUrl
        podcast.podcastGuid = parsed.podcastGuid
        podcast.fundingUrl = parsed.fundingUrl
        podcast.fundingLabel = parsed.fundingLabel
        podcast.publisher = parsed.publisher
        podcast.supportsValue4Value = parsed.supportsValue4Value
        podcast.hasLiveItem = parsed.hasLiveItem
        podcast.liveItemStatus = parsed.liveItemStatus
        podcast.liveItemStart = parsed.liveItemStart
        podcast.liveItemContentLink = parsed.liveItemContentLink
    }
    
    /// Map new iTunes/Podcasting 2.0 fields from parsed data to an Episode model.
    private func mapParsedEpisodeMetadata(_ parsed: ParsedEpisode, to episode: Episode) {
        episode.seasonNumber = parsed.seasonNumber
        episode.seasonName = parsed.seasonName
        episode.episodeNumber = parsed.episodeNumber
        episode.episodeDisplay = parsed.episodeDisplay
        episode.episodeType = parsed.episodeType
        episode.explicit = parsed.explicit
        
        // Update transcript and chapters URLs (feeds may add these to existing episodes)
        if let transcriptUrl = parsed.transcriptUrl, !transcriptUrl.isEmpty {
            episode.transcriptUrl = transcriptUrl
        }
        if let chaptersUrl = parsed.chaptersUrl, !chaptersUrl.isEmpty {
            episode.chaptersUrl = chaptersUrl
        }
        
        // Encode Podlove inline chapters to JSON for persistence
        if let chapters = parsed.inlineChapters, !chapters.isEmpty {
            struct InlineChapterData: Codable {
                let startTime: Double
                let title: String
                let img: String?
                let url: String?
            }
            let encoded = chapters.map { InlineChapterData(startTime: $0.startTime, title: $0.title, img: $0.image, url: $0.href) }
            if let data = try? JSONEncoder().encode(encoded) {
                episode.chaptersJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}

import Foundation
import SwiftData
import os

/// Sendable result from a concurrent RSS feed fetch.
/// Contains only value types — safe to pass across actor boundaries.
struct FeedFetchResult: Sendable {
    let url: String
    let authHeader: String?
    let parsed: ParsedPodcast
    let episodes: [ParsedEpisode]
}

/// Manages podcast subscriptions, episode data, feed refreshing, and gPodder sync.
/// Subscription and episode state manager — owns the SwiftData ModelContext.
@Observable
@MainActor
final class PodcastManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "PodcastManager")
    
    var subscriptions: [Podcast] = []
    var isRefreshing = false
    
    /// Whether a sync cycle (refreshAndSync) is currently in progress.
    /// Used by loadSubscriptions to avoid blanking the library mid-sync.
    var isSyncing = false
    
    /// Set when any sync backend (Pro or gPodder) returns an error, so the UI
    /// can show a banner. Cleared on the next successful sync or user dismissal.
    var lastSyncError: String?
    
    /// Progress of the current subscription sync: (completed, total).
    /// Nil when no sync is in progress.
    var subscriptionSyncProgress: (completed: Int, total: Int)?
    
    private let modelContext: ModelContext
    private let rssService = RSSService()
    private var syncClient: (any SyncClient)?
    private var deviceId = "swift-client"
    
    // References to other managers for cleanup
    var downloadManager: DownloadManager?
    var settingsManager: SettingsManager?
    /// Weak reference to PlayerManager — used to forward `setSyncClient`
    /// so that queue sync is wired at every call site, not just cold start.
    weak var playerManager: PlayerManager?
    /// Badge service for updating app icon badge count after new episodes.
    var badgeService: BadgeService?
    
    /// Map of episodeGuid → latest EpisodeAction (for sync lookups).
    /// Forwarded from EpisodeActionSyncService for backward compatibility.
    var actionMap: [String: EpisodeAction] {
        get { episodeActionSync.actionMap }
    }
    
    /// Isolated service owning episode action sync, action map, and conflict tracking.
    private(set) var episodeActionSync: EpisodeActionSyncService!
    
    /// Network monitor for checking WiFi vs cellular before autodownloads.
    var networkMonitor: NetworkMonitoring?
    
    /// Interacted episode GUIDs per podcast URL (marks episodes as "seen")
    private var interactedKeys: [String: Set<String>] = [:]
    
    // MARK: - Disk Write Throttle
    
    /// Minimum interval between disk saves for progress-only updates (seconds).
    /// Reduces disk write rate from ~95 KB/s to ~8 KB/s during sustained playback.
    /// See: Crash 1 — excessive disk writes (bug_type 145, Incident 6AA549C6).
    private static let progressSaveInterval: TimeInterval = 60
    
    /// Timestamp of the last progress-triggered `modelContext.save()`.
    private var lastProgressSaveTime = Date.distantPast
    
    /// Tracks progress-triggered saves this session for budget monitoring.
    /// Exposed as `private(set)` so tests can assert on throttle behavior.
    private(set) var progressSaveCount = 0
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // Create episode action service with closure-based DI.
        // Closures capture `self` weakly to avoid retain cycles.
        self.episodeActionSync = EpisodeActionSyncService(
            modelContext: modelContext,
            subscriptionsProvider: { [weak self] in self?.subscriptions ?? [] },
            syncClientProvider: { [weak self] in self?.syncClient },
            profileIdProvider: { [weak self] in self?.activeProfileId },
            deviceIdProvider: { [weak self] in self?.deviceId ?? "swift-client" },
            storeHealthCheck: {
                StoreHealthProbe.rawWriteProbe(storeURL: YourPodsApp.modelStoreURL())
            }
        )
        loadSubscriptions()
    }
    
    func setSyncClient(_ client: (any SyncClient)?, deviceId: String) {
        self.syncClient = client
        self.deviceId = deviceId
        // Forward to PlayerManager so queue sync, playback sync, and
        // nowPlaying reconciliation all have the correct client wired.
        // Without this, PlayerManager.syncClient stays nil after
        // onboarding or profile switches — queue sync silently skips.
        playerManager?.setSyncClient(client, deviceId: deviceId)
    }
    
    /// The currently wired sync client (for migration/downcast in onboarding).
    var currentSyncClient: (any SyncClient)? { syncClient }
    
    /// Migrate local subscriptions and episode actions to YourPods Pro.
    /// Must be called while a `YourPodsProClient` is the active sync client.
    /// Safe to call from `@MainActor` — does not expose or downcast the actor client.
    func migrateLocalDataToPro() async throws -> (subscriptions: Int, actions: Int) {
        guard let client = syncClient as? YourPodsProClient else {
            throw PromotionError.profileNotFound  // No Pro client wired
        }
        let subs = subscriptions.map(\.url)
        let actions = allEpisodeActions()
        let result = try await client.migrate(subscriptions: subs, episodeActions: actions)
        return (result.subscriptionsImported, result.episodeActionsImported)
    }
    
    /// All stored episode actions (for Pro migration upload).
    func allEpisodeActions() -> [EpisodeAction] {
        Array(actionMap.values)
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
    
    // MARK: - Context Persistence
    
    /// Save the SwiftData model context. Used by views for lightweight changes (e.g., groupId).
    ///
    /// Pre-validates store health using `StoreHealthProbe.rawWriteProbe()` to prevent
    /// pread() signal crashes during WAL checkpoint. Throws `StoreError.storeUnhealthy`
    /// if the probe fails.
    func saveContext() throws {
        let storeURL = YourPodsApp.modelStoreURL()
        guard StoreHealthProbe.rawWriteProbe(storeURL: storeURL) else {
            throw StoreError.storeUnhealthy
        }
        try modelContext.save()
    }
    
    // MARK: - Vault → Sync Promotion
    
    /// Promote a Vault Mode profile to a gPodder sync profile.
    /// - Modifies the profile in UserDefaults (sets baseUrl, username, deviceId)
    /// - Saves password to Keychain
    /// - Wires up a GPodderClient
    /// - Pushes local subscriptions to the server
    /// - Pulls server subscriptions and episode actions
    /// - Returns the total number of merged subscriptions
    @MainActor
    func promoteVaultToSync(
        profile: ServerProfile,
        serverUrl: String,
        username: String,
        password: String,
        deviceId: String
    ) async throws -> Int {
        // 1. Validate connection first — don't modify profile until we know the server works
        let client = GPodderClient(baseUrl: serverUrl, username: username, password: password)
        let effectiveDeviceId = deviceId.isEmpty ? "yourpods-ios" : deviceId
        
        // Test connection by fetching subscription changes
        // If this throws, the profile stays as Vault Mode (rollback by not committing)
        _ = try await client.getSubscriptionChanges(deviceId: effectiveDeviceId, since: 0)
        
        // 2. Connection succeeded — update the profile in UserDefaults
        var profiles: [ServerProfile] = []
        if let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw PromotionError.profileNotFound
        }
        
        profiles[idx].baseUrl = serverUrl
        profiles[idx].username = username
        profiles[idx].deviceId = effectiveDeviceId
        // Update name to reflect the promotion
        if profiles[idx].name == "Vault Mode" {
            profiles[idx].name = username
        }
        
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "serverProfiles")
        }
        
        // 3. Save password to Keychain
        _ = KeychainHelper.shared.save(password: password, forProfileId: profile.id)
        
        // 4. Wire up GPodderClient
        setSyncClient(client, deviceId: effectiveDeviceId)
        
        // 5. Push local subscriptions to server
        let profileId = activeProfileId ?? profile.id
        let localUrls = Array(subscriptionUrls(for: profileId))
        if !localUrls.isEmpty {
            _ = try await client.updateSubscriptions(deviceId: effectiveDeviceId, add: localUrls, remove: [])
            logger.info("Pushed \(localUrls.count) local subscriptions to server")
        }
        
        // 6. Pull server subscriptions
        let conflicts = try await syncSubscriptions()
        logger.info("Subscription sync complete, \(conflicts.count) URL rewrites")
        
        // 7. Sync episode actions
        _ = try await syncEpisodeActions()
        
        loadSubscriptions()
        
        return subscriptions.count
    }
    
    /// Promote a Vault Mode profile to YourPods Pro.
    /// Similar to `promoteVaultToSync` but uses the Pro API and migration endpoint.
    func promoteVaultToPro(
        profile: ServerProfile,
        authProvider: any AuthProvider,
        baseUrl: String = "https://sync.yourpods.app"
    ) async throws -> Int {
        // 1. Validate connection — create client and validate session
        let client = YourPodsProClient(baseUrl: baseUrl, authProvider: authProvider)
        let session = try await client.validateSession()
        
        // 2. Connection succeeded — update the profile in UserDefaults
        var profiles: [ServerProfile] = []
        if let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw PromotionError.profileNotFound
        }
        
        profiles[idx].baseUrl = baseUrl
        profiles[idx].username = session.user.email
        profiles[idx].deviceId = "yourpods-ios"
        profiles[idx].profileType = .yourpodsPro
        // Update name to reflect the promotion
        if profiles[idx].name == "Vault Mode" {
            profiles[idx].name = session.user.email
        }
        
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "serverProfiles")
        }
        
        // 3. Wire up YourPodsProClient
        setSyncClient(client, deviceId: "yourpods-ios")
        
        // 4. Migrate local data to server
        let profileId = activeProfileId ?? profile.id
        let localUrls = Array(subscriptionUrls(for: profileId))
        let actions = allEpisodeActions()
        
        if !localUrls.isEmpty || !actions.isEmpty {
            let result = try await client.migrate(subscriptions: localUrls, episodeActions: actions)
            logger.info("Migration complete: \(result.subscriptionsImported) subs, \(result.episodeActionsImported) actions")
        }
        
        // 5. Pull server subscriptions
        let conflicts = try await syncSubscriptions()
        logger.info("Subscription sync complete, \(conflicts.count) URL rewrites")
        
        // 6. Sync episode actions
        _ = try await syncEpisodeActions()
        
        loadSubscriptions()
        
        return subscriptions.count
    }
    
    /// Errors specific to vault → sync promotion.
    enum PromotionError: LocalizedError {
        case profileNotFound
        
        var errorDescription: String? {
            switch self {
            case .profileNotFound:
                return "Profile not found. Please restart the app and try again."
            }
        }
    }
    
    // MARK: - Download Cleanup
    
    /// Delete or schedule deletion of the episode's download based on the cleanup policy.
    private func handleDownloadCleanup(for episodeGuid: String, podcastUrl: String) {
        guard let downloadManager, downloadManager.isDownloaded(episodeGuid) else { return }
        
        var policy: DownloadCleanupPolicy = .oncePlayed
        if let settingsManager {
            policy = settingsManager.defaultDownloadCleanupPolicy
            if let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
               let perPodcast = podcast.effectiveSettings.downloadCleanupPolicy {
                policy = perPodcast
            }
        }
        
        switch policy {
        case .oncePlayed:
            downloadManager.deleteDownload(guid: episodeGuid)
            logger.info("Deleted download after play: \(episodeGuid)")
        case .afterOneWeek, .afterOneMonth:
            downloadManager.markPlayed(guid: episodeGuid)
            logger.info("Marked download for deferred cleanup: \(episodeGuid) (\(policy.rawValue))")
        case .never:
            break
        }
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
                    // Adopt all existing podcasts when profile URLs are empty.
                    // This handles both first-profile migration AND recovery when
                    // UserDefaults keys are cleared (e.g., app update edge cases).
                    // The sync cycle will correct the profile URL set on its next run.
                    if !allPodcasts.isEmpty {
                        let allUrls = Set(allPodcasts.map(\.url))
                        saveSubscriptionUrls(allUrls, for: profileId)
                        subscriptions = allPodcasts
                        logger.info("Adopted \(allPodcasts.count) podcast(s) for profile \(profileId) (recovery/migration)")
                    } else {
                        // Guard: don't blank the library mid-sync — keep current cached state
                        if isSyncing && !subscriptions.isEmpty {
                            logger.debug("loadSubscriptions: preserving \(self.subscriptions.count) cached podcasts during sync (store empty, profileUrls empty)")
                            return
                        }
                        subscriptions = []
                    }
                } else {
                    let filtered = allPodcasts.filter { profileUrls.contains($0.url) }
                    
                    // Re-adoption safety net: if the profile URL set is non-empty
                    // but no podcasts match (stale/drifted URLs), re-adopt all store
                    // podcasts instead of showing an empty library. This prevents the
                    // "library disappears on launch" bug caused by URL drift.
                    if filtered.isEmpty && !allPodcasts.isEmpty {
                        let allUrls = Set(allPodcasts.map(\.url))
                        saveSubscriptionUrls(allUrls, for: profileId)
                        subscriptions = allPodcasts
                        logger.warning("Re-adopted \(allPodcasts.count) podcast(s) — profile URL filter returned zero results (stale URLs)")
                    } else if filtered.isEmpty && allPodcasts.isEmpty {
                        // Guard: don't blank the library mid-sync — keep current cached state
                        if isSyncing && !subscriptions.isEmpty {
                            logger.debug("loadSubscriptions: preserving \(self.subscriptions.count) cached podcasts during sync (store empty)")
                            return
                        }
                        subscriptions = filtered
                    } else {
                        subscriptions = filtered
                    }
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
        
        modelContext.safeSave()
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
        
        modelContext.guardedSave(storeURL: YourPodsApp.modelStoreURL())
        associateWithCurrentProfile(url: url)
        loadSubscriptions()

        // Track as pending add BEFORE pushing — survives network failures exactly
        // like pendingRemovals. syncSubscriptions will push this on the next cycle
        // and won't mistake it for a remote deletion.
        addPendingSubscriptionAdd(url)

        // Immediate push (best-effort — pending add ensures retry if this fails)
        if let client = syncClient {
            do {
                _ = try await client.pushSubscriptions(add: [url], remove: [], deviceId: deviceId)
                clearPendingSubscriptionAdd(url)
                logger.info("Pushed new subscription to server: \(url)")
            } catch {
                logger.error("Failed to push new subscription (will retry on next sync): \(error.localizedDescription)")
            }
        }

        logger.info("Subscribed to \(parsed.title) with \(episodes.count) episodes")
    }
    
    func removeSubscription(_ podcast: Podcast) async {
        let url = podcast.url
        disassociateFromCurrentProfile(url: url)
        modelContext.delete(podcast)
        modelContext.safeSave()
        loadSubscriptions()

        // Record as pending removal BEFORE pushing, so it survives network failures.
        // syncSubscriptions reads this set and re-pushes it on the next sync.
        addPendingSubscriptionRemoval(url)

        if let client = syncClient {
            do {
                _ = try await client.pushSubscriptions(add: [], remove: [url], deviceId: deviceId)
                logger.info("Pushed subscription removal to server: \(url)")
            } catch {
                // Removal push failed — pending removal set ensures retry on next sync
                logger.error("Failed to push subscription removal (will retry on next sync): \(error.localizedDescription)")
            }
        }
    }

    
    // MARK: - Sync-Optimized Subscription Methods
    
    /// Filter a list of feed URLs to only those not already subscribed.
    /// Used by syncSubscriptions to skip already-known feeds.
    func filterNewSubscriptionUrls(_ urls: [String]) -> [String] {
        let subscribedUrls = Set(subscriptions.map(\.url))
        return urls.filter { !subscribedUrls.contains($0) }
    }
    
    /// Determines which subscriptions need to be pushed to the server as adds.
    /// Only URLs the user explicitly added on this device (pendingSubscriptionAdds)
    /// that the server doesn't have yet are eligible.
    ///
    /// ⚠️ Do NOT fall back to "any local URL not on server" — that pattern re-adds
    /// podcasts that were deleted from another device (the web / gPodder client).
    /// The server is authoritative for cross-device state.
    ///
    /// Exception: `forcePushToServer` intentionally bypasses this and pushes all
    /// local URLs — it is a recovery tool, not a sync tool.
    func localSubscriptionsToUpload(serverUrls: Set<String>) -> [String] {
        let pendingAdds = pendingSubscriptionAdds()
        return Array(pendingAdds.subtracting(serverUrls))
    }

    // MARK: - Pending Subscription Adds
    // Tracks URLs the user explicitly subscribed to on this device since the last sync.
    // Only these are pushed to the server as adds during syncSubscriptions.
    // This prevents re-adding podcasts that were deleted from the server by another device.

    private func pendingAddsKey() -> String {
        "pendingSubscriptionAdds_\(activeProfileId ?? "global")"
    }

    /// Returns the set of URLs the user added locally that haven't been confirmed by the server.
    func pendingSubscriptionAdds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingAddsKey()) ?? [])
    }

    /// Records a URL as a locally-initiated add (called in subscribeToFeed before the network push).
    func addPendingSubscriptionAdd(_ url: String) {
        var set = pendingSubscriptionAdds()
        set.insert(url)
        UserDefaults.standard.set(Array(set), forKey: pendingAddsKey())
    }

    /// Clears a URL from the pending-add set after a confirmed successful server push.
    func clearPendingSubscriptionAdd(_ url: String) {
        var set = pendingSubscriptionAdds()
        set.remove(url)
        UserDefaults.standard.set(Array(set), forKey: pendingAddsKey())
    }

    // MARK: - Pending Subscription Removals
    // Tracks URLs that the user has deleted locally, so syncSubscriptions can
    // push the removal before pulling and filter bounce-backs from the server.

    private func pendingRemovalsKey() -> String {
        let profileId = activeProfileId ?? "global"
        return "pendingSubscriptionRemovals_\(profileId)"
    }

    /// Returns the set of URLs pending removal on the server.
    func pendingSubscriptionRemovals() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: pendingRemovalsKey()) ?? []
        return Set(arr)
    }

    /// Records a URL to be removed from the server on the next sync.
    func addPendingSubscriptionRemoval(_ url: String) {
        var pending = pendingSubscriptionRemovals()
        pending.insert(url)
        UserDefaults.standard.set(Array(pending), forKey: pendingRemovalsKey())
    }

    /// Removes a URL from the pending-removal set (called after successful push).
    private func clearPendingSubscriptionRemoval(_ url: String) {
        var pending = pendingSubscriptionRemovals()
        pending.remove(url)
        UserDefaults.standard.set(Array(pending), forKey: pendingRemovalsKey())
    }

    
    /// Force push all local data to the server: subscriptions first, then episode actions.
    /// Called by the "Force Push to Server" button in Settings.
    /// Unlike the regular sync, this always pushes local subscriptions regardless of sync state.
    func forcePushToServer() async -> [SyncConflict] {
        guard let client = syncClient else {
            logger.info("No sync client — skipping force push")
            return []
        }
        
        // 1. Push subscriptions
        let localUrls = subscriptions.map(\.url)
        if !localUrls.isEmpty {
            do {
                _ = try await client.pushSubscriptions(add: localUrls, remove: [], deviceId: deviceId)
                logger.info("Force pushed \(localUrls.count) subscriptions to server")
            } catch {
                logger.error("Force push subscriptions failed: \(error.localizedDescription)")
            }
        }
        
        // 2. Sync episode actions with deviceWins to preserve local positions
        let conflicts = (try? await syncEpisodeActions(strategy: .deviceWins)) ?? []
        return conflicts
    }
    
    /// Force pull all data from the server: resets sync timestamps, pulls subscriptions
    /// and episode actions. Called by the "Force Pull from Server" button in Settings.
    /// This is a recovery tool for account switches and sync issues.
    func forcePullFromServer(strategy: SyncStrategy = .serverWins) async throws -> [SyncConflict] {
        guard syncClient != nil else {
            logger.info("No sync client — skipping force pull")
            return []
        }

        let profileId = activeProfileId ?? "global"

        // 1. Reset subscription sync timestamp so the server returns its complete list
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(profileId)")
        logger.info("Force pull: reset lastSubscriptionSync for profile \(profileId) to 0")

        episodeActionSync.clearActionMapAndConflicts()
        let clearedCount = actionMap.count
        logger.info("Force pull: cleared actionMap (\(clearedCount)) and conflict counts")

        // 3. Pull subscriptions (full sync since timestamp = 0)
        _ = try await syncSubscriptions()

        // 4. Pull episode actions using the user's configured conflict strategy
        let conflicts = (try? await syncEpisodeActions(strategy: strategy)) ?? []

        logger.info("Force pull complete: subscriptions and episode actions synced")
        return conflicts
    }
    
    /// Persist a podcast and its episodes from pre-parsed RSS data.
    /// Optimized for batch sync: does NOT call loadSubscriptions() or push to server.
    /// Caller is responsible for calling loadSubscriptions() and modelContext.save()
    /// after the batch is complete.
    func persistPodcastFromSync(url: String, parsed: ParsedPodcast, episodes: [ParsedEpisode]) {
        // Guard: skip if already in SwiftData (dedup safety net)
        let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.url == url })
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            logger.debug("persistPodcastFromSync: skipping duplicate URL: \(url)")
            associateWithCurrentProfile(url: url)
            return
        }
        
        let podcast = Podcast(
            url: url,
            title: parsed.title,
            podcastDescription: parsed.description,
            logoUrl: parsed.logoUrl,
            website: parsed.website,
            author: parsed.author
        )
        podcast.sortOrder = subscriptions.count
        
        // Map new spec fields
        mapParsedPodcastMetadata(parsed, to: podcast)
        
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
        
        // Associate with current profile (does NOT reload subscriptions)
        associateWithCurrentProfile(url: url)
        
        logger.info("Persisted from sync: \(parsed.title) with \(episodes.count) episodes")
    }
    
    // MARK: - Groups Sync (YourPods Pro)

    /// Applies server groups locally **only if no local groups exist** (first-pull guard).
    /// If the user already has local groups, pushes local groups to the server instead.
    /// Call during Pro sync flow step 12.
    func applyServerGroups(_ serverGroups: [ProGroup], profileId: String) {
        let local = PodcastGroup.loadGroups(forProfileId: profileId)
        guard local.isEmpty else {
            // Guard: local groups exist — device wins, skip server overwrite
            logger.debug("Groups: local groups exist (\(local.count)) — skipping server pull")
            return
        }
        guard !serverGroups.isEmpty else { return }

        let mapped = serverGroups.map { pg in
            PodcastGroup(
                id: pg.id,
                name: pg.name,
                sortOrder: pg.sortOrder,
                iconName: pg.iconName,
                colorHex: pg.colorHex
            )
        }.sorted { $0.sortOrder < $1.sortOrder }

        PodcastGroup.saveGroups(mapped, forProfileId: profileId)
        logger.info("Groups: applied \(mapped.count) groups from server (first pull)")
    }

    /// Applies server group assignments to podcasts **only for podcasts with no existing groupId**.
    /// Podcasts already in a group keep their local assignment. Call during Pro sync step 13.
    func applyServerGroupAssignments(_ assignments: [ProGroupAssignment]) {
        var changed = false
        for assignment in assignments {
            guard let groupId = assignment.groupId else { continue }
            guard let podcast = subscriptions.first(where: { $0.url == assignment.podcastUrl }) else {
                continue
            }
            guard podcast.groupId == nil else {
                // Guard: podcast already has a local group assignment — device wins
                logger.debug("Groups: skipping server assignment for \(podcast.url) — already grouped locally")
                continue
            }
            podcast.groupId = groupId
            changed = true
        }
        if changed {
            try? saveContext()
            logger.info("Groups: applied server group assignments to ungrouped podcasts")
        }
    }

    /// Builds the `[ProGroup]` array for `POST /groups/sync` from local UserDefaults storage.
    func buildGroupsForSync(profileId: String) -> [ProGroup] {
        PodcastGroup.loadGroups(forProfileId: profileId).map { group in
            ProGroup(
                id: group.id,
                name: group.name,
                sortOrder: group.sortOrder,
                iconName: group.iconName,
                colorHex: group.colorHex
            )
        }
    }

    /// Builds the `[ProGroupAssignment]` array for `POST /groups/assignments/sync`.
    /// Only includes podcasts with a non-nil `groupId` (ungrouped = omit per spec).
    func buildGroupAssignmentsForSync() -> [ProGroupAssignment] {
        subscriptions.compactMap { podcast -> ProGroupAssignment? in
            guard let groupId = podcast.groupId else { return nil }
            return ProGroupAssignment(podcastUrl: podcast.url, groupId: groupId)
        }
    }

    /// Push-then-pull groups sync — the correct order to prevent deletion bounce-back.
    ///
    /// **Why push first?**
    /// If the app pulls before pushing, a user's local deletion gets overwritten by the
    /// stale server state, then the stale state is pushed back — the deletion is lost.
    ///
    /// **Algorithm:**
    /// 1. Build local groups payload and push to server (device wins → server is updated)
    /// 2. Pull server confirmation and apply to local (first-pull guard protects existing groups)
    ///
    /// - Parameters:
    ///   - profileName: The Pro profile name (e.g., `"yourpodspro"`).
    ///   - client: A `GroupsSyncCapable` — normally `YourPodsProClient`, or a spy in tests.
    func syncGroupsPushThenPull(profileName: String, client: some GroupsSyncCapable) async {
        let localGroups = buildGroupsForSync(profileId: profileName)

        // Step 1: PUSH — send local state to server first so deletions are applied
        do {
            try await client.syncGroups(profileName: profileName, groups: localGroups)
            logger.info("Groups pushed: \(localGroups.count) groups → server")
        } catch {
            logger.error("Groups push failed: \(error.localizedDescription) — skipping pull to avoid overwrite")
            // Guard: if push fails, do NOT pull — pulling stale server state would overwrite local deletions
            return
        }

        // Step 2: PULL — server now reflects our push; apply as confirmation
        do {
            if let response = try await client.getGroups(profileName: profileName) {
                // After a successful push, local already has the correct state.
                // applyServerGroups' first-pull guard will no-op (local is non-empty).
                // We call it anyway so a fresh device that just pushed its first empty state
                // can adopt any groups that exist on the server from other devices.
                applyServerGroups(response.groups, profileId: profileName)
                logger.info("Groups pull confirmed: server returned \(response.groups.count) groups")
            }
        } catch {
            // Pull failure is non-fatal — local state is already correct after the push
            logger.warning("Groups pull failed (non-fatal — local state preserved): \(error.localizedDescription)")
        }
    }


    
    /// Maximum number of concurrent RSS feed fetches.
    /// Balances speed vs memory/network pressure.
    private static let maxConcurrentFetches = 6

    // MARK: - Feed Result Application (Main Actor)

    /// Apply a pre-fetched RSS feed result to a podcast's SwiftData model.
    ///
    /// This method runs on `@MainActor` and handles all SwiftData mutations:
    /// updating podcast metadata, creating new episodes, and updating existing
    /// episode metadata. It does NOT call `modelContext.save()` — the caller
    /// is responsible for saving after all results are applied.
    ///
    /// Extracted from `refreshFeed(for:)` to separate network I/O (concurrent)
    /// from SwiftData mutations (sequential, main actor).
    ///
    /// - Parameters:
    ///   - result: The pre-fetched feed data (podcast metadata + episodes).
    ///   - podcast: The SwiftData `Podcast` model to update.
    /// - Returns: Array of newly created `Episode` objects.
    func applyFeedResult(_ result: FeedFetchResult, to podcast: Podcast) -> [Episode] {
        let parsed = result.parsed
        let parsedEpisodes = result.episodes

        // ── Update podcast metadata ──
        podcast.title = parsed.title
        podcast.podcastDescription = parsed.description
        podcast.logoUrl = parsed.logoUrl
        podcast.website = parsed.website
        podcast.author = parsed.author
        mapParsedPodcastMetadata(parsed, to: podcast)

        // ── Handle feed URL migration (itunes:new-feed-url) ──
        if let newUrl = parsed.newFeedUrl, !newUrl.isEmpty, newUrl != podcast.url {
            logger.warning("Feed \(podcast.title) declares new URL: \(newUrl). Auto-migrating.")
            let oldUrl = podcast.url
            podcast.url = newUrl
            podcast.newFeedUrl = nil  // Clear after migration
            disassociateFromCurrentProfile(url: oldUrl)
            associateWithCurrentProfile(url: newUrl)
            // Sync change to server (fire-and-forget — don't block save)
            if let client = syncClient {
                Task {
                    _ = try? await client.pushSubscriptions(add: [newUrl], remove: [oldUrl], deviceId: deviceId)
                }
            }
        }

        // ── Create new episodes / update existing ──
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

        // ── Mark stale episodes ──
        // Episodes that exist locally but are NOT in the current feed XML are stale.
        // Match by GUID (primary) with audio URL base-path fallback.
        let feedGuids = Set(parsedEpisodes.map(\.guid))
        let feedAudioBaseURLs = Set(parsedEpisodes.compactMap { ep -> String? in
            guard let url = ep.audioUrl else { return nil }
            return Self.stripQueryParams(url)
        })

        for localEp in podcast.episodes {
            let inFeedByGuid = feedGuids.contains(localEp.guid)
            let inFeedByURL: Bool = {
                guard let audioUrl = localEp.audioUrl else { return false }
                return feedAudioBaseURLs.contains(Self.stripQueryParams(audioUrl))
            }()

            if inFeedByGuid || inFeedByURL {
                // Episode is still in the feed — un-stale it (feed may re-add episodes)
                if localEp.isStale { localEp.isStale = false }
            } else {
                // Episode is no longer in the feed
                if !localEp.isStale { localEp.isStale = true }
            }
        }

        return newEpisodes
    }

    // MARK: - Per-Podcast Settings Sync

    /// Apply per-podcast setting overrides from the server to local Podcast models.
    /// Matches by podcastUrl and merges server payload into local settings using
    /// the `PodcastSettings.fromServerPayload()` mapping.
    ///
    /// **Important:** Podcasts with existing local overrides are skipped because
    /// the push-then-pull flow already sent them to the server. Applying stale
    /// server data on top would clobber the user's local edits (e.g. autopilot
    /// changes that haven't been reflected by the server yet).
    /// Podcasts without local overrides still receive server settings, enabling
    /// cross-device adoption (e.g. settings changed on the web player).
    func applyPerPodcastOverridesFromServer(_ overrides: [ProPodcastSetting]) {
        for override in overrides {
            guard let podcast = subscriptions.first(where: { $0.url == override.podcastUrl }) else {
                continue
            }
            let serverSettings = PodcastSettings.fromServerPayload(override.resolvedPayload)
            if podcast.effectiveSettings.hasOverrides {
                // Field-level merge: local overrides win for fields the user set,
                // server values fill in fields not set locally (cross-device adoption).
                // e.g. user set skipIntro on phone, web set skipOutro → both survive.
                let merged = podcast.effectiveSettings.merging(serverSettings: serverSettings)
                podcast.effectiveSettings = merged
                logger.debug("Per-podcast settings: field-level merge for \(podcast.url)")
            } else {
                // No local overrides — adopt server settings wholesale
                var merged = serverSettings
                if let existingExtras = podcast.settings?.serverExtras {
                    for (key, value) in existingExtras where merged.serverExtras[key] == nil {
                        merged.serverExtras[key] = value
                    }
                }
                podcast.effectiveSettings = merged
            }
        }
    }

    /// Collect all per-podcast settings that have overrides for pushing to the server.
    /// Returns an array of (podcastUrl, payload) tuples in server key format.
    func collectDirtyPodcastSettings() -> [(podcastUrl: String, payload: [String: AnyCodableValue])] {
        var result: [(podcastUrl: String, payload: [String: AnyCodableValue])] = []
        for podcast in subscriptions {
            let settings = podcast.effectiveSettings
            guard settings.hasOverrides || !settings.serverExtras.isEmpty else { continue }
            let payload = settings.toServerPayload()
            guard !payload.isEmpty else { continue }
            result.append((podcastUrl: podcast.url, payload: payload))
        }
        return result
    }

    /// Enable new-episode notifications for all current subscriptions.
    /// Called from the onboarding prompt when the user chooses "All Podcasts."
    /// Only sets `notificationsEnabled` — other Listening Profile settings are preserved.
    func enableNotificationsForAllPodcasts() {
        for podcast in subscriptions {
            podcast.effectiveSettings.notificationsEnabled = true
        }
        modelContext.safeSave()
        logger.info("Bulk-enabled notifications for \(self.subscriptions.count) podcasts")
    }

    
    func refreshAllFeeds() async -> [Episode] {
        isRefreshing = true
        defer { isRefreshing = false }
        
        let feedsToRefresh = subscriptions
        guard !feedsToRefresh.isEmpty else { return [] }
        
        // ── Phase 1: Concurrent network fetches ─────────────────────────
        // Only Sendable data (FeedFetchResult) crosses the actor boundary.
        // No SwiftData objects are accessed inside the TaskGroup.
        var fetchResults: [FeedFetchResult] = []
        
        for batchStart in stride(from: 0, to: feedsToRefresh.count, by: Self.maxConcurrentFetches) {
            let batchEnd = min(batchStart + Self.maxConcurrentFetches, feedsToRefresh.count)
            let batch = Array(feedsToRefresh[batchStart..<batchEnd])
            
            // Capture only Sendable values (URL strings, auth headers) before entering TaskGroup
            let fetchInputs: [(url: String, authHeader: String?)] = batch.map { podcast in
                let auth = podcast.requiresAuth
                    ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: podcast.url)
                    : nil
                return (url: podcast.url, authHeader: auth)
            }
            
            await withTaskGroup(of: FeedFetchResult?.self) { group in
                for input in fetchInputs {
                    let rss = self.rssService
                    group.addTask {
                        do {
                            let (parsed, episodes) = try await rss.fetchFeed(
                                url: input.url, authHeader: input.authHeader
                            )
                            return FeedFetchResult(
                                url: input.url,
                                authHeader: input.authHeader,
                                parsed: parsed,
                                episodes: episodes
                            )
                        } catch {
                            // Log errors — don't crash the batch for one feed
                            return nil
                        }
                    }
                }
                
                for await result in group {
                    if let result {
                        fetchResults.append(result)
                    }
                }
            }
        }
        
        // ── Phase 2: Sequential SwiftData mutations (@MainActor) ────────
        // All model access happens here on the main actor — no data races.
        var newEpisodes: [Episode] = []
        
        for result in fetchResults {
            // Match fetch result to its podcast by URL.
            // Use the result URL (not podcast.url) because feed migration may
            // have changed podcast.url during a previous applyFeedResult call.
            guard let podcast = subscriptions.first(where: { $0.url == result.url }) else {
                logger.warning("No subscription found for fetched URL: \(result.url)")
                continue
            }
            let created = applyFeedResult(result, to: podcast)
            newEpisodes.append(contentsOf: created)
        }
        
        // Single save for all mutations — much more efficient than per-feed saves
        modelContext.guardedSave(storeURL: YourPodsApp.modelStoreURL())
        
        logger.info("Refreshed all feeds: \(newEpisodes.count) new episodes found")
        return newEpisodes
    }
    
    // MARK: - Sync Building Blocks (called by SyncOrchestrators)

    /// Auto-queue and auto-download new episodes after an RSS refresh.
    ///
    /// Extracted from `refreshAndSync()` so all 3 orchestrators (Vault, gPodder, Pro)
    /// can call this shared logic after `refreshAllFeeds()`.
    func processNewEpisodes(
        _ newEpisodes: [Episode],
        playerManager: PlayerManager,
        downloadManager: DownloadManager,
        settingsManager: SettingsManager
    ) async {
        // Group new episodes by podcast URL
        let byPodcast = Dictionary(grouping: newEpisodes, by: { $0.podcastUrl ?? "" })

        for (podcastUrl, episodes) in byPodcast {
            guard let podcast = subscriptions.first(where: { $0.url == podcastUrl }) else { continue }
            let podSettings = podcast.effectiveSettings

            // Filter to only truly "new" unplayed episodes
            let markedBefore = podSettings.markedPlayedBefore
            let sessionInteracted = interactedKeys[podcastUrl] ?? []
            let newOnly = episodes.filter { ep in
                guard !ep.isPlayed else { return false }
                guard !ep.isInteracted else { return false }
                guard !sessionInteracted.contains(ep.guid) else { return false }
                if let markedBefore, let pubDate = ep.pubDate, pubDate <= markedBefore {
                    return false
                }
                return ep.audioUrl != nil
            }

            // Auto-queue new episodes from RSS
            let queueMode = podSettings.autoQueueMode ?? settingsManager.defaultAutoQueueMode
            if queueMode != .off {
                let sorted = newOnly.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                playerManager.addToQueue(sorted, playNext: queueMode == .priority)
            }

            // Auto-download (gated by network policy)
            let shouldDownload = podSettings.autoDownloadNewEpisodes ?? settingsManager.defaultAutoDownload
            if shouldDownload, isAutoDownloadAllowed(settingsManager: settingsManager) {
                for episode in newOnly {
                    if let audioUrl = episode.audioUrl, !downloadManager.isDownloaded(episode.guid) {
                        let authHeaders: [String: String]? = podcast.requiresAuth
                            ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: podcast.url)
                                .map { ["Authorization": $0] }
                            : nil
                        let privacyMode = podSettings.privacyMode ?? settingsManager.p3Enabled
                        downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl, authHeaders: authHeaders, privacyMode: privacyMode)
                    }
                }
            }
        }

        // Auto-queue existing unplayed episodes for all subscriptions
        autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)

        // Post local notifications for new episodes — LAST in the pipeline so
        // sync + queue + downloads are never starved of background task time.
        // Global toggle is the kill switch; per-podcast is opt-in.
        // IMPORTANT: Awaited directly (not fire-and-forget Task) so the background
        // task doesn't call setTaskCompleted() before notifications are posted.
        logger.info("Notification pipeline: \(newEpisodes.count) new episode(s) from refreshAllFeeds, globalToggle=\(settingsManager.newEpisodeNotificationsEnabled)")
        if settingsManager.newEpisodeNotificationsEnabled {
            let episodesToNotify = newEpisodes.filter { episode in
                // Opt-in: only notify for podcasts with explicit notificationsEnabled = true
                let enabled = episode.podcast?.effectiveSettings.notificationsEnabled == true
                if !enabled {
                    logger.debug("Notification pipeline: skipping '\(episode.title)' — podcast '\(episode.podcast?.title ?? "nil")' notificationsEnabled=\(String(describing: episode.podcast?.effectiveSettings.notificationsEnabled))")
                }
                return enabled
            }
            logger.info("Notification pipeline: \(episodesToNotify.count)/\(newEpisodes.count) episode(s) passed per-podcast opt-in filter")
            if !episodesToNotify.isEmpty {
                await NewEpisodeNotificationService.shared.postNewEpisodeNotifications(episodesToNotify)
            }
        } else {
            logger.info("Notification pipeline: skipped — global toggle is OFF")
        }
        
        // Update app icon badge count — independent from notifications.
        // Users can enable badges, notifications, or both.
        if let badgeService {
            await badgeService.updateBadgeCount()
        }
    }

    /// Sync subscriptions with auto-retry on empty library.
    ///
    /// Extracted from `refreshAndSync()` so gPodder and Pro orchestrators
    /// can call this without duplicating the retry/recovery logic.
    ///
    /// - Returns: `true` if a fatal auth error occurred and sync should stop.
    func syncSubscriptionsWithRecovery() async -> Bool {
        do {
            _ = try await syncSubscriptions()
            lastSyncError = nil
            return false
        } catch let proError as YourPodsProError
            where proError == .forbidden || proError == .unauthorized {
            logger.error("Sync blocked (\(proError.errorDescription ?? "")): stopping refresh")
            lastSyncError = proError.errorDescription
            isRefreshing = false
            return true   // fatal — caller should abort
        } catch {
            // ── Cancellation guard ──────────────────────────────────────────
            // When the app transitions to background, foregroundSyncTask?.cancel()
            // cancels in-flight URLSession calls, producing URLError(.cancelled).
            // This is an expected lifecycle event, NOT a connectivity failure.
            // Suppress it from the user-facing banner.
            if Task.isCancelled || error.isCancellationError {
                logger.info("Subscription sync cancelled — suppressing error banner")
                return false
            }
            
            logger.error("Subscription sync failed: \(error.localizedDescription)")
            lastSyncError = error.localizedDescription

            // Auto-retry once if the library is empty — catches post-recovery transient failures.
            if subscriptions.isEmpty {
                logger.warning("Library is empty after sync failure — retrying once after delay...")
                try? await Task.sleep(for: .seconds(2))
                do {
                    _ = try await syncSubscriptions()
                    lastSyncError = nil
                    logger.info("Subscription sync retry succeeded — library restored")
                } catch {
                    logger.error("Subscription sync retry also failed: \(error.localizedDescription)")
                    lastSyncError = error.localizedDescription
                }
            }
            return false
        }
    }

    /// Refresh feeds, auto-queue new episodes, and auto-download based on per-podcast settings.
    /// This is the "Refresh & Sync" button action.
    ///
    /// Delegates all work to the appropriate `SyncOrchestrator` via `SyncOrchestratorFactory`.
    /// The factory selects the orchestrator based on the active profile type:
    /// - **Vault**: RSS refresh only, no server contact.
    /// - **gPodder**: Subscriptions → RSS → episode actions.
    /// - **Pro**: Settings → subscriptions → RSS → episode actions → stats → groups → queue.
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
        isSyncing = true
        defer { isSyncing = false }
        
        let orchestrator = SyncOrchestratorFactory.make(
            profile: settingsManager.activeProfile,
            podcastManager: self,
            syncClient: syncClient
        )

        return await orchestrator.sync(
            podcastManager: self,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: strategy
        )
    }
    
    /// Whether the current network conditions allow autodownloads,
    /// based on the user's `autoDownloadNetworkPolicy` setting and
    /// the current network type from `networkMonitor`.
    ///
    /// - Returns: `true` if autodownloads should proceed on the current network.
    ///   Falls back to `true` if no `networkMonitor` is available (safety fallback).
    func isAutoDownloadAllowed(settingsManager: SettingsManager) -> Bool {
        let policy = settingsManager.autoDownloadNetworkPolicy
        guard let monitor = networkMonitor else {
            // Guard: no network monitor available — allow downloads as a safe fallback
            logger.debug("No network monitor available — allowing autodownload by default")
            return true
        }
        let allowed = policy.shouldDownload(isExpensive: monitor.isExpensive)
        if !allowed {
            logger.info("Autodownload skipped: policy=\(policy.rawValue), isExpensive=\(monitor.isExpensive)")
        }
        return allowed
    }
    
    func refreshFeed(for podcast: Podcast) async throws -> [Episode] {
        let authHeader = podcast.requiresAuth
            ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: podcast.url)
            : nil
        
        // ── Network fetch (off main actor is fine) ───────────────────────
        let (parsed, parsedEpisodes) = try await rssService.fetchFeed(url: podcast.url, authHeader: authHeader)
        
        // ── SwiftData mutations (already on @MainActor via PodcastManager) ──
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
            // Sync change to server (fire-and-forget — don't block save)
            if let client = syncClient {
                Task {
                    _ = try? await client.pushSubscriptions(add: [newUrl], remove: [oldUrl], deviceId: deviceId)
                }
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
        
        modelContext.guardedSave(storeURL: YourPodsApp.modelStoreURL())
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
    
    /// Checks if an episode is marked as played in SwiftData by its GUID.
    /// Used by post-sync queue cleanup to determine if queue items should be removed.
    func isEpisodePlayed(guid: String) -> Bool {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == guid }
        )
        guard let episode = try? modelContext.fetch(descriptor).first else {
            return false  // No match in SwiftData — can't determine status
        }
        return episode.isPlayed
    }
    
    // MARK: - Auto-Queue Candidates
    
    func getAutoQueueCandidates(for podcast: Podcast, globalDefault: AutoQueueMode = .off) -> [Episode] {
        let settings = podcast.effectiveSettings
        let mode = settings.autoQueueMode ?? globalDefault
        guard mode != .off else { return [] }
        
        let markedBefore = settings.markedPlayedBefore
        let interacted = interactedKeys[podcast.url] ?? []
        
        return podcast.episodes.filter { episode in
            // Skip if stale (no longer in feed)
            guard !episode.isStale else { return false }
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
    ///
    /// The in-memory model (`episode.listenedSeconds`) is updated immediately so SwiftUI
    /// progress bars stay responsive. Disk persistence (`modelContext.save()`) is throttled
    /// to `progressSaveInterval` (60s) to stay within the iOS disk write budget.
    /// Critical save points (pause, backgrounding, episode completion) call
    /// `flushProgressToDisk()` to bypass the throttle.
    func updateEpisodeProgress(podcastUrl: String, episodeGuid: String, position: Int) {
        guard let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
              let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }),
              episode.listenedSeconds != position else { return }
        
        // Always update in-memory — SwiftUI observes this immediately
        episode.listenedSeconds = position
        
        // Throttle disk saves to reduce SQLite write pressure.
        // Critical save points (background, pause) call flushProgressToDisk() directly.
        let now = Date()
        guard now.timeIntervalSince(lastProgressSaveTime) >= Self.progressSaveInterval else { return }
        lastProgressSaveTime = now
        modelContext.safeSave()
        
        // Budget monitoring — log periodically so device logs show if we approach limits
        progressSaveCount += 1
        if progressSaveCount % 60 == 0 {
            logger.info("Progress save budget: \(self.progressSaveCount) saves this session")
        }
    }
    
    /// Force-save any dirty progress to disk, bypassing the throttle.
    /// Called on pause, backgrounding, and episode completion to ensure
    /// no position data is lost if the app is killed.
    func flushProgressToDisk() {
        if modelContext.safeSave() {
            lastProgressSaveTime = Date()
        }
    }
    
    /// Test-only: override lastProgressSaveTime to simulate time passing.
    func testOverrideLastProgressSaveTime(_ date: Date) {
        lastProgressSaveTime = date
    }
    
    /// Update episode progress by guid only (used for conflict resolution where podcastUrl is unknown).
    func updateEpisodeProgressByGuid(episodeGuid: String, position: Int) {
        for podcast in subscriptions {
            if let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }),
               episode.listenedSeconds != position {
                episode.listenedSeconds = position
                modelContext.safeSave()
                return
            }
        }
    }
    
    func markEpisodeAsInteracted(_ podcastUrl: String, _ episodeGuid: String, deferSave: Bool = false) {
        var keys = interactedKeys[podcastUrl] ?? []
        keys.insert(episodeGuid)
        interactedKeys[podcastUrl] = keys
        
        // Also update the SwiftData model so HomeView's recentEpisodes filter sees the change
        if let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
           let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }) {
            episode.isInteracted = true
            if !deferSave {
                modelContext.safeSave()
            }
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
        modelContext.safeSave()
        
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
        
        // Push completed=true to Pro server so other devices see the episode as finished.
        // Without this, only natural playback completion (handleEpisodeCompleted) sent
        // the completed flag — manual "Mark as Played" was invisible to cross-device sync.
        if let syncClient {
            let device = deviceId
            Task {
                try? await syncClient.syncPlayback(
                    podcastUrl: podcastUrl,
                    episodeUrl: audioUrl,
                    episodeGuid: episodeGuid,
                    positionSec: Double(total),
                    durationSec: Double(total),
                    nowPlaying: false,
                    completed: true,
                    deviceId: device
                )
            }
        }
        
        handleDownloadCleanup(for: episodeGuid, podcastUrl: podcastUrl)
        
        logger.info("Marked episode \(episodeGuid) as played")
    }
    
    /// Mark an episode as played locally (sets isPlayed flag only, no server action).
    /// Used by handleEpisodeCompleted which sends its own EpisodeAction separately.
    func markEpisodePlayedLocally(podcastUrl: String, episodeGuid: String) {
        markEpisodeAsInteracted(podcastUrl, episodeGuid)
        
        if let podcast = subscriptions.first(where: { $0.url == podcastUrl }),
           let episode = podcast.episodes.first(where: { $0.guid == episodeGuid }) {
            episode.isPlayed = true
            modelContext.safeSave()
            logger.info("Marked episode \(episodeGuid) as played (local only)")
            
            handleDownloadCleanup(for: episodeGuid, podcastUrl: podcastUrl)
        }
    }
    
    /// Mark an episode as unplayed (resets position)
    func markEpisodeAsUnplayed(podcastUrl: String, episodeGuid: String) {
        let podcast = subscriptions.first { $0.url == podcastUrl }
        let episode = podcast?.episodes.first { $0.guid == episodeGuid }
        
        episode?.isPlayed = false
        episode?.listenedSeconds = 0
        modelContext.safeSave()
        
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
        var modified = false
        
        for episode in podcast.episodes {
            if !episode.isStale && !episode.isPlayed {
                episode.isPlayed = true
                if let total = episode.durationSeconds {
                    episode.listenedSeconds = total
                }
                modified = true
                handleDownloadCleanup(for: episode.guid, podcastUrl: podcast.url)
                
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
                episodeActionSync.sendActionLocally(action)
            }
        }
        
        guard modified else { return }
        
        modelContext.safeSave()
        episodeActionSync.forcePersistActionMap()
        
        let count = actions.count
        logger.info("Marked \(count) episodes as played for \(podcast.title)")
        
        // Batch upload to server
        guard !actions.isEmpty else { return }
        Task {
            guard let client = syncClient else { return }
            // Upload in batches of 50 to avoid oversized requests
            for batch in stride(from: 0, to: actions.count, by: 50) {
                let end = min(batch + 50, actions.count)
                let slice = Array(actions[batch..<end])
                _ = try? await client.uploadEpisodeActions(slice)
            }
            logger.info("Uploaded \(count) play actions to server")
            
            // Push completed=true for each episode to the Pro playback endpoint.
            let device = self.deviceId
            for action in actions {
                try? await client.syncPlayback(
                    podcastUrl: action.podcast,
                    episodeUrl: action.episode,
                    episodeGuid: action.guid,
                    positionSec: Double(action.total ?? 0),
                    durationSec: Double(action.total ?? 0),
                    nowPlaying: false,
                    completed: true,
                    deviceId: device
                )
            }
        }
    }
    
    // MARK: - gPodder Sync
    
    /// Pull subscription list from server and subscribe to any missing feeds.
    /// Also pushes any local-only subscriptions and pending removals to the server.
    /// Returns any URL rewrites from the server that need to be handled.
    ///
    /// ⚠️ Push-first invariant: pending removals are pushed BEFORE pulling server state.
    /// This prevents the "delete bounce-back" bug where a server pull re-adds a locally
    /// deleted subscription. Same pattern used for groups sync.
    func syncSubscriptions() async throws -> [URLRewriteConflict] {
        guard let client = syncClient else {
            logger.info("No sync client configured, skipping subscription sync")
            return []
        }

        let profileId = activeProfileId ?? "global"
        let since = UserDefaults.standard.integer(forKey: "lastSubscriptionSync_\(profileId)")
        logger.info("Syncing subscriptions since \(since)...")

        // ── Step 1: Push pending removals FIRST (push-first invariant) ──────────
        // If the user deleted podcasts since the last sync (including while offline),
        // push those removals before we pull, so the server reflects the deletion
        // before we merge its response into local state.
        //
        // ⚠️ We only clear a URL from pending removals after a CONFIRMED successful push.
        // If the push fails (network, token, server error), the URL stays in pending
        // and will be retried on the next sync.
        let pendingRemovals = pendingSubscriptionRemovals()
        var successfullyPushedRemovals: Set<String> = []
        if !pendingRemovals.isEmpty {
            let removalArray = Array(pendingRemovals)
            logger.info("Pushing \(removalArray.count) pending subscription removals before pull: \(removalArray)")
            do {
                _ = try await client.pushSubscriptions(add: [], remove: removalArray, deviceId: deviceId)
                successfullyPushedRemovals = pendingRemovals
                logger.info("Successfully pushed \(removalArray.count) subscription removal(s) to server")
            } catch {
                // Push failed — leave URLs in pendingRemovals so they retry next sync.
                // We still continue with the pull since the filteredAdditions guard will
                // prevent bounce-back for this sync cycle.
                logger.error("Failed to push pending subscription removals — will retry on next sync: \(error.localizedDescription)")
            }
        }


        // ── Step 2: Pull server state ─────────────────────────────────────────
        let delta = try await client.pullSubscriptionChanges(deviceId: deviceId, since: since)

        // ── Step 3: Apply server removals ─────────────────────────────────────
        for removeUrl in delta.remove {
            disassociateFromCurrentProfile(url: removeUrl)
            if let podcast = subscriptions.first(where: { $0.url == removeUrl }) {
                modelContext.delete(podcast)
                logger.info("Removed subscription (server initiated): \(removeUrl)")
            }
        }

        // ── Step 4: Apply server additions — but filter out locally-deleted URLs ─
        // If the server still returns a URL we locally deleted (it may not have
        // processed our push yet, or this is a delta window edge case), do NOT
        // re-add it. This is the bounce-back guard.
        let filteredAdditions = delta.add.filter { !pendingRemovals.contains($0) }
        if filteredAdditions.count < delta.add.count {
            let filtered = delta.add.count - filteredAdditions.count
            logger.info("Filtered \(filtered) bounce-back URL(s) from server add list (pending removal)")
        }

        
        // Associate the filtered server URLs with profile (handles cross-profile scenarios)
        for feedUrl in filteredAdditions {
            associateWithCurrentProfile(url: feedUrl)
        }

        // Filter to only truly new URLs that need fetching
        let newUrls = filterNewSubscriptionUrls(filteredAdditions)
        logger.info("Subscription sync: \(filteredAdditions.count) from server (after bounce-back filter), \(newUrls.count) new to fetch")

        // Fetch and persist new feeds concurrently (batch of maxConcurrentFetches at a time)
        var addedCount = 0
        if !newUrls.isEmpty {
            subscriptionSyncProgress = (completed: 0, total: newUrls.count)

            let batchSaveInterval = 10

            for batchStart in stride(from: 0, to: newUrls.count, by: Self.maxConcurrentFetches) {
                let batchEnd = min(batchStart + Self.maxConcurrentFetches, newUrls.count)
                let batch = Array(newUrls[batchStart..<batchEnd])

                // Fetch RSS feeds concurrently via RSSService actor
                let results = await withTaskGroup(
                    of: (String, ParsedPodcast, [ParsedEpisode])?.self
                ) { group -> [(String, ParsedPodcast, [ParsedEpisode])] in
                    for feedUrl in batch {
                        group.addTask { [weak self] in
                            guard let self else { return nil }
                            do {
                                let (parsed, episodes) = try await self.rssService.fetchFeed(url: feedUrl)
                                return (feedUrl, parsed, episodes)
                            } catch {
                                await MainActor.run {
                                    self.logger.error("Failed to fetch \(feedUrl): \(error.localizedDescription)")
                                }
                                return nil
                            }
                        }
                    }

                    var collected: [(String, ParsedPodcast, [ParsedEpisode])] = []
                    for await result in group {
                        if let result { collected.append(result) }
                    }
                    return collected
                }

                // Persist results on main actor (we're already @MainActor)
                for (feedUrl, parsed, episodes) in results {
                    persistPodcastFromSync(url: feedUrl, parsed: parsed, episodes: episodes)
                    addedCount += 1
                    subscriptionSyncProgress = (completed: addedCount, total: newUrls.count)
                    logger.info("Added subscription from server (\(addedCount)/\(newUrls.count)): \(parsed.title)")
                }

                // Batch save every N podcasts to prevent memory buildup
                if addedCount % batchSaveInterval == 0 || batchEnd == newUrls.count {
                    modelContext.safeSave()
                }
            }

            subscriptionSyncProgress = nil
        }

        // ── Step 5: Push pending adds, apply remote deletions, clear pending queues ─
        //
        // SERVER-AUTHORITATIVE MODEL:
        //   - Only push URLs the user explicitly added on this device (pendingAdds).
        //   - If a URL is local, NOT on server, and NOT a pending add → another device
        //     deleted it → remove it locally.
        //
        // This replaces the old "push all local-only URLs" approach which re-added
        // podcasts deleted from the web/server by treating them as pending adds.

        var allRewrites: [URLRewrite] = []
        let serverUrls = Set(filteredAdditions)
        let pendingAdds = pendingSubscriptionAdds()
        loadSubscriptions()

        // Step 5a: Push pending adds (only URLs this device explicitly added)
        let urlsToAdd = localSubscriptionsToUpload(serverUrls: serverUrls)  // now returns pendingAdds − serverUrls
        var successfullyPushedAdds: Set<String> = []
        if !urlsToAdd.isEmpty {
            logger.info("Pushing \(urlsToAdd.count) pending local add(s) to server: \(urlsToAdd)")
            do {
                let rewrites = try await client.pushSubscriptions(add: urlsToAdd, remove: [], deviceId: deviceId)
                successfullyPushedAdds = Set(urlsToAdd)
                allRewrites.append(contentsOf: rewrites)
                logger.info("Pushed \(urlsToAdd.count) pending add(s) to server")
            } catch {
                // Leave in pendingAdds — will retry next sync
                logger.error("Failed to push pending adds — will retry next sync: \(error.localizedDescription)")
            }
        }

        // Step 5b: Apply remote deletions
        // Safe when the server response represents the COMPLETE subscription list:
        //   - Full sync (since=0): delta.add is the full list for any client
        //   - Full-list clients (YourPods Pro): delta.add is ALWAYS the full list
        // During incremental syncs (since>0) for delta clients (gPodder), delta.add
        // only contains new additions — comparing against it would wipe the library.
        // Explicit server removals during incremental syncs are handled by Step 3.
        let isFullList = await (client.returnsFullSubscriptionList) || since == 0
        var remoteDeleteCount = 0
        if isFullList {
            let localUrls = Set(subscriptions.map(\.url))
            let remotelyDeleted = localUrls
                .subtracting(serverUrls)          // server doesn't have it
                .subtracting(pendingAdds)          // user didn't add it locally
                .subtracting(pendingRemovals)      // not already mid-removal

            remoteDeleteCount = remotelyDeleted.count
            if !remotelyDeleted.isEmpty {
                logger.info("Disassociating \(remotelyDeleted.count) remote deletion(s) from profile: \(remotelyDeleted)")
                for url in remotelyDeleted {
                    disassociateFromCurrentProfile(url: url)
                    // Do NOT delete Podcast from SwiftData — it may belong to other
                    // profiles or be recoverable. Explicit deletions via delta.remove
                    // (Step 3) and user action are the only safe deletion paths.
                    logger.info("Disassociated from profile (deleted from another device): \(url)")
                }
            }
        } else {
            logger.debug("Skipping remote deletion check — incremental sync (since=\(since)); explicit removals handled in Step 3")
        }

        UserDefaults.standard.set(delta.timestamp, forKey: "lastSubscriptionSync_\(profileId)")
        modelContext.safeSave()
        loadSubscriptions()

        // Step 5c: Clear confirmed pending queues
        for url in successfullyPushedAdds    { clearPendingSubscriptionAdd(url) }
        for url in successfullyPushedRemovals { clearPendingSubscriptionRemoval(url) }
        if !successfullyPushedAdds.isEmpty {
            logger.info("Cleared \(successfullyPushedAdds.count) confirmed add(s) from pending set")
        }
        if !successfullyPushedRemovals.isEmpty {
            logger.info("Cleared \(successfullyPushedRemovals.count) confirmed removal(s) from pending set")
        }

        logger.info("Subscription sync complete: \(addedCount) added, \(delta.remove.count) server-removed, \(remoteDeleteCount) remote-deleted")

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

    // MARK: - Episode Action Sync (forwarded to EpisodeActionSyncService)
    
    func syncEpisodeActions(force: Bool = true, strategy: SyncStrategy = .serverWins) async throws -> [SyncConflict] {
        try await episodeActionSync.syncEpisodeActions(force: force, strategy: strategy)
    }
    
    @discardableResult
    func applyEpisodeActions(strategy: SyncStrategy = .serverWins) -> [SyncConflict] {
        episodeActionSync.applyEpisodeActions(strategy: strategy)
    }
    
    func applyEpisodeActionsAsync(strategy: SyncStrategy = .serverWins) async -> [SyncConflict] {
        await episodeActionSync.applyEpisodeActionsAsync(strategy: strategy)
    }
    
    func applyEpisodeActionsWithStatsAsync(strategy: SyncStrategy = .serverWins) async -> ([SyncConflict], Int) {
        await episodeActionSync.applyEpisodeActionsWithStatsAsync(strategy: strategy)
    }
    
    func applyEpisodeActionsWithStats(strategy: SyncStrategy = .serverWins) -> ([SyncConflict], Int) {
        episodeActionSync.applyEpisodeActionsWithStats(strategy: strategy)
    }
    
    func applyEpisodeActionsCore(strategy: SyncStrategy, cooperative: Bool) async -> ([SyncConflict], Int) {
        await episodeActionSync.applyEpisodeActionsCore(strategy: strategy, cooperative: cooperative)
    }
    
    func sendEpisodeAction(_ action: EpisodeAction) async {
        await episodeActionSync.sendEpisodeAction(action)
    }
    
    /// Queue an episode action locally without pushing to the server.
    /// The action is written to the `actionMap` for deferred server push
    /// on the next foreground sync cycle. Used by `forceSyncProgress()`
    /// to avoid spawning async Tasks during app backgrounding (0xDEAD10CC fix).
    func queueEpisodeAction(_ action: EpisodeAction) {
        episodeActionSync.sendActionLocally(action)
    }
    
    func getLatestAction(for guid: String) -> EpisodeAction? {
        episodeActionSync.getLatestAction(for: guid)
    }
    
    // MARK: - Conflict Resolution (forwarded)
    
    func resolveConflict(_ conflict: SyncConflict, chosenPosition: Int) {
        episodeActionSync.resolveConflict(conflict, chosenPosition: chosenPosition)
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
        
        modelContext.safeSave()
        loadSubscriptions()
        
        logger.info("Accepted URL rewrite: \(oldUrl) → \(rewrite.newUrl)")
    }
    
    /// Reject a server URL rewrite — keep the local URL unchanged.
    func rejectUrlRewrite(_ rewrite: URLRewriteConflict) {
        logger.info("Rejected URL rewrite for \(rewrite.oldUrl) → \(rewrite.newUrl). Keeping local URL.")
    }
    
    // MARK: - Action Map Persistence (forwarded)
    
    func loadActionMap() {
        episodeActionSync.loadActionMap()
    }
    
    func loadConflictCounts() {
        episodeActionSync.loadConflictCounts()
    }
    
    // MARK: - Profile Cleanup
    
    /// Remove all UserDefaults data associated with a profile.
    /// Call this before or after removing the profile from the profiles list.
    func clearProfileData(profileId: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "subscriptionUrls_\(profileId)")
        defaults.removeObject(forKey: "lastSubscriptionSync_\(profileId)")
        defaults.removeObject(forKey: "lastEpisodeActionSync_\(profileId)")
        defaults.removeObject(forKey: "pendingSubscriptionAdds_\(profileId)")
        defaults.removeObject(forKey: "pendingSubscriptionRemovals_\(profileId)")
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
    
    // MARK: - URL Comparison Helpers
    
    /// Strip query parameters from a URL string for base-path comparison.
    /// Handles Megaphone's `?updated=TIMESTAMP` cache-busters and similar
    /// query-param variations that change the URL without changing the content.
    static func stripQueryParams(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        comps.query = nil
        comps.fragment = nil
        return comps.string ?? urlString
    }
    
    // MARK: - Action Map Pruning (P2-1)

    
    /// Maximum age (in seconds) for action map entries from unsubscribed podcasts.
    /// Entries for *subscribed* podcasts are always kept regardless of age.
    private static let pruneMaxAge: TimeInterval = 90 * 86400 // 90 days
    
    /// Prune stale entries from the action map.
    ///
    /// Removes entries where:
    /// - The podcast is NOT in the current subscriptions, AND
    /// - The action timestamp is older than `pruneMaxAge` (90 days).
    ///
    /// Entries for subscribed podcasts are always kept (even if old) because
    /// they may still be needed for sync conflict detection.
    func pruneActionMap() {
        let subscribedUrls = Set(subscriptions.map(\.url))
        let cutoff = Int(Date().timeIntervalSince1970) - Int(Self.pruneMaxAge)
        
        var pruned = actionMap
        var removeCount = 0
        for (guid, action) in pruned {
            // Keep if the podcast is still subscribed
            if subscribedUrls.contains(action.podcast) { continue }
            // Remove if older than 90 days AND unsubscribed
            if action.timestamp < cutoff {
                pruned.removeValue(forKey: guid)
                removeCount += 1
            }
        }
        
        if removeCount > 0 {
            episodeActionSync.replaceActionMap(pruned)
            logger.info("Pruned \(removeCount) stale action map entries (unsubscribed, >90d)")
        }
    }
    
    // MARK: - Crash-Safe Batch Uploads (P1-2)
    
    private static let pendingUploadGuidsKey = "pendingUploadGuids"
    
    /// GUIDs of episode actions that have been buffered locally but not yet
    /// confirmed uploaded to the server. Persisted to UserDefaults so they
    /// survive crashes between buffer and flush.
    var pendingUploadGuids: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.pendingUploadGuidsKey),
                  let guids = try? JSONDecoder().decode(Set<String>.self, from: data) else {
                return []
            }
            return guids
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.pendingUploadGuidsKey)
            }
        }
    }
    
    /// Buffer an episode action for later batch upload.
    /// The action is stored in the action map immediately (persist-first)
    /// and the GUID is added to the pending upload set.
    func bufferEpisodeAction(_ action: EpisodeAction) {
        // Store in action map immediately (already persisted by episodeActionSync)
        episodeActionSync.sendActionLocally(action)
        episodeActionSync.forcePersistActionMap()
        
        // Track as pending upload
        var pending = pendingUploadGuids
        if let guid = action.guid {
            pending.insert(guid)
        }
        pendingUploadGuids = pending
    }
    
    /// Flush all pending buffered actions to the server.
    /// On success, clears the pending set. On failure, GUIDs remain pending
    /// for retry on the next flush.
    func flushPendingActions() async {
        guard let client = syncClient else { return }
        let pending = pendingUploadGuids
        guard !pending.isEmpty else { return }
        
        // Collect actions from the action map for all pending GUIDs
        let actionsToUpload = pending.compactMap { actionMap[$0] }
        guard !actionsToUpload.isEmpty else {
            // GUIDs exist but actions don't — stale pending set, clear it
            pendingUploadGuids = []
            return
        }
        
        do {
            _ = try await client.uploadEpisodeActions(actionsToUpload)
            // Success — clear pending set
            pendingUploadGuids = []
            logger.info("Flushed \(actionsToUpload.count) pending episode actions to server")
        } catch {
            logger.error("Failed to flush pending actions — will retry: \(error.localizedDescription)")
            // Leave pendingUploadGuids intact for retry
        }
    }
}

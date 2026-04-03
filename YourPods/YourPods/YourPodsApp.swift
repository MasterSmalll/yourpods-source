import SwiftUI
import SwiftData
import os

@main
struct YourPodsApp: App {
    private static let logger = Logger(subsystem: "com.yourpods", category: "app")
    let modelContainer: ModelContainer
    @State private var audioManager: AudioManager
    @State private var settingsManager: SettingsManager
    @State private var playerManager: PlayerManager
    @State private var podcastManager: PodcastManager
    @State private var navigationState: NavigationState
    @State private var sleepTimerManager: SleepTimerManager
    @State private var downloadManager: DownloadManager
    
    @Environment(\.scenePhase) private var scenePhase
    
    /// Changing this forces a complete tear-down and rebuild of the view tree.
    @State private var viewTreeId = UUID()
    
    /// Key for storing the last-launched build number.
    private static let lastBuildKey = "lastLaunchedBuildNumber"
    
    /// Sentinel key: set before a heavy save, cleared after.
    /// If still set on next launch, the previous save crashed the process.
    private static let saveSentinelKey = "saveSentinelInProgress"
    
    /// The current build number from the bundle.
    private static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    
    init() {
        // ── Stamp the current build number ──
        let lastBuild = UserDefaults.standard.string(forKey: Self.lastBuildKey) ?? ""
        if Self.currentBuild != lastBuild {
            UserDefaults.standard.set(Self.currentBuild, forKey: Self.lastBuildKey)
        }
        
        // ── Crash sentinel check ──
        // If the sentinel is still set from a previous launch, it means
        // modelContext.save() crashed the process (signal crash, not a Swift error).
        // Nuke the store so we can start clean.
        if UserDefaults.standard.bool(forKey: Self.saveSentinelKey) {
            Self.logger.warning("Save sentinel detected — previous launch crashed during save. Deleting store...")
            UserDefaults.standard.set(false, forKey: Self.saveSentinelKey)
            Self.deleteStoreFiles()
        }
        
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        // If Flutter migration is needed, clear any iOS Saved Application State to prevent 
        // a black screen caused by iOS attempting to resume the old Flutter AppDelegate lifecycle.
        // Also delete any stale SwiftData store from previous Swift development builds.
        if FlutterDataMigrator.needsMigration {
            // Delete Saved Application State
            if let bundleID = Bundle.main.bundleIdentifier,
               let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                let savedStateURL = libraryPath.appendingPathComponent("Saved Application State/\(bundleID).savedState")
                try? FileManager.default.removeItem(at: savedStateURL)
            }
            
            // Delete stale SwiftData store
            Self.deleteStoreFiles()
        }
        
        // ── Create ModelContainer with corruption recovery ──
        // Step 1: Create the container (catches schema migration failures)
        var container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            Self.deleteStoreFiles()
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
        
        // Step 2: Write health probe — exercises the same SQLite page-write paths
        // that crash with pread() on a corrupted store. A read-only fetch won't
        // catch corruption in writable pages.
        //
        // The probe sets a UserDefaults sentinel BEFORE calling save().
        // If pread() kills the process with a signal crash (which do/catch
        // cannot intercept), the sentinel will still be set on next launch,
        // triggering automatic store deletion (see sentinel check above).
        let storeCorrupted = StoreHealthProbe.run(
            context: container.mainContext,
            sentinelKey: Self.saveSentinelKey
        )
        
        if storeCorrupted {
            Self.logger.warning("SQLite store corruption detected — auto-recovering...")
            Self.deleteStoreFiles()
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer after corruption recovery: \(error)")
            }
            Self.logger.info("Store rebuilt. Data will re-sync from server.")
        }
        
        modelContainer = container
        
        let audio = AudioManager()
        let settings = SettingsManager()
        let player = PlayerManager(audioManager: audio)
        let podcast = PodcastManager(modelContext: modelContainer.mainContext)
        let navState = NavigationState()
        
        player.podcastManager = podcast
        player.settingsManager = settings
        
        let download = DownloadManager()
        player.downloadManager = download
        
        // Apply headphone/remote command action settings at startup
        audio.nextTrackAction = settings.nextTrackAction
        audio.previousTrackAction = settings.previousTrackAction
        
        _audioManager = State(initialValue: audio)
        _settingsManager = State(initialValue: settings)
        _playerManager = State(initialValue: player)
        _podcastManager = State(initialValue: podcast)
        _navigationState = State(initialValue: navState)
        _downloadManager = State(initialValue: download)
        
        // Wire sleep timer to pause playback on expiry
        let sleepTimer = SleepTimerManager()
        sleepTimer.onTimerExpired = { [weak audio] in
            audio?.pause()
        }
        _sleepTimerManager = State(initialValue: sleepTimer)
        
        // Wire "End of Episode" mode: when active, stop after current episode
        audio.shouldAutoAdvanceToNextEpisode = { [weak sleepTimer] in
            guard let sleepTimer else { return true }
            if sleepTimer.stopAfterCurrentEpisode {
                sleepTimer.cancelEndOfEpisode()
                return false
            }
            return true
        }
        
        // ── Migrate passwords from UserDefaults to Keychain (one-time) ──
        KeychainHelper.migrateFromUserDefaultsIfNeeded()
        KeychainHelper.migratePodcastIndexCredsFromUserDefaultsIfNeeded()
        
        // ── Wire GPodder client from saved active profile ──
        if let activeId = settings.activeProfileId,
           let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data),
           let active = profiles.first(where: { $0.id == activeId }),
           !active.isLocal,
           let baseUrl = active.baseUrl,
           let username = active.username {
            let password = KeychainHelper.shared.password(forProfileId: active.id) ?? ""
            let client = GPodderClient(baseUrl: baseUrl, username: username, password: password)
            podcast.setGPodderClient(client, deviceId: active.deviceId)
            player.setGPodderClient(client, deviceId: active.deviceId)
        }
        
        // Restore persisted episode action map and apply to episodes
        podcast.loadActionMap()
        podcast.loadConflictCounts()
        
        // Set sentinel before the heavy save — if this crashes the process,
        // the sentinel will be detected on next launch to auto-recover.
        UserDefaults.standard.set(true, forKey: Self.saveSentinelKey)
        podcast.applyEpisodeActions(strategy: settings.syncConflictStrategy)
        UserDefaults.standard.set(false, forKey: Self.saveSentinelKey)
        
        // ── P0: Wire service singletons ──
        
        // CarPlay
        #if canImport(CarPlay)
        CarPlayService.shared.podcastManager = podcast
        CarPlayService.shared.playerManager = player
        CarPlayService.shared.audioManager = audio
        #endif
        
        // Background Refresh
        let bgRefresh = BackgroundRefreshService.shared
        bgRefresh.podcastManager = podcast
        bgRefresh.audioManager = audio
        bgRefresh.settingsManager = settings
        bgRefresh.registerTasks()
        bgRefresh.scheduleRefresh()
        
        // Watch Connectivity
        let watchService = WatchService.shared
        watchService.audioManager = audio
        watchService.playerManager = player
        watchService.podcastManager = podcast
        watchService.onCustomCommand = { [weak player, weak podcast, weak audio] command, payload in
            Task { @MainActor in
                switch command {
                case "remove_from_queue":
                    if let episodeId = payload["episodeId"] as? String {
                        let items = audio?.queue ?? []
                        if let item = items.first(where: { $0.id == episodeId }) {
                            audio?.removeFromQueue(item)
                        }
                    }
                case "mark_as_played":
                    if let episodeId = payload["episodeId"] as? String {
                        let items = audio?.queue ?? []
                        if let item = items.first(where: { $0.id == episodeId }) {
                            audio?.removeFromQueue(item)
                        }
                    }
                case "refresh_queue":
                    watchService.syncQueue()
                case "playLatest":
                    if let name = payload["podcastName"] as? String {
                        player?.playLatest(podcastName: name)
                    }
                case "update_progress":
                    if let episodeId = payload["episodeId"] as? String,
                       let position = payload["position"] as? Int {
                        player?.updateProgress(episodeId: episodeId, position: position)
                    }
                case "request_library":
                    watchService.syncLibrary()
                case "request_episodes":
                    if let feedUrl = payload["feedUrl"] as? String,
                       let podcast = podcast {
                        let episodes: [[String: Any]] = podcast.subscriptions
                            .first(where: { $0.url == feedUrl })?
                            .episodes.map { ep in
                                [
                                    "id": ep.guid,
                                    "title": ep.title,
                                    "duration": ep.durationSeconds ?? 0,
                                    "audioUrl": ep.audioUrl ?? "",
                                    "artUri": ep.imageUrl ?? "",
                                ] as [String: Any]
                            } ?? []
                        watchService.sendEpisodes(feedUrl: feedUrl, episodes: episodes)
                    }
                default:
                    break
                }
            }
        }
        
        // Live Activity
        LiveActivityService.shared.initialize()
        LiveActivityService.shared.onAction = { [weak audio] action in
            Task { @MainActor in
                switch action {
                case "togglePlay": audio?.togglePlayPause()
                case "skipForward": audio?.seekRelative(seconds: 30)
                case "skipBackward": audio?.seekRelative(seconds: -15)
                default: break
                }
            }
        }
        
        // ── P2: Siri intent observers ──
        let nc = NotificationCenter.default
        nc.addObserver(forName: .siriPlayQueue, object: nil, queue: .main) { _ in
            Task { await audio.resumePlayback() }
        }
        nc.addObserver(forName: .siriResumePlayback, object: nil, queue: .main) { _ in
            Task { await audio.resumePlayback() }
        }
        nc.addObserver(forName: .siriPause, object: nil, queue: .main) { _ in
            audio.pause()
        }
        nc.addObserver(forName: .siriStop, object: nil, queue: .main) { _ in
            audio.stop()
        }
        nc.addObserver(forName: .siriSkipForward, object: nil, queue: .main) { _ in
            audio.seekRelative(seconds: 30)
        }
        nc.addObserver(forName: .siriSkipBackward, object: nil, queue: .main) { _ in
            audio.seekRelative(seconds: -15)
        }
        nc.addObserver(forName: .siriSkipToNext, object: nil, queue: .main) { _ in
            audio.skipToNext()
        }
        nc.addObserver(forName: .siriPlayLatest, object: nil, queue: .main) { notification in
            if let name = notification.userInfo?["podcastName"] as? String {
                Task { @MainActor in
                    player.playLatest(podcastName: name)
                }
            }
        }
        nc.addObserver(forName: .siriSetSpeed, object: nil, queue: .main) { notification in
            if let speed = notification.userInfo?["speed"] as? Float {
                audio.setPlaybackRate(speed)
            }
        }
        nc.addObserver(forName: .siriPlayPodcast, object: nil, queue: .main) { notification in
            if let name = notification.userInfo?["podcastName"] as? String {
                Task { @MainActor in
                    player.playLatest(podcastName: name)
                }
            }
        }
        nc.addObserver(forName: .siriSetSleepTimer, object: nil, queue: .main) { notification in
            if let minutes = notification.userInfo?["minutes"] as? Int {
                sleepTimer.start(minutes: minutes)
            }
        }
        nc.addObserver(forName: .siriCancelSleepTimer, object: nil, queue: .main) { _ in
            sleepTimer.stop()
        }
        nc.addObserver(forName: .siriWhatsPlaying, object: nil, queue: .main) { _ in
            // No-op: MPNowPlayingInfoCenter already exposes the current track to Siri.
            // This observer exists for future enhancements (e.g., logging queries).
        }
        
        // ── P2: Chain Live Activity + Watch sync onto existing callbacks ──
        // PlayerManager.init() already sets these; we wrap them instead of replacing.
        let existingOnItemChanged = audio.onItemChanged
        audio.onItemChanged = { item in
            // Run PlayerManager's existing handler first
            existingOnItemChanged?(item)
            
            // Update watch playback state & queue
            WatchService.shared.updatePlaybackState()
            WatchService.shared.syncQueue(
                autoSyncEnabled: settings.watchSyncEnabled,
                watchSyncCount: settings.watchSyncPodcastLimit,
                watchPositionSyncInterval: settings.watchPositionSyncInterval
            )
            
            // Live Activity disabled — MPNowPlayingInfoCenter already provides
            // Dynamic Island pill, lock screen controls, and Control Center.
            // Uncomment to re-enable for richer chapter/progress display later.
            // if #available(iOS 16.2, *), let item {
            //     LiveActivityService.shared.startActivity(...)
            // }
            
            // Update CarPlay
            #if canImport(CarPlay)
            CarPlayService.shared.scheduleUpdate()
            #endif
        }
        
        let existingOnCompleted = audio.onEpisodeCompleted
        audio.onEpisodeCompleted = { item in
            // Run PlayerManager's existing handler first
            existingOnCompleted?(item)
            
            // Live Activity disabled (see onItemChanged comment above)
            // if audio.queue.isEmpty || audio.currentItem == nil {
            //     if #available(iOS 16.2, *) {
            //         LiveActivityService.shared.endActivity()
            //     }
            // }
            
            // Sync watch after episode completes
            WatchService.shared.syncQueue(
                autoSyncEnabled: settings.watchSyncEnabled,
                watchSyncCount: settings.watchSyncPodcastLimit,
                watchPositionSyncInterval: settings.watchPositionSyncInterval
            )
        }
        
        // Sync watch whenever queue changes (add, remove, reorder)
        audio.onQueueChanged = { [weak settings] in
            guard let settings else { return }
            WatchService.shared.syncQueue(
                autoSyncEnabled: settings.watchSyncEnabled,
                watchSyncCount: settings.watchSyncPodcastLimit,
                watchPositionSyncInterval: settings.watchPositionSyncInterval
            )
        }
        
        // ── Progress tracking timer ──
        // Matches the local-save cadence (5s). Server sync uses its own
        // throttle (user-configured, default 30s). UI progress bar and
        // lock screen / CarPlay now-playing are driven by the separate
        // 0.5s AVPlayer periodic time observer — not this timer.
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak player] _ in
            Task { @MainActor in
                player?.syncProgress()
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(viewTreeId)
                .environment(audioManager)
                .environment(settingsManager)
                .environment(playerManager)
                .environment(podcastManager)
                .environment(navigationState)
                .environment(sleepTimerManager)
                .environment(downloadManager)
                .modelContainer(modelContainer)
                // P1: Deep link handler for Live Activity + yourpods:// URLs
                .onOpenURL { url in
                    LiveActivityService.shared.handleURL(url)
                }
                .preferredColorScheme(settingsManager.appearance.colorScheme)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Detect if the binary was replaced while the app was suspended
                // (e.g. TestFlight update). If so, force a full view tree rebuild.
                let lastBuild = UserDefaults.standard.string(forKey: Self.lastBuildKey) ?? ""
                if Self.currentBuild != lastBuild {
                    UserDefaults.standard.set(Self.currentBuild, forKey: Self.lastBuildKey)
                    viewTreeId = UUID()
                }
                
                // Run time-based download cleanup (after 1 week / 1 month policies)
                let globalPolicy = settingsManager.defaultDownloadCleanupPolicy
                var podcastPolicies: [String: DownloadCleanupPolicy] = [:]
                for podcast in podcastManager.subscriptions {
                    if let policy = podcast.effectiveSettings.downloadCleanupPolicy {
                        for episode in podcast.episodes {
                            podcastPolicies[episode.guid] = policy
                        }
                    }
                }
                downloadManager.cleanupExpiredDownloads(
                    globalPolicy: globalPolicy,
                    podcastPolicies: podcastPolicies
                )
            }
            if newPhase == .background {
                // Persist position immediately so app kills don't lose progress
                playerManager.forceSyncProgress()
                audioManager.persistQueueToDisk()
            }
        }
    }
    
    // MARK: - Store Recovery
    
    /// Delete the SwiftData SQLite store and its WAL/SHM files.
    /// Used for corruption recovery and Flutter migration cleanup.
    private static func deleteStoreFiles() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let storeURL = appSupport.appendingPathComponent("default.store")
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + ext)
            )
        }
    }
}

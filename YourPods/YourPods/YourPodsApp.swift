import SwiftUI
import SwiftData

@main
struct YourPodsApp: App {
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
            if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let storeURL = appSupport.appendingPathComponent("default.store")
                for ext in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + ext))
                }
            }
        }
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Last-resort recovery — delete and retry
            let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            if let appSupport = urls.first {
                let storeURL = appSupport.appendingPathComponent("default.store")
                for ext in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + ext))
                }
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
        
        let audio = AudioManager()
        let settings = SettingsManager()
        let player = PlayerManager(audioManager: audio)
        let podcast = PodcastManager(modelContext: modelContainer.mainContext)
        let navState = NavigationState()
        
        player.podcastManager = podcast
        player.settingsManager = settings
        
        let download = DownloadManager()
        
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
        
        // ── Migrate passwords from UserDefaults to Keychain (one-time) ──
        KeychainHelper.migrateFromUserDefaultsIfNeeded()
        
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
        podcast.applyEpisodeActions(strategy: settings.syncConflictStrategy)
        
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
                watchSyncCount: settings.watchSyncPodcastLimit
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
                watchSyncCount: settings.watchSyncPodcastLimit
            )
        }
        
        // Sync watch whenever queue changes (add, remove, reorder)
        audio.onQueueChanged = { [weak settings] in
            guard let settings else { return }
            WatchService.shared.syncQueue(
                autoSyncEnabled: settings.watchSyncEnabled,
                watchSyncCount: settings.watchSyncPodcastLimit
            )
        }
        
        // ── Progress tracking timer ──
        // Calls syncProgress() every 1s; internal throttle handles cadence:
        //   - Local model writes every 5s
        //   - Server sync at user-configured interval (10–60s, default 30s)
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak player] _ in
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
            }
            if newPhase == .background {
                // Persist position immediately so app kills don't lose progress
                playerManager.forceSyncProgress()
                audioManager.persistQueueToDisk()
            }
        }
    }
}

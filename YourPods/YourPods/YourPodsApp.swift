import SwiftUI
import SwiftData
import os
// ─── YourPods Pro ──────────────────────────────────────────────────────────
// Firebase is used EXCLUSIVELY for YourPods Pro account authentication.
// It is NOT required to build or run the app — Vault Mode (local-only)
// and gPodder sync work without it.
// See: https://opensource.yourpods.app
// ───────────────────────────────────────────────────────────────────────────
import FirebaseCore

@main
struct YourPodsApp: App {
    private static let logger = Logger(subsystem: "com.yourpods", category: "AppLifecycle")
    
    let modelContainer: ModelContainer
    @State private var audioManager: AudioManager
    @State private var settingsManager: SettingsManager
    @State private var playerManager: PlayerManager
    @State private var podcastManager: PodcastManager
    @State private var navigationState: NavigationState
    @State private var sleepTimerManager: SleepTimerManager
    @State private var downloadManager: DownloadManager
    @State private var networkMonitor: NetworkMonitor
    
    @Environment(\.scenePhase) private var scenePhase
    
    /// Changing this forces a complete tear-down and rebuild of the view tree.
    @State private var viewTreeId = UUID()
    
    /// True while the deferred startup save (applyEpisodeActions) is running.
    /// Shows a brief loading indicator so stale positions aren't visible.
    @State private var isApplyingStartupActions = false
    
    /// Tracks the in-flight foreground sync task so it can be cancelled on background.
    /// Prevents 0x8BADF00D watchdog kills when the system terminates the app
    /// while a heavy SwiftData save is blocking the main thread.
    @State private var foregroundSyncTask: Task<Void, Never>?
    
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
        // ── Diagnostic: capture Objective-C exception messages ──
        NSSetUncaughtExceptionHandler { exception in
            let message = """
            ⚠️ UNCAUGHT EXCEPTION: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            User Info: \(exception.userInfo ?? [:])
            Stack: \(exception.callStackSymbols.joined(separator: "\n"))
            """
            Logger(subsystem: "com.yourpods", category: "crash").fault("\(message)")
            // Also write to a file for easy retrieval
            let crashLog = FileManager.default.temporaryDirectory.appendingPathComponent("yourpods_crash.log")
            try? message.write(to: crashLog, atomically: true, encoding: .utf8)
        }
        
        // ── Stamp the current build number ──
        let lastBuild = UserDefaults.standard.string(forKey: Self.lastBuildKey) ?? ""
        if Self.currentBuild != lastBuild {
            UserDefaults.standard.set(Self.currentBuild, forKey: Self.lastBuildKey)
        }
        
        // ── Clear stale crash sentinel from previous app versions ──
        // Previous versions used a sentinel + ModelContext.save() as a write probe.
        // That probe could itself crash with pread() — the very thing it was
        // designed to detect. The preflight check now uses the raw sqlite3 C API
        // for write validation (returns error codes instead of crashing).
        // Clear any stale sentinel so users upgrading from an older version
        // don't get stuck in a "previous crash detected" state.
        if UserDefaults.standard.bool(forKey: Self.saveSentinelKey) {
            Self.logger.info("Clearing stale save sentinel from previous app version")
            UserDefaults.standard.set(false, forKey: Self.saveSentinelKey)
        }
        
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        // ── Preflight SQLite integrity check ──
        // Validates B-tree integrity (PRAGMA quick_check), WAL checkpoint health,
        // AND raw write capability (INSERT + DELETE via sqlite3 C API) — all using
        // the raw C API which returns error codes instead of crashing with pread().
        // If any check fails, delete the store. SwiftData will create a fresh one below.
        if !StoreHealthProbe.preflightCheck(storeURL: Self.modelStoreURL()) {
            Self.logger.warning("Preflight SQLite check failed — deleting corrupt store before SwiftData init")
            Self.deleteStoreFiles()
            Self.clearSyncStateForStoreRecovery()
        }
        
        // ── Create ModelContainer with corruption recovery ──
        // Schema migration failures are caught here. If the container can't be
        // created, delete the store and try once more.
        var container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            Self.deleteStoreFiles()
            Self.clearSyncStateForStoreRecovery()
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
        
        modelContainer = container
        
        // ── Disable SwiftData autosave timer ──
        // SwiftData defaults to autosaveEnabled = true, installing an NSTimer that
        // periodically calls modelContext.save(). This races with our explicit saves
        // during sync (applyActionsForPodcast, updateEpisodeProgress, flushProgressToDisk)
        // and can crash in sqlite3ExprDeleteNN when the autosave fires while model objects
        // are mid-mutation. We manage all 20+ save points explicitly with throttling,
        // cooperative yielding, and critical flush points — the autosave timer is redundant.
        modelContainer.mainContext.autosaveEnabled = false
        
        let audio = AudioManager()
        let settings = SettingsManager()
        let player = PlayerManager(audioManager: audio)
        let podcast = PodcastManager(modelContext: modelContainer.mainContext)
        let navState = NavigationState()
        
        player.podcastManager = podcast
        player.settingsManager = settings
        podcast.playerManager = player
        
        let download = DownloadManager()
        podcast.downloadManager = download
        podcast.settingsManager = settings
        player.downloadManager = download
        
        // Wire queue items provider so episode action sync can look up metadata
        // for queue-only episodes (added without subscribing to the podcast).
        podcast.episodeActionSync.setQueueItemsProvider { [weak audio] in
            guard let audio else { return [] }
            var items = audio.queue
            if let current = audio.currentItem {
                items.insert(current, at: 0)
            }
            return items
        }
        
        // Re-attach local file URLs to restored queue items so downloaded
        // episodes play offline after a cold start. Must run AFTER restoreQueue()
        // (called inside PlayerManager.init) and AFTER DownloadManager is created.
        audio.rehydrateLocalFileUrls { guid in
            download.localUrl(for: guid)
        }
        
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
        
        // Wire "DriftOff Mode": when active, stop after current episode
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
        
        // ── Wire sync client from saved active profile ──
        // ─── YourPods Pro ──────────────────────────────────────────────────
        // Firebase Auth is optional — only initialized for Pro profiles.
        // Vault Mode and gPodder sync work without Firebase.
        // See: https://opensource.yourpods.app
        // ───────────────────────────────────────────────────────────────────
        if let _ = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") {
            FirebaseApp.configure()
        } else {
            Logger(subsystem: "com.yourpods", category: "sync").info("GoogleService-Info.plist not found — Firebase not initialized (Vault/gPodder-only mode)")
        }
        
        if let activeId = settings.activeProfileId,
           let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data),
           let active = profiles.first(where: { $0.id == activeId }),
           !active.isLocal,
           let baseUrl = active.baseUrl,
           let username = active.username {
            switch active.profileType {
            case .yourpodsPro:
                let authProvider = FirebaseAuthProvider()
                let client = YourPodsProClient(baseUrl: baseUrl, authProvider: authProvider)
                podcast.setSyncClient(client, deviceId: active.deviceId)
            case .gpodder:
                let password = KeychainHelper.shared.password(forProfileId: active.id) ?? ""
                let client = GPodderClient(baseUrl: baseUrl, username: username, password: password)
                podcast.setSyncClient(client, deviceId: active.deviceId)
            case .gpodderNet:
                let password = KeychainHelper.shared.password(forProfileId: active.id) ?? ""
                let client = GPodderClient(baseUrl: baseUrl, username: username, password: password, flavor: .gpodderNet)
                podcast.setSyncClient(client, deviceId: active.deviceId)
            }
        }
        
        // Restore persisted episode action map — actions will be applied
        // in a deferred .task modifier (see body) to avoid holding SQLite
        // write locks during init, which causes 0xDEAD10CC kills.
        podcast.loadActionMap()
        podcast.loadConflictCounts()
        
        // ── P0: Wire service singletons ──
        
        // Network monitor for autodownload gating + UI connectivity state
        let network = NetworkMonitor()
        podcast.networkMonitor = network
        audio.networkMonitor = network
        audio.subscribeToConnectivityRestoration()
        _networkMonitor = State(initialValue: network)
        
        // CarPlay
        #if canImport(CarPlay)
        CarPlayService.shared.podcastManager = podcast
        CarPlayService.shared.playerManager = player
        CarPlayService.shared.audioManager = audio
        CarPlayService.shared.networkMonitor = network
        #endif
        
        // Background Refresh — iOS only (macOS apps run continuously)
        #if os(iOS)
        let bgRefresh = BackgroundRefreshService.shared
        bgRefresh.podcastManager = podcast
        bgRefresh.audioManager = audio
        bgRefresh.settingsManager = settings
        bgRefresh.downloadManager = download
        bgRefresh.networkMonitor = network
        bgRefresh.playerManager = player
        bgRefresh.registerTasks()
        bgRefresh.scheduleRefresh()
        
        // Badge Service — updates app icon badge with unplayed episode count
        let badge = BadgeService.shared
        badge.podcastManager = podcast
        badge.settingsManager = settings
        podcast.badgeService = badge
        #endif
        
        // Watch Connectivity — iOS only (macOS doesn't pair with Apple Watch)
        #if os(iOS)
        let watchService = WatchService.shared
        watchService.audioManager = audio
        watchService.playerManager = player
        watchService.podcastManager = podcast
        watchService.settingsManager = settings
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
                case "request_recent_episodes":
                    watchService.sendRecentEpisodes()
                default:
                    break
                }
            }
        }
        #endif
        
        // Live Activity — iOS only (Dynamic Island / Lock Screen)
        #if os(iOS)
        LiveActivityService.shared.initialize()
        LiveActivityService.shared.onAction = { [weak audio] action in
            Task { @MainActor in
                switch action {
                case "togglePlay": audio?.togglePlayPause()
                case "skipForward": audio?.seekRelative(seconds: Double(settings.skipForwardSeconds))
                case "skipBackward": audio?.seekRelative(seconds: -Double(settings.skipBackwardSeconds))
                default: break
                }
            }
        }
        
        // Register notification categories for new episode alerts
        NewEpisodeNotificationService.shared.registerCategories()
        #endif
        
        // ── P2: Siri intent observers ──
        let nc = NotificationCenter.default
        nc.addObserver(forName: .siriPlayQueue, object: nil, queue: .main) { _ in
            Task { await audio.resumePlayback() }
        }
        nc.addObserver(forName: .siriResumePlayback, object: nil, queue: .main) { _ in
            Task { await audio.resumePlayback() }
        }
        nc.addObserver(forName: .siriPause, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                audio.pause()
            }
        }
        nc.addObserver(forName: .siriStop, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                audio.stop()
            }
        }
        nc.addObserver(forName: .siriSkipForward, object: nil, queue: .main) { [weak settings] _ in
            MainActor.assumeIsolated {
                audio.seekRelative(seconds: Double(settings?.skipForwardSeconds ?? 30))
            }
        }
        nc.addObserver(forName: .siriSkipBackward, object: nil, queue: .main) { [weak settings] _ in
            MainActor.assumeIsolated {
                audio.seekRelative(seconds: -Double(settings?.skipBackwardSeconds ?? 15))
            }
        }
        nc.addObserver(forName: .siriSkipToNext, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                audio.skipToNext()
            }
        }
        nc.addObserver(forName: .siriPlayLatest, object: nil, queue: .main) { notification in
            if let name = notification.userInfo?["podcastName"] as? String {
                Task { @MainActor in
                    player.playLatest(podcastName: name)
                }
            }
        }
        nc.addObserver(forName: .siriSetSpeed, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                if let speed = notification.userInfo?["speed"] as? Float {
                    audio.setPlaybackRate(speed)
                }
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
        
        // ── P2: Chain Live Activity + Watch + CarPlay sync onto existing callbacks ──
        // These services are iOS-only; on macOS the default handlers from PlayerManager suffice.
        #if os(iOS)
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
            
            // Update CarPlay
            #if canImport(CarPlay)
            CarPlayService.shared.scheduleUpdate()
            #endif
        }
        
        let existingOnCompleted = audio.onEpisodeCompleted
        audio.onEpisodeCompleted = { item in
            // Run PlayerManager's existing handler first
            existingOnCompleted?(item)
            
            // Sync watch after episode completes
            WatchService.shared.syncQueue(
                autoSyncEnabled: settings.watchSyncEnabled,
                watchSyncCount: settings.watchSyncPodcastLimit,
                watchPositionSyncInterval: settings.watchPositionSyncInterval
            )
        }
        
        // Sync watch whenever queue changes (including position updates)
        audio.onQueueChanged = { [weak settings] in
            guard let settings else { return }
            WatchService.shared.syncQueue(
                autoSyncEnabled: settings.watchSyncEnabled,
                watchSyncCount: settings.watchSyncPodcastLimit,
                watchPositionSyncInterval: settings.watchPositionSyncInterval
            )
        }
        
        // P1-4: Push queue to Pro server only on membership/order changes,
        // NOT on position-only updates. This prevents a server push every ~7s
        // during active playback (5s position timer + 2s debounce).
        audio.onQueueMembershipChanged = { [weak player] in
            player?.pushQueueToProServerDebounced()
        }
        #endif
        
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
            ZStack {
                ContentView()
                    .id(viewTreeId)
                    .environment(audioManager)
                    .environment(settingsManager)
                    .environment(playerManager)
                    .environment(podcastManager)
                    .environment(navigationState)
                    .environment(sleepTimerManager)
                    .environment(downloadManager)
                    .environment(networkMonitor)
                    .modelContainer(modelContainer)
                    // P1: Deep link handler for Live Activity + yourpods:// URLs
                    .onOpenURL { url in
                        #if os(iOS)
                        LiveActivityService.shared.handleURL(url)
                        #endif
                    }
                    .preferredColorScheme(settingsManager.appearance.colorScheme)
                
                // Loading overlay during deferred startup save
                if isApplyingStartupActions {
                    startupLoadingOverlay
                }
            }
            .task {
                await performStartupSave()
            }
        }
        .onChange(of: settingsManager.skipForwardSeconds) { _, newValue in
            audioManager.updateRemoteCommandIntervals(
                forward: newValue,
                backward: settingsManager.skipBackwardSeconds
            )
        }
        .onChange(of: settingsManager.skipBackwardSeconds) { _, newValue in
            audioManager.updateRemoteCommandIntervals(
                forward: settingsManager.skipForwardSeconds,
                backward: newValue
            )
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
                
                // Foreground sync: refresh feeds + sync subscriptions/episode actions/queue
                // from server. Debounced to avoid spamming on rapid foreground/background cycles.
                #if os(iOS)
                let bgService = BackgroundRefreshService.shared
                if bgService.shouldPerformForegroundSync() {
                    foregroundSyncTask = Task {
                        // 0xDEAD10CC fix: protect the foreground sync with a background
                        // task assertion. When the user unplugs CarPlay (phone screen off),
                        // RunningBoard sees zero active scenes and suspends immediately.
                        // Without this assertion, a mid-save modelContext.save() holds the
                        // SQLite write lock through suspension → 0xDEAD10CC kill.
                        var bgId: UIBackgroundTaskIdentifier = .invalid
                        if NSClassFromString("XCTestCase") == nil {
                            bgId = UIApplication.shared.beginBackgroundTask(withName: "foreground-sync") {
                                self.foregroundSyncTask?.cancel()
                                UIApplication.shared.endBackgroundTask(bgId)
                                bgId = .invalid
                            }
                        }
                        
                        await bgService.performForegroundSync()
                        
                        if bgId != .invalid {
                            UIApplication.shared.endBackgroundTask(bgId)
                        }
                    }
                }
                
                // Recalculate badge count on foreground — reflects episodes played
                // since last open and any new episodes from background sync.
                Task {
                    await BadgeService.shared.updateBadgeCount()
                }
                #endif
            }
            if newPhase == .background {
                // Cancel in-flight foreground sync to prevent 0x8BADF00D watchdog kills.
                // Heavy SwiftData saves (applyEpisodeActions) block termination — cancelling
                // the task lets the app exit within the 5-second watchdog window.
                foregroundSyncTask?.cancel()
                foregroundSyncTask = nil
                
                // 0xDEAD10CC fix: ALL background-entry work must run inside a single
                // background task assertion. Previously, endBackgroundTask was called
                // before the async network pushes, allowing fire-and-forget Tasks to
                // execute without protection. If any Task triggered a modelContext.save()
                // during suspension, the SQLite WAL checkpoint held a file lock →
                // iOS killed the process with 0xDEAD10CC.
                var bgSaveId: UIBackgroundTaskIdentifier = .invalid
                if NSClassFromString("XCTestCase") == nil {
                    bgSaveId = UIApplication.shared.beginBackgroundTask(withName: "bg-save") {
                        UIApplication.shared.endBackgroundTask(bgSaveId)
                        bgSaveId = .invalid
                    }
                }
                
                // Synchronous saves — must complete before suspension
                playerManager.forceSyncProgress()
                audioManager.persistQueueToDisk()
                // Flush throttled actionMap to disk before potential process kill
                podcastManager.episodeActionSync.forcePersistActionMap()
                
                // Re-schedule background refresh — Apple recommends scheduling
                // every time the app enters background for maximum reliability.
                BackgroundRefreshService.shared.scheduleRefresh()
                
                // Async network pushes — run inside the assertion, end when done.
                // These are fire-and-forget but must complete before suspension.
                Task {
                    // Tell the Pro server which episode is active
                    playerManager.syncNowPlayingToProServer()
                    // Flush queue to Pro server so web/other devices see the latest state
                    await playerManager.pushQueueToProServer()
                    // Flush pending stats events so they aren't lost if the app is killed
                    playerManager.flushStatsIfAuthenticated()
                    
                    if bgSaveId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgSaveId)
                    }
                }
            }
        }
    }
    
    // MARK: - Deferred Startup Save
    
    /// Applies episode actions from the persisted action map, protected by a
    /// background task assertion to prevent `0xDEAD10CC` kills.
    ///
    /// **Why deferred:** `applyEpisodeActions()` calls `modelContext.save()`
    /// per-podcast (to avoid __CFStringEqual crashes), which takes ~11 seconds
    /// for large libraries. When this ran in `App.init()`, the system would
    /// suspend the app while it held an active SQLite write lock, triggering
    /// a `0xDEAD10CC` watchdog kill. The sentinel was never cleared, causing
    /// store deletion and a blank library on next launch.
    ///
    /// **Fix:** `beginBackgroundTask` gives up to 30 seconds of execution time
    /// even when the device is locked. If the system's expiration handler fires,
    /// we end cleanly and let the sentinel trigger recovery on next launch.
    private func performStartupSave() async {
        // Guard: only apply if there are actions to process
        guard !podcastManager.actionMap.isEmpty else { return }
        
        isApplyingStartupActions = true
        defer { isApplyingStartupActions = false }
        
        #if os(iOS)
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        if NSClassFromString("XCTestCase") == nil {
            bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "startup-save") {
                // Expiration handler — system is about to suspend us.
                // End the task cleanly. The sentinel will trigger recovery on next launch.
                Self.logger.warning("Background task expired during startup save — ending task")
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }
        #endif
        
        // NOTE: Sentinel removed from performStartupSave.
        // Previously, a sentinel was set before the save and cleared after.
        // If the app was killed mid-save (e.g. by the watchdog), the sentinel
        // caused the ENTIRE store to be deleted on next launch — blank library.
        // A mid-save kill only means some positions aren't applied yet;
        // the next sync corrects this. Store deletion is overkill.
        // The sentinel is retained in StoreHealthProbe for init-time corruption.
        
        _ = await podcastManager.applyEpisodeActionsAsync(
            strategy: settingsManager.syncConflictStrategy
        )
        
        #if os(iOS)
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }
        #endif
        
        Self.logger.info("Deferred startup save completed successfully")
    }
    
    /// A subtle loading overlay shown while episode positions are being applied.
    @ViewBuilder
    private var startupLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Syncing positions…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .animation(.easeInOut(duration: 0.3), value: true)
    }
    
    // MARK: - Store Recovery
    
    /// Resolve the actual ModelContainer store path.
    ///
    /// SwiftData places `default.store` in the app group shared container
    /// when the app has an app group entitlement. The standard
    /// `applicationSupportDirectory` is the *non-shared* container and
    /// does NOT contain the store.
    ///
    /// Visible to tests via `@testable import`.
    static func modelStoreURL() -> URL {
        // SwiftData places default.store in the app group shared container
        // when the app has a group entitlement. We must resolve via
        // containerURL(forSecurityApplicationGroupIdentifier:) to find it.
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.asecretcompany.yourpods"
        ) {
            let storeDir = groupURL
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
            // Ensure the directory exists — first launch or fresh simulator
            // may not have Library/Application Support/ yet, causing
            // "Sandbox access to file-write-create denied" errors.
            try? FileManager.default.createDirectory(
                at: storeDir,
                withIntermediateDirectories: true
            )
            return storeDir.appendingPathComponent("default.store")
        }
        // Fallback: standard Application Support (tests without entitlement, etc.)
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("default.store")
    }
    
    /// Delete the SwiftData SQLite store and its WAL/SHM files.
    /// Used for corruption recovery.
    private static func deleteStoreFiles() {
        let storeURL = modelStoreURL()
        for ext in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: storeURL.path + ext)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
                logger.info("Deleted store file: \(fileURL.lastPathComponent)")
            }
        }
        logger.warning("Store deletion attempted at: \(storeURL.path)")
    }
    
    /// Clear sync-related UserDefaults state after store corruption recovery.
    /// Called alongside deleteStoreFiles() so that the rebuilt store gets a
    /// clean sync from the server without stale actionMap conflicts.
    ///
    /// Visible to tests via `@testable import`.
    static func clearSyncStateForStoreRecovery() {
        let defaults = UserDefaults.standard
        
        // Clear episode action map — stale positions from before corruption
        // would cause a flood of sync conflicts against server data
        defaults.removeObject(forKey: "episodeActionMap")
        // Also clear the file-based action map (migrated from UserDefaults)
        try? FileManager.default.removeItem(at: EpisodeActionSyncService.actionMapFileURL)
        
        // Clear conflict counts — they're meaningless after store deletion
        defaults.removeObject(forKey: "syncConflictCounts")
        
        // Reset sync timestamps and clear subscription URLs for all profiles.
        // We iterate UserDefaults keys because we don't know which profile(s) exist.
        // Clearing subscriptionUrls ensures loadSubscriptions() starts fresh
        // instead of filtering against stale URLs that reference deleted Podcast objects.
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix("lastSubscriptionSync_") ||
               key.hasPrefix("lastEpisodeActionSync_") ||
               key.hasPrefix("subscriptionUrls_") {
                if key.hasPrefix("subscriptionUrls_") {
                    defaults.removeObject(forKey: key)
                } else {
                    defaults.set(0, forKey: key)
                }
            }
        }
        
        logger.info("Cleared sync state for store recovery (actionMap, conflicts, timestamps, subscription URLs)")
    }
}

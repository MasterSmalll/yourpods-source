import SwiftUI
import SwiftData
import Intents
import os
// ─── YourPods Pro ──────────────────────────────────────────────────────────
// Firebase is used EXCLUSIVELY for YourPods Pro account authentication.
// It is NOT required to build or run the app — Vault Mode (local-only)
// and gPodder sync work without it.
// See: https://opensource.yourpods.app
// ───────────────────────────────────────────────────────────────────────────
import FirebaseCore
import FirebaseAppCheck

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
    @State private var subscriptionManager = SubscriptionManager()
    @State private var chapterCoordinator: ChapterCoordinator
    
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
    
    // MARK: - Recovery Decision Helpers
    
    /// What recovery action to take after a preflight health verdict.
    enum RecoveryAction: Equatable {
        /// Store is healthy or diagnosis was inconclusive — do not delete.
        case none
        /// Store is definitively corrupted — delete and recreate.
        case deleteAndRecreate
    }
    
    /// Classification of a ModelContainer creation error.
    enum ContainerErrorClass: Equatable {
        /// Migration failure or definitive corruption — delete + retry is appropriate.
        case migrationOrCorruption
        /// Transient environment issue (disk full, permissions, data protection) — do NOT delete.
        case transientEnvironment
    }
    
    /// Determine the recovery action for a given health verdict.
    ///
    /// Delete ONLY when the store is definitively corrupted AND the device
    /// is in a state where file I/O is reliable (protected data available).
    ///
    /// - Parameters:
    ///   - verdict: The tri-state health verdict from `preflightVerdict`.
    ///   - protectedDataAvailable: Whether the device is unlocked (iOS) or always-true (macOS/tests).
    /// - Returns: The appropriate recovery action.
    static func recoveryAction(for verdict: StoreHealthVerdict, protectedDataAvailable: Bool) -> RecoveryAction {
        switch verdict {
        case .healthy, .indeterminate:
            return .none
        case .corrupt:
            // Only delete when we trust the diagnosis — data protection
            // lockout can cause false-positive corruption verdicts.
            return protectedDataAvailable ? .deleteAndRecreate : .none
        }
    }
    
    /// Classify a ModelContainer creation error to decide if deletion is appropriate.
    ///
    /// Walks the `NSUnderlyingErrorKey` chain looking for known error patterns.
    ///
    /// - Parameter error: The error from `ModelContainer(for:configurations:)`.
    /// - Returns: The error class.
    static func classifyContainerCreationError(_ error: Error) -> ContainerErrorClass {
        // Walk the underlying error chain looking for transient patterns
        var current: Error? = error
        while let err = current {
            let nsErr = err as NSError
            
            // Cocoa file-system errors that indicate transient conditions
            let transientCocoaCodes = [
                NSFileWriteOutOfSpaceError,      // Disk full
                NSFileWriteNoPermissionError,     // Permission denied
                NSFileWriteVolumeReadOnlyError,   // Read-only filesystem
            ]
            if nsErr.domain == NSCocoaErrorDomain && transientCocoaCodes.contains(nsErr.code) {
                return .transientEnvironment
            }
            
            // POSIX errors: ENOSPC (28), EACCES (13), EROFS (30), EIO (5)
            let transientPosixCodes = [28, 13, 30, 5]
            if nsErr.domain == NSPOSIXErrorDomain && transientPosixCodes.contains(nsErr.code) {
                return .transientEnvironment
            }
            
            // Walk deeper
            current = nsErr.userInfo[NSUnderlyingErrorKey] as? Error
        }
        
        // Default: migration or corruption — deletion + retry is appropriate
        return .migrationOrCorruption
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
        
        let schema = Schema([Podcast.self, Episode.self, Annotation.self])
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
        // Container creation runs Core Data's own WAL recovery and (after an
        // app update) lightweight migration — multi-transaction writes on a
        // connection we cannot pragma-protect. Wrap in a suspension assertion:
        // BGAppRefreshTask cold-launches run this in the background.
        var container: ModelContainer
        do {
            container = try SuspensionGuard.shared.withProtection("containerInit") {
                try ModelContainer(for: schema, configurations: [config])
            }
        } catch {
            Self.deleteStoreFiles()
            Self.clearSyncStateForStoreRecovery()
            do {
                container = try SuspensionGuard.shared.withProtection("containerInit") {
                    try ModelContainer(for: schema, configurations: [config])
                }
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
        
        // Wire media intent donation so episodes appear in Control Center suggestions
        audio.mediaIntentDonor = MediaIntentDonationService()
        
        _audioManager = State(initialValue: audio)
        _settingsManager = State(initialValue: settings)
        _playerManager = State(initialValue: player)
        _podcastManager = State(initialValue: podcast)
        _navigationState = State(initialValue: navState)
        _downloadManager = State(initialValue: download)

        // ── Chapter artwork: the coordinator drives itself from
        // playback and pushes boundary crossings into AudioManager's Now
        // Playing / lock-screen artwork. `attach` wraps `audio.onItemChanged`
        // rather than replacing it — PlayerManager's own handler (just set
        // above, via PlayerManager.init) must keep running. Not gated behind
        // `#if os(iOS)`: ChapterArtworkView supports AppKit too, so macOS gets
        // chapter-following artwork the same as iOS.
        let chapterCoord = ChapterCoordinator()
        chapterCoord.attach(to: audio)
        _chapterCoordinator = State(initialValue: chapterCoord)
        
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
        // The plist must be present AND real. The open-source mirror ships it with
        // `YOUR_*` placeholders, and `FirebaseApp.configure()` raises on a malformed
        // GOOGLE_APP_ID — so checking only for the file's existence would crash every
        // clone at launch. Drop to Vault/gPodder-only mode instead.
        if FirebaseBootstrap.hasUsableConfiguration {
            AppCheck.setAppCheckProviderFactory(ShareAppCheckProviderFactory())
            FirebaseApp.configure()
        } else {
            Logger(subsystem: "com.yourpods", category: "sync").info("No usable GoogleService-Info.plist — Firebase not initialized (Vault/gPodder-only mode)")
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
                // Wire Pro auth for enhanced sharing (25/day tier via Bearer instead of 5/day App Check)
                ShareLinkBuilder.shared = ShareLinkBuilder(
                    tokenProvider: FirebaseAppCheckTokenProvider(), client: ShareClient(), authProvider: authProvider)
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
        podcast.loadOutbox()
        
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
        CarPlayService.shared.chapterCoordinator = chapterCoord
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
                        if audio?.currentItem?.id == episodeId {
                            player?.removeCurrentEpisodeFromQueue()
                        } else if let item = (audio?.queue ?? []).first(where: { $0.id == episodeId }) {
                            player?.removeFromQueue(item)
                        } else {
                            Logger(subsystem: "com.yourpods", category: "watch")
                                .debug("Watch remove_from_queue: \(episodeId) not in queue")
                        }
                    }
                case "mark_as_played":
                    if let episodeId = payload["episodeId"] as? String {
                        if audio?.currentItem?.id == episodeId {
                            player?.markCurrentEpisodeAsPlayed()
                        } else {
                            let handled = podcast?.markEpisodeAsPlayedByGuid(episodeId) ?? false
                            if !handled {
                                Logger(subsystem: "com.yourpods", category: "watch")
                                    .debug("Watch mark_as_played: \(episodeId) not found")
                            }
                            if let item = (audio?.queue ?? []).first(where: { $0.id == episodeId }) {
                                player?.removeFromQueue(item)
                            }
                        }
                    }
                case "refresh_queue":
                    watchService.syncQueueWithSettings()
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
                                WatchWireFormat.encodeEpisodeListItem(.init(
                                    guid: ep.guid,
                                    title: ep.title,
                                    duration: ep.durationSeconds ?? 0,
                                    audioUrl: ep.audioUrl,
                                    imageUrl: ep.imageUrl))
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

        // Home Screen widget controls. These are AudioPlaybackIntents, so the
        // system runs their perform() in *this* (the app's) process — they reach
        // this handler directly. Awaiting the audio action here means playback is
        // actually playing/paused before the intent completes, which stops iOS
        // from foregrounding the app to "finish" the action (the "tapping the
        // widget opens the app" bug). See WidgetPlaybackBridge.
        let widgetDiagLog = Logger(subsystem: "com.yourpods", category: "widget")
        WidgetPlaybackBridge.shared.handler = { [weak audio] command in
            // DIAGNOSTIC (temporary): if this line logs, perform() reached the APP
            // process and the live engine is in hand. If it never logs while the
            // widget still opens the app, the intent ran in the extension instead.
            widgetDiagLog.notice("⟦app-handler⟧ \(String(describing: command), privacy: .public) isPlaying=\(audio?.isPlaying ?? false) hasCurrentItem=\(audio?.currentItem != nil)")
            guard let audio else { return }
            switch command {
            case .togglePlay:
                if audio.isPlaying { audio.pause() } else { await audio.resumePlayback() }
            case .skipForward:
                audio.seekRelative(seconds: Double(settings.skipForwardSeconds))
            case .skipBackward:
                audio.seekRelative(seconds: -Double(settings.skipBackwardSeconds))
            }
        }
        widgetDiagLog.notice("⟦app-init⟧ widget bridge handler installed \(Bundle.main.bundleIdentifier ?? "?", privacy: .public) build=\(Self.currentBuild, privacy: .public)")  // DIAGNOSTIC (build= proves the running APP binary is the expected build)

        // DIAGNOSTIC (temporary): catch the app being brought to the foreground so we
        // can correlate it with a widget tap. willEnterForeground firing right after a
        // ⟦bridge⟧ log = iOS foregrounded the app to service the intent (the bug).
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            widgetDiagLog.notice("⟦lifecycle⟧ willEnterForeground")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            widgetDiagLog.notice("⟦lifecycle⟧ didBecomeActive")
        }

        // Register notification categories for new episode alerts
        NewEpisodeNotificationService.shared.registerCategories()
        #endif

        // ── Siri/Shortcuts intent bridge (replaces the older notification observers) ──
        let siriHandler = SiriIntentHandler(
            audio: audio, player: player, settings: settings, sleepTimer: sleepTimer,
            podcastManager: podcast, downloadManager: download, navigationState: navState,
            chapterCoordinator: chapterCoord)
        SiriIntentBridge.shared.handler = { command in
            await siriHandler.handle(command)
        }

        // ── Chain Live Activity + Watch + CarPlay sync onto existing callbacks ──
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

        // ── Diagnostic write instrumentation ──
        // No-op unless the DEBUG_WRITE_INSTRUMENTATION flag is set. Emits a
        // per-interval write/assertion/overlap report so we can see what drives
        // the sustained background disk-write volume before changing anything.
        #if os(iOS)
        WriteInstrumentation.shared.observeContextSaves()
        WriteInstrumentation.shared.startPeriodicEmit(intervalSeconds: 60, reason: "tick") {
            Self.instrumentationFileSizes()
        }
        #endif
    }

    #if os(iOS)
    /// Current on-disk sizes of the SQLite store + its WAL/SHM sidecars and the
    /// app-group preferences plist. Read-only — the instrumentation never writes.
    nonisolated static func instrumentationFileSizes() -> [String: Int64] {
        let fm = FileManager.default
        func size(_ path: String) -> Int64 {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let n = attrs[.size] as? NSNumber else { return 0 }
            return n.int64Value
        }
        var sizes: [String: Int64] = [:]
        let store = modelStoreURL().path
        sizes["store"] = size(store)
        sizes["store-wal"] = size(store + "-wal")
        sizes["store-shm"] = size(store + "-shm")
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.asecretcompany.yourpods") {
            let prefs = group.appendingPathComponent("Library/Preferences/group.com.asecretcompany.yourpods.plist")
            sizes["appgroup-prefs"] = size(prefs.path)
        }
        // Standard (sandbox) UserDefaults plist — queue persistence + most keys
        // live here, rewritten whole by cfprefsd on each flush.
        if let bundleId = Bundle.main.bundleIdentifier {
            let appSupport = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            if let prefs = appSupport?.appendingPathComponent("Preferences/\(bundleId).plist") {
                sizes["standard-prefs"] = size(prefs.path)
            }
        }
        return sizes
    }
    #endif
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .id(viewTreeId)
                    // P1: Deep link handler for Live Activity + yourpods:// URLs
                    .onOpenURL { url in
                        #if os(iOS)
                        LiveActivityService.shared.handleURL(url)   // yourpods://action/...
                        #endif
                        guard let link = DeepLinkParser.parse(url) else { return }
                        Task { @MainActor in
                            let router = DeepLinkRouter(
                                resolver: RSSFeedResolver(),
                                isEpisodeKnown: { guid in
                                    podcastManager.subscriptions.contains { $0.episodes.contains { $0.guid == guid } }
                                },
                                isPodcastKnown: { feed in
                                    podcastManager.subscriptions.contains { $0.url == feed }
                                })
                            navigationState.apply(await router.resolve(link))
                        }
                    }
                    // Handle Control Center media suggestion taps (INPlayMediaIntent)
                    // iOS-only: INPlayMediaIntent is unavailable on macOS, and
                    // MediaIntentDonationService never donates there, so there
                    // is no suggestion to continue from.
                    #if os(iOS)
                    .onContinueUserActivity("INPlayMediaIntent") { activity in
                        guard let intent = activity.interaction?.intent as? INPlayMediaIntent,
                              let mediaItem = intent.mediaItems?.first,
                              let episodeGuid = mediaItem.identifier else {
                            // Fallback: just resume playback
                            audioManager.play()
                            return
                        }
                        // Look up the episode in the library by GUID
                        let episode = podcastManager.subscriptions
                            .flatMap { $0.episodes }
                            .first { $0.guid == episodeGuid }
                        if let episode {
                            playerManager.playEpisode(episode)
                        } else {
                            // Episode not in library (unsubscribed?) — resume whatever was playing
                            audioManager.play()
                        }
                    }
                    #endif

                // Loading overlay during deferred startup save
                if isApplyingStartupActions {
                    startupLoadingOverlay
                }
            }
            .environment(audioManager)
            .environment(settingsManager)
            .environment(playerManager)
            .environment(podcastManager)
            .environment(navigationState)
            .environment(sleepTimerManager)
            .environment(downloadManager)
            .environment(networkMonitor)
            .environment(subscriptionManager)
            .environment(chapterCoordinator)
            // Seed the glass appearance once for the whole tree. The glass
            // modifiers read this key (never SettingsManager directly) so they
            // can never trap; re-applies automatically when the user changes
            // Glass Style because settingsManager is @Observable.
            .environment(\.glassAppearance, settingsManager.glassAppearance)
            .modelContainer(modelContainer)
            .preferredColorScheme(settingsManager.appearance.colorScheme)
            .task {
                healAnnotationSyncCasingIfNeeded()
                await performStartupSave()
                await refreshProEntitlementOnLaunch()
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
        .onChange(of: scenePhase, initial: false) { _, newPhase in
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
                
                // Duration-based auto-hide: run on every foreground so the list
                // freshens even without a full sync cycle.
                Task { @MainActor in
                    await podcastManager.autoHideUnplayedEpisodes(
                        settingsManager: settingsManager,
                        downloadManager: downloadManager
                    )
                }
                
                // Foreground sync: refresh feeds + sync subscriptions/episode actions/queue
                // from server. Debounced to avoid spamming on rapid foreground/background cycles.
                #if os(iOS)
                let bgService = BackgroundRefreshService.shared
                let isiOSAppOnMac = ProcessInfo.processInfo.isiOSAppOnMac
                let willForegroundSync = bgService.shouldPerformForegroundSync()
                Self.logger.info("scenePhase .active: isiOSAppOnMac=\(isiOSAppOnMac, privacy: .public) willForegroundSync=\(willForegroundSync, privacy: .public)")
                if willForegroundSync {
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
                // On a real iOS device, .background is the last beat before
                // suspension: a SQLite write that straddles suspension is killed
                // with 0xDEAD10CC, and a heavy SwiftData save (applyEpisodeActions)
                // that blocks the 5s termination watchdog is killed with 0x8BADF00D.
                // So in-flight sync MUST be cancelled here.
                //
                // The iOS-app-on-Mac receives .background whenever its window loses
                // key focus (e.g. the user switching to the browser to confirm a
                // sync landed). macOS never suspension-kills for a held lock, and the
                // playback reconcile is a LATE sync step — cancelling it there means
                // the Mac never adopts server now-playing/queue ("Mac stays stale").
                // Skip the cancel on Mac so the in-flight sync runs to completion.
                let isiOSAppOnMac = ProcessInfo.processInfo.isiOSAppOnMac
                let cancelInFlightSync = SyncLifecyclePolicy.cancelsInFlightSyncOnBackground(
                    isiOSAppOnMac: isiOSAppOnMac
                )
                Self.logger.info("scenePhase .background: isiOSAppOnMac=\(isiOSAppOnMac, privacy: .public) cancelInFlightSync=\(cancelInFlightSync, privacy: .public)")
                if cancelInFlightSync {
                    foregroundSyncTask?.cancel()
                    foregroundSyncTask = nil

                    // Also stop the SHARED sync pipeline and the login/playback
                    // sync: view-initiated syncs (pull-to-refresh, Home buttons)
                    // and setSyncClient's initial sync run in tasks no other
                    // lifecycle hook can reach — without these cancels they keep
                    // opening SQLite write transactions in the background.
                    podcastManager.cancelActiveSync()
                    playerManager.cancelInFlightPlaybackSync()
                }

                // 0xDEAD10CC fix: ALL background-entry work must run inside a single
                // background task assertion. Previously, endBackgroundTask was called
                // before the async network pushes, allowing fire-and-forget Tasks to
                // execute without protection. If any Task triggered a modelContext.save()
                // during suspension, the SQLite WAL checkpoint held a file lock →
                // iOS killed the process with 0xDEAD10CC.
                #if os(iOS)
                var bgSaveId: UIBackgroundTaskIdentifier = .invalid
                if NSClassFromString("XCTestCase") == nil {
                    bgSaveId = UIApplication.shared.beginBackgroundTask(withName: "bg-save") {
                        UIApplication.shared.endBackgroundTask(bgSaveId)
                        bgSaveId = .invalid
                    }
                }
                #endif
                
                // Synchronous saves — must complete before suspension
                playerManager.forceSyncProgress()
                audioManager.persistQueueToDisk()
                // Flush throttled actionMap to disk before potential process kill
                podcastManager.episodeActionSync.forcePersistActionMap()

                // Diagnostic: emit the write/assertion/overlap delta at the
                // last reliable beat before suspension. No-op unless enabled.
                // iOS-only: instrumentationFileSizes() is itself declared under
                // #if os(iOS), so an unguarded call here breaks the macOS build.
                #if os(iOS)
                WriteInstrumentation.shared.emitReport(
                    reason: "background",
                    fileSizes: Self.instrumentationFileSizes()
                )
                #endif
                
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
                    // Flush pending outbox entries so episode actions reach the server
                    await podcastManager.flushPendingEpisodeActions()
                    // Flush pending stats events so they aren't lost if the app is killed
                    playerManager.flushStatsIfAuthenticated()
                    
                    #if os(iOS)
                    if bgSaveId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgSaveId)
                    }
                    #endif
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
    /// One-time heal for the annotation snake_case→camelCase push regression.
    ///
    /// During the broken window, pushes returned `200 {synced:0}` (the server
    /// dropped every snake_case item), so iOS marked notes clean that never
    /// reached the server, and deletes never propagated. Re-dirty all local
    /// annotations so the next sync re-pushes them, and reset the pull cursor so
    /// the full-state push response re-imports any server notes that were locally
    /// hard-deleted. Runs in the deferred `.task` — never `init` — to avoid a
    /// SwiftData write while the store may be straddling suspension (0xDEAD10CC).
    @MainActor
    private func healAnnotationSyncCasingIfNeeded() {
        guard !settingsManager.didHealAnnotationSyncCasing else { return }
        let redirtied = podcastManager.annotationService?.markAllDirtyForResync() ?? 0
        settingsManager.lastAnnotationSyncedAt = nil
        settingsManager.didHealAnnotationSyncCasing = true
        Self.logger.info("Annotation sync-casing heal: re-dirtied \(redirtied) annotations, reset pull cursor")
    }

    /// Refresh the Pro entitlement on launch for a returning YourPods Pro user.
    ///
    /// Sign-in sets `isPro` directly, but `SubscriptionManager` is recreated each
    /// launch, so without this a returning Pro user would see the upgrade nudge again.
    /// The server is the source of truth; if the call fails (offline/auth not ready)
    /// we keep the last-known state and never crash on launch.
    private func refreshProEntitlementOnLaunch() async {
        guard let proClient = podcastManager.currentSyncClient as? YourPodsProClient else { return }
        do {
            let session = try await proClient.validateSession()
            subscriptionManager.applyServerSession(session)
            // Re-identify to RevenueCat on launch so a returning user's entitlement and
            // offerings load against their Firebase UID (SubscriptionManager is recreated
            // each launch). Never anonymous.
            if let uid = session.user.firebaseUid {
                subscriptionManager.identify(
                    firebaseUID: uid,
                    earlyAdopterPricingEligible: session.earlyAdopterPricingEligible ?? false)
            }
        } catch {
            Self.logger.error("Launch Pro entitlement refresh failed: \(error.localizedDescription)")
        }
    }

    private func performStartupSave() async {
        // Guard: only apply if there are actions to process
        guard !podcastManager.actionMap.isEmpty else { return }
        
        isApplyingStartupActions = true
        defer { isApplyingStartupActions = false }
        
        // Run the apply in a child task so the expiration handler can stop it.
        // Ending the assertion WITHOUT cancelling the apply leaves the save
        // loop writing unprotected — iOS suspends mid-commit → 0xDEAD10CC.
        // (Created before the assertion, but on the MainActor it cannot start
        // until the next suspension point, after beginBackgroundTask returns.)
        let applyTask = Task { [podcastManager, settingsManager] in
            await podcastManager.applyEpisodeActionsAsync(
                strategy: settingsManager.syncConflictStrategy
            )
        }

        #if os(iOS)
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        if NSClassFromString("XCTestCase") == nil {
            bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "startup-save") {
                // Expiration handler — system is about to suspend us.
                // Cancel the apply loop (its per-batch cancellation gates stop
                // further writes), then end the task cleanly.
                Self.logger.warning("Background task expired during startup save — cancelling apply")
                applyTask.cancel()
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

        _ = await applyTask.value
        
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
        .yourPodsGlass(role: .overlay, cornerRadius: 16)
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
    nonisolated static func modelStoreURL() -> URL {
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
        // Also clear the file-based action maps + completion outboxes (global and
        // every profile-scoped variant) — stale positions from any profile would
        // otherwise flood sync with conflicts after store recovery.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let appSupport,
           let files = try? FileManager.default.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
            for url in files {
                let name = url.lastPathComponent
                if name.hasPrefix("episodeActionMap") || name.hasPrefix("pendingCompletionOutbox") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

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

import Foundation
import WatchConnectivity
import Combine
import WatchKit
import os

// WatchChapter and WatchEpisode live in Services/WatchQueueMerger.swift —
// that file is compiled into both this (watch) target and the main iOS
// target (YourPodsTests needs them to test WatchQueueMerger), so the types
// were moved there rather than duplicated. See WatchQueueMerger.swift.

struct WatchPodcast: Identifiable, Codable {
    let id: String // feedUrl
    let title: String
    let feedUrl: String
    let artUri: String?
    let author: String
}

// MARK: - Download Manager for on-device downloads
class WatchDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = WatchDownloadManager()
    static let backgroundSessionId = "com.asecretcompany.yourpods.watch.download"

    /// System-provided completion handler for background session events.
    static var backgroundSessionCompletionHandler: (() -> Void)?

    /// Who asked for a download. Queue auto-downloads follow queue membership
    /// (the orphan GC may delete their files once the episode leaves the queue);
    /// user-initiated downloads are protected by a persistent manifest and only
    /// removed on explicit delete.
    enum DownloadOrigin: String {
        case queue
        case user
    }

    @Published var activeDownloads: [String: Double] = [:] // episodeId -> progress (0.0-1.0)
    @Published var completedDownloads: Set<String> = []

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var episodeInfo: [String: (url: String, title: String)] = [:]
    private var downloadQueue: [(episodeId: String, url: String, title: String, origin: DownloadOrigin)] = []
    private var stallTimers: [String: Timer] = [:]
    private var lastBytesReceived: [String: Date] = [:]
    
    private let logger = Logger(subsystem: "com.yourpods", category: "WatchDownload")
    
    /// Observers for background/foreground lifecycle notifications.
    private var backgroundObserver: Any?
    private var foregroundObserver: Any?
    
    /// Whether to restrict downloads to Wi-Fi only (blocks watch cellular radio).
    private var currentWifiOnly: Bool = true
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionId)
        config.isDiscretionary = false          // download ASAP, not at system discretion
        config.sessionSendsLaunchEvents = true  // wake app on download completion
        config.allowsCellularAccess = true      // per-task override in startDownload()
        config.timeoutIntervalForResource = 3600   // don't let a dead download hold the radio path all day
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        // Enable once — the computed property below is a pure read.
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        setupLifecycleObservers()
    }
    
    /// CAROUSEL FIX: Observe background/foreground transitions to manage stall timers.
    ///
    /// Problem: When the app is suspended, time passes but no download bytes arrive.
    /// On resume, `lastBytesReceived` timestamps are stale, so every active download
    /// appears "stalled" and gets falsely cancelled.
    ///
    /// Fix: Invalidate timers on background entry, reset timestamps on foreground resume.
    private func setupLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: WKApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.debug("Background entry — invalidating stall timers")
            self?.invalidateAllStallTimers()
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: WKApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Reset timestamps so active downloads don't appear stalled
            let now = Date()
            for key in self.lastBytesReceived.keys {
                self.lastBytesReceived[key] = now
            }
            // Restart stall timers for any active downloads
            for episodeId in self.downloadTasks.keys {
                self.startStallTimer(for: episodeId)
            }
            if !self.downloadTasks.isEmpty {
                self.logger.debug("Foreground resume — reset stall timers for \(self.downloadTasks.count) downloads")
            }
        }
    }
    
    var onDownloadComplete: ((String, String) -> Void)? // (episodeId, localPath)
    
    /// Force the background URLSession to connect so the system can deliver
    /// pending download completion events. Must be called during background
    /// launch for `.backgroundTask(.urlSession(...))` to work.
    ///
    /// Without this, the lazy `session` property is never initialized during
    /// background wakes, so `urlSessionDidFinishEvents` is never called and
    /// the CAROUSEL watchdog kills the app after 45 seconds.
    /// See: Crash 55435E1D — watchOS background URLSession watchdog transgression.
    func reconnectBackgroundSession() {
        // CAROUSEL FIX: Invalidate all stall timers from a previous foreground
        // session. Stale repeating timers accumulate across suspend/wake cycles,
        // adding main-thread work every 60s until the watchdog kills the app.
        invalidateAllStallTimers()
        _ = session  // Force lazy initialization — connects to the system's background session
        logger.debug("Background session reconnected for pending event delivery")
    }
    
    /// Invalidate all active stall detection timers.
    /// Called on background reconnect to prevent stale timers from accumulating.
    func invalidateAllStallTimers() {
        for (_, timer) in stallTimers {
            timer.invalidate()
        }
        stallTimers.removeAll()
    }
    
    /// Check if battery is too low for downloads (< 10%)
    private var isBatteryTooLow: Bool {
        let device = WKInterfaceDevice.current()
        return device.batteryLevel >= 0 && device.batteryLevel < 0.10
    }
    
    /// Max concurrent downloads to avoid radio contention
    private let maxConcurrentDownloads = 1
    
    /// Update the Wi-Fi-only network policy. New downloads will respect this;
    /// in-flight downloads are not interrupted.
    func updateNetworkPolicy(wifiOnly: Bool) {
        currentWifiOnly = wifiOnly
    }
    
    func startDownload(episodeId: String, url: String, title: String, origin: DownloadOrigin) {
        guard downloadTasks[episodeId] == nil else {
            logger.debug("Download already in progress for \(episodeId)")
            return
        }

        guard !downloadQueue.contains(where: { $0.episodeId == episodeId }) else {
            logger.debug("Download already queued for \(episodeId)")
            return
        }

        // Skip if battery too low
        if isBatteryTooLow {
            logger.info("Skipping download for \(title) — battery too low")
            return
        }

        // Queue if max concurrent reached
        if downloadTasks.count >= maxConcurrentDownloads {
            logger.debug("Queueing download for \(title) (max concurrent reached)")
            downloadQueue.append((episodeId: episodeId, url: url, title: title, origin: origin))
            return
        }

        guard let downloadUrl = URL(string: url) else {
            logger.error("Invalid URL for download: \(url)")
            return
        }

        logger.info("Starting on-watch download for: \(title) (wifiOnly: \(self.currentWifiOnly), origin: \(origin.rawValue))")
        episodeInfo[episodeId] = (url, title)
        activeDownloads[episodeId] = 0.0
        lastBytesReceived[episodeId] = Date()

        // Persist a registry entry so a background-relaunch completion can
        // still resolve the deterministic filename for this episode.
        var registry = (UserDefaults.standard.dictionary(forKey: "watch_download_registry") as? [String: String]) ?? [:]
        registry[episodeId] = WatchDownloadHygiene.filename(forEpisodeId: episodeId)
        UserDefaults.standard.set(registry, forKey: "watch_download_registry")

        // Persist the origin alongside the registry entry so a completion that
        // arrives via a background relaunch (in-memory state gone) can still
        // tell whether this was a user-initiated download that needs manifest
        // protection from the orphan GC.
        var origins = (UserDefaults.standard.dictionary(forKey: "watch_download_origins") as? [String: String]) ?? [:]
        origins[episodeId] = origin.rawValue
        UserDefaults.standard.set(origins, forKey: "watch_download_origins")
        
        var request = URLRequest(url: downloadUrl)
        request.allowsCellularAccess = !currentWifiOnly
        
        let task = session.downloadTask(with: request)
        task.taskDescription = episodeId
        downloadTasks[episodeId] = task
        task.resume()
        
        // Start stall detection timer (5 minutes)
        startStallTimer(for: episodeId)
    }
    
    private func startStallTimer(for episodeId: String) {
        stallTimers[episodeId]?.invalidate()
        stallTimers[episodeId] = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let lastReceived = self.lastBytesReceived[episodeId],
               Date().timeIntervalSince(lastReceived) > 300 { // 5 minutes no progress
                self.logger.warning("Download stalled for \(episodeId) — cancelling")
                self.cancelDownload(episodeId: episodeId)
            }
        }
    }
    
    func cancelDownload(episodeId: String) {
        downloadTasks[episodeId]?.cancel()
        downloadTasks.removeValue(forKey: episodeId)
        activeDownloads.removeValue(forKey: episodeId)
        episodeInfo.removeValue(forKey: episodeId)
        stallTimers[episodeId]?.invalidate()
        stallTimers.removeValue(forKey: episodeId)
        lastBytesReceived.removeValue(forKey: episodeId)
        removeDownloadRegistryEntry(for: episodeId)

        // Start next queued download if any
        processQueue()
    }

    /// Remove this episode's persisted registry + origin entries. Called on
    /// completion, failure, and cancellation so the registry only ever reflects
    /// in-flight downloads (never a stale reference the orphan GC would then
    /// treat as "still referenced").
    private func removeDownloadRegistryEntry(for episodeId: String) {
        var registry = (UserDefaults.standard.dictionary(forKey: "watch_download_registry") as? [String: String]) ?? [:]
        registry.removeValue(forKey: episodeId)
        UserDefaults.standard.set(registry, forKey: "watch_download_registry")

        var origins = (UserDefaults.standard.dictionary(forKey: "watch_download_origins") as? [String: String]) ?? [:]
        origins.removeValue(forKey: episodeId)
        UserDefaults.standard.set(origins, forKey: "watch_download_origins")
    }

    /// Persisted origin for an in-flight download (survives background relaunch).
    private func downloadOrigin(for episodeId: String) -> DownloadOrigin? {
        let origins = (UserDefaults.standard.dictionary(forKey: "watch_download_origins") as? [String: String]) ?? [:]
        return origins[episodeId].flatMap(DownloadOrigin.init(rawValue:))
    }

    // MARK: - Completed-download manifest (user-origin GC protection)
    //
    // libraryEpisodes is never persisted, and recent/queue lists can be empty
    // in a freshly relaunched process. A user-initiated download referenced
    // only by such a list would look "orphaned" to the GC after any relaunch.
    // The manifest is the persistent record that a user explicitly downloaded
    // a file — those files are only ever removed by an explicit delete.
    // Queue auto-downloads are intentionally NOT in the manifest: their files
    // follow queue membership (that is the GC's cleanup purpose), and the
    // queue list itself is persisted (saved_episodes).
    //
    // All manifest reads/writes are main-thread confined: completion callbacks
    // arrive on the session's main delegate queue, deleteLocalFile runs on
    // main, and the GC reads inside its main.sync snapshot / removes via a
    // main.async hop — so there is no cross-queue read-modify-write.

    private static let completedManifestKey = "watch_completed_downloads"

    /// Record a completed user-origin download. No-op for queue-origin.
    private func recordCompletedDownload(episodeId: String, filename: String, origin: DownloadOrigin) {
        guard origin == .user else { return }
        var manifest = (UserDefaults.standard.dictionary(forKey: Self.completedManifestKey) as? [String: String]) ?? [:]
        manifest[episodeId] = filename
        UserDefaults.standard.set(manifest, forKey: Self.completedManifestKey)
    }

    /// Explicit user delete — the episode's file no longer needs GC protection.
    func removeCompletedDownloadRecord(for episodeId: String) {
        var manifest = (UserDefaults.standard.dictionary(forKey: Self.completedManifestKey) as? [String: String]) ?? [:]
        manifest.removeValue(forKey: episodeId)
        UserDefaults.standard.set(manifest, forKey: Self.completedManifestKey)
    }

    /// Filenames of completed user-origin downloads — the orphan GC must
    /// never delete these. Main thread only.
    func completedUserDownloadFilenames() -> Set<String> {
        let manifest = (UserDefaults.standard.dictionary(forKey: Self.completedManifestKey) as? [String: String]) ?? [:]
        return Set(manifest.values)
    }

    /// Drop manifest entries whose file the GC just deleted, so the manifest
    /// can't accumulate references to files that no longer exist. Main thread
    /// only. (In normal operation the GC never deletes a manifest-protected
    /// file — this is defensive consistency, not a hot path.)
    func removeManifestEntries(pointingTo deletedFilenames: Set<String>) {
        var manifest = (UserDefaults.standard.dictionary(forKey: Self.completedManifestKey) as? [String: String]) ?? [:]
        let stale = manifest.filter { deletedFilenames.contains($0.value) }
        guard !stale.isEmpty else { return }
        for (episodeId, filename) in stale {
            manifest.removeValue(forKey: episodeId)
            logger.info("Removed manifest entry for deleted file: \(episodeId) → \(filename)")
        }
        UserDefaults.standard.set(manifest, forKey: Self.completedManifestKey)
    }

    private func processQueue() {
        guard downloadTasks.count < maxConcurrentDownloads,
              !downloadQueue.isEmpty else { return }
        let next = downloadQueue.removeFirst()
        startDownload(episodeId: next.episodeId, url: next.url, title: next.title, origin: next.origin)
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let episodeId = downloadTask.taskDescription else { return }
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Deterministic filename — hashValue is process-seeded, so deriving
        // the name from it meant a relaunch could re-download the same
        // episode under a second filename.
        let filename = WatchDownloadHygiene.filename(forEpisodeId: episodeId)

        let destinationURL = documentsURL.appendingPathComponent(filename)
        
        // CRITICAL: For background URLSessions, the temp file at `location` is
        // deleted when this callback returns. The file MUST be moved synchronously.
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            logger.info("Download complete for \(episodeId): \(destinationURL.path)")
            
            DispatchQueue.main.async {
                self.downloadTasks.removeValue(forKey: episodeId)
                self.activeDownloads.removeValue(forKey: episodeId)
                self.completedDownloads.insert(episodeId)
                self.stallTimers[episodeId]?.invalidate()
                self.stallTimers.removeValue(forKey: episodeId)
                self.lastBytesReceived.removeValue(forKey: episodeId)
                self.episodeInfo.removeValue(forKey: episodeId)
                // Read the persisted origin BEFORE registry cleanup removes it.
                if let origin = self.downloadOrigin(for: episodeId) {
                    self.recordCompletedDownload(episodeId: episodeId, filename: filename, origin: origin)
                } else {
                    self.logger.warning("No persisted origin for completed download \(episodeId) — treating as user download so it can't be GC'd")
                    self.recordCompletedDownload(episodeId: episodeId, filename: filename, origin: .user)
                }
                self.removeDownloadRegistryEntry(for: episodeId)
                self.onDownloadComplete?(episodeId, filename)
                self.processQueue()
            }
        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.downloadTasks.removeValue(forKey: episodeId)
                self.activeDownloads.removeValue(forKey: episodeId)
                self.episodeInfo.removeValue(forKey: episodeId)
                self.removeDownloadRegistryEntry(for: episodeId)
                self.processQueue()
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let episodeId = downloadTask.taskDescription else { return }
        
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
        
        DispatchQueue.main.async {
            self.activeDownloads[episodeId] = progress
            self.lastBytesReceived[episodeId] = Date()
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let episodeId = task.taskDescription, error != nil else { return }
        
        logger.error("Download failed for \(episodeId): \(error?.localizedDescription ?? "unknown")")
        
        DispatchQueue.main.async {
            self.downloadTasks.removeValue(forKey: episodeId)
            self.activeDownloads.removeValue(forKey: episodeId)
            self.stallTimers[episodeId]?.invalidate()
            self.stallTimers.removeValue(forKey: episodeId)
            self.lastBytesReceived.removeValue(forKey: episodeId)
            self.episodeInfo.removeValue(forKey: episodeId)
            self.removeDownloadRegistryEntry(for: episodeId)
            self.processQueue()
        }
    }

    /// Called by the system when all background session events have been delivered.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            Self.backgroundSessionCompletionHandler?()
            Self.backgroundSessionCompletionHandler = nil
        }
    }
}

class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    // MARK: - Singleton
    /// Singleton — survives SwiftUI App struct recreation during background wakes.
    /// Without this, watchOS creates a new WatchSessionManager on background wake
    /// but WCSession.default.delegate still points to the old instance → the new
    /// UI never receives data and appears frozen.
    static let shared = WatchSessionManager()
    @Published var episodes: [WatchEpisode] = []
    @Published var playbackSpeed: Double = 1.0
    @Published var positionSyncInterval: Double = 30.0
    /// User-configured skip intervals, synced from the iPhone's SettingsManager
    /// (skip-interval parity). Defaults mirror the iPhone's defaults.
    @Published var skipForwardSeconds: Int = UserDefaults.standard.object(forKey: "skipForwardSeconds") as? Int ?? 30
    @Published var skipBackwardSeconds: Int = UserDefaults.standard.object(forKey: "skipBackwardSeconds") as? Int ?? 15
    /// Tracks WCSession reachability so views can distinguish "still loading"
    /// from "the phone is unreachable" instead of spinning forever.
    @Published var isPhoneReachable: Bool = false
    /// Feed URLs whose most recent episode-list request failed (e.g. transfer
    /// timeout). Lets the episodes view resolve to an error state instead of
    /// spinning forever when the request errors after being sent.
    @Published var episodeRequestFailed: Set<String> = []

    // Remote Control State
    @Published var remoteTitle: String = "Not Playing"
    @Published var remoteArtist: String = ""
    @Published var remoteIsPlaying: Bool = false
    @Published var remoteEpisodeId: String? = nil
    
    // Library (subscriptions)
    @Published var library: [WatchPodcast] = []
    @Published var libraryEpisodes: [String: [WatchEpisode]] = [:] // feedUrl -> episodes
    
    // Recently Updated (cross-podcast, newest unplayed episodes)
    @Published var recentEpisodes: [WatchEpisode] = []
    /// Maximum number of recently updated episodes to display on watch.
    static let recentEpisodesLimit = 10
    
    // On-device download manager
    let downloadManager = WatchDownloadManager.shared
    
    private let logger = Logger(subsystem: "com.yourpods", category: "WatchSession")
    
    /// Serial queue for UserDefaults persistence — keeps saves off the main thread.
    /// watchOS has an extremely aggressive 2-second main thread watchdog;
    /// synchronous JSON encode + UserDefaults write can take 200-500ms
    /// with large queues, accumulating into watchdog kills.
    private let persistenceQueue = DispatchQueue(label: "com.yourpods.watch.persistence", qos: .utility)
    
    /// Debounce work items for each persistence key — rapid queue updates
    /// from iPhone are coalesced into a single write.
    private var saveEpisodesWorkItem: DispatchWorkItem?
    private var saveLibraryWorkItem: DispatchWorkItem?
    private var saveRecentWorkItem: DispatchWorkItem?
    
    /// The currently-playing episode (looked up from episodes list)
    var currentEpisode: WatchEpisode? {
        guard let id = remoteEpisodeId else { return nil }
        return episodes.first(where: { $0.id == id })
    }
    
    /// Whether WCSession has already been activated in this process lifetime.
    /// Guards against duplicate activation when SwiftUI recreates the App struct.
    private var sessionActivated = false
    
    /// Whether activate() has been called from onAppear.
    /// Guards against @Published mutations before SwiftUI's observation is ready.
    /// See: Intermittent crash in YourPodsWatch_Watch_AppApp.$main()
    private var hasBeenActivated = false

    /// Whether loadPersistedData() has completed in this process. The orphan
    /// GC must never run before this: a cold `.appRefresh` background launch
    /// skips onAppear (and therefore loadPersistedData), so episodes/
    /// recentEpisodes/libraryEpisodes are all empty — an ungated GC would
    /// classify every downloaded file as an orphan and mass-delete them.
    /// Main thread only (set in loadPersistedData's main-queue completion,
    /// read from handleQueueUpdate which is main-confined).
    ///
    /// Named distinctly from `YourPodsWatchApp`'s `@State hasLoadedPersistedData`
    /// (a different flag, same era) to end the duplicate-identifier confusion (W26).
    private var persistedDataLoaded = false

    /// Last context applied via refreshFromApplicationContext — skip identical
    /// re-processing on every scene activation (full queue rebuild + persistence).
    private var lastProcessedContext: NSDictionary?
    
    override init() {
        super.init()
        // CRASH FIX: Do NOT call setupSession() here. When this singleton is
        // created as `private let ... = .shared` in the App struct, init() runs
        // BEFORE SwiftUI evaluates body and wires observation. WCSession.activate()
        // can deliver pending applicationContext immediately, mutating @Published
        // properties on an un-observed ObservableObject
        // → double-free / use-after-free in Combine → intermittent crash at $main().
        //
        // This is now called from activate(), invoked by onAppear.
        
        // CAROUSEL FIX: Do NOT load UserDefaults data here.
        // Synchronous JSON decoding of large queues during init() blocks
        // the main thread and can exceed the watchOS launch watchdog.
        // Data is loaded lazily via loadPersistedData() from onAppear.
        setupDownloadHandler()
    }
    
    /// Activate WCSession and register observers. Must be called from onAppear,
    /// AFTER SwiftUI's observation infrastructure is ready.
    ///
    /// **NOT from init()** — see crash fix for intermittent $main() crash.
    /// WCSession.activate() can deliver pending applicationContext immediately,
    /// and NotificationCenter observers can fire before SwiftUI is ready.
    /// Both mutate @Published properties, which causes a double-free in Combine
    /// if the ObservableObjectPublisher hasn't been wired to any subscriber.
    func activate() {
        guard !hasBeenActivated else {
            logger.debug("Already activated — skipping")
            return
        }
        hasBeenActivated = true
        setupSession()
        logger.info("WatchSessionManager activated from onAppear")
    }
    
    /// Load persisted data from UserDefaults. Called from onAppear (not init)
    /// to avoid blocking the main thread during app launch.
    ///
    /// CAROUSEL FIX: Decodes JSON on the background persistence queue and
    /// hops back to main. Large queues (20+ episodes with chapters) can take
    /// 200-500ms to decode — dangerously close to the 2s watchOS main-thread
    /// watchdog when combined with other init() work.
    func loadPersistedData() {
        persistenceQueue.async { [weak self] in
            let episodes = Self.decodeFromDefaults([WatchEpisode].self, key: "saved_episodes")
            let library = Self.decodeFromDefaults([WatchPodcast].self, key: "saved_library")
            let recent = Self.decodeFromDefaults([WatchEpisode].self, key: "saved_recent_episodes")
            let interval = UserDefaults.standard.object(forKey: "positionSyncInterval") as? Double
            
            DispatchQueue.main.async {
                guard let self else { return }
                if let episodes { self.episodes = episodes }
                if let library { self.library = library }
                if let recent { self.recentEpisodes = recent }
                if let interval { self.positionSyncInterval = max(interval, 10.0) }
                // The load has actually applied — only now is the orphan GC
                // allowed to trust the in-memory lists as "everything we know".
                self.persistedDataLoaded = true
            }
        }
    }
    
    func setupSession() {
        // Guard: WCSession must be supported on this device
        guard WCSession.isSupported() else {
            logger.info("WCSession not supported on this device — skipping setup")
            return
        }
        // CAROUSEL FIX: Guard against duplicate activation. When watchOS
        // recreates the App struct during background wakes, init() is called
        // again. Re-activating WCSession causes undefined behavior.
        guard !sessionActivated else {
            logger.debug("WCSession already activated — skipping")
            return
        }
        sessionActivated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        logger.debug("WCSession activation requested")
    }
    
    private func setupDownloadHandler() {
        downloadManager.onDownloadComplete = { [weak self] episodeId, localPath in
            self?.updateEpisodeLocalPath(episodeId: episodeId, localPath: localPath)
        }
    }
    
    /// Re-read the latest `receivedApplicationContext` and process it.
    ///
    /// **Why this is needed:** `WCSession.didReceiveApplicationContext` fires
    /// exactly once — when the system delivers the context. If the app is
    /// suspended at delivery time, the data sits in `receivedApplicationContext`
    /// but the `@Published` properties are never updated. The UI shows stale
    /// data and appears "frozen."
    ///
    /// Call this from `scenePhase` `.active` transitions to catch up on any
    /// context that arrived during suspension.
    func refreshFromApplicationContext() {
        guard WCSession.default.activationState == .activated else {
            logger.debug("WCSession not activated — skipping context refresh")
            return
        }
        
        let context = WCSession.default.receivedApplicationContext
        guard !context.isEmpty else {
            logger.debug("No application context to refresh from")
            return
        }

        let snapshot = context as NSDictionary
        guard snapshot != lastProcessedContext else {
            logger.debug("Context unchanged since last processing — skipping")
            return
        }
        lastProcessedContext = snapshot

        logger.info("Refreshing from receivedApplicationContext on foreground resume")
        
        // Re-process using the same delegate path
        // This is safe to call redundantly — the handlers are idempotent
        // (they replace state rather than append)
        if let queue = context["queue"] as? [[String: Any]] {
            self.handleQueueUpdate(queue)
        }
        
        if let speed = context["speed"] as? Double {
            self.playbackSpeed = speed
        }
        
        if let info = context["playback_info"] as? [String: Any] {
            self.remoteTitle = info["title"] as? String ?? "Not Playing"
            self.remoteArtist = info["artist"] as? String ?? ""
            self.remoteIsPlaying = info["isPlaying"] as? Bool ?? false
            self.remoteEpisodeId = info["episodeId"] as? String
        }
        
        if let interval = context["positionSyncInterval"] as? Int {
            self.positionSyncInterval = Double(max(interval, 10))
            self.savePositionSyncInterval()
        }

        if let wifiOnly = context["wifiOnly"] as? Bool {
            self.downloadManager.updateNetworkPolicy(wifiOnly: wifiOnly)
        }

        if let fwd = context["skipForwardSeconds"] as? Int {
            self.skipForwardSeconds = fwd
            UserDefaults.standard.set(fwd, forKey: "skipForwardSeconds")
        }
        if let back = context["skipBackwardSeconds"] as? Int {
            self.skipBackwardSeconds = back
            UserDefaults.standard.set(back, forKey: "skipBackwardSeconds")
        }
    }

    /// Apply a queue payload (from applicationContext, a refresh_queue reply,
    /// or a background refresh). Main thread only.
    func applyQueueData(_ queue: [[String: Any]]) {
        handleQueueUpdate(queue)
    }

    /// Request fresh queue data from the iPhone.
    func requestQueueRefresh() {
        guard WCSession.default.isReachable else {
            logger.debug("iPhone not reachable for queue refresh")
            return
        }
        
        WCSession.default.sendMessage(
            ["command": "refresh_queue"],
            replyHandler: { [weak self] reply in
                if let queue = reply["queue"] as? [[String: Any]] {
                    DispatchQueue.main.async {
                        self?.handleQueueUpdate(queue)
                    }
                }
            },
            errorHandler: { [self] error in
                logger.error("Queue refresh request failed: \(error.localizedDescription)")
            }
        )
    }
    
    // MARK: - On-Device Download
    
    func downloadOnWatch(episode: WatchEpisode) {
        guard let streamUrl = episode.streamUrl else {
            logger.warning("No stream URL available for: \(episode.title)")
            return
        }
        // All downloadOnWatch call sites are explicit user taps (player,
        // remote player, library episode rows) — user origin, so the file is
        // manifest-protected from the orphan GC until explicitly deleted.
        downloadManager.startDownload(episodeId: episode.id, url: streamUrl, title: episode.title, origin: .user)
    }
    
    func cancelOnWatchDownload(episodeId: String) {
        downloadManager.cancelDownload(episodeId: episodeId)
    }
    
    func isDownloading(episodeId: String) -> Bool {
        return downloadManager.activeDownloads[episodeId] != nil
    }
    
    func downloadProgress(episodeId: String) -> Double {
        return downloadManager.activeDownloads[episodeId] ?? 0.0
    }
    
    /// Link a completed download into every list that might display the
    /// episode. Previously this only searched `episodes` (the queue), so
    /// Library and Recently-Updated downloads never got their localPath —
    /// the download completed but the episode still showed as not-downloaded.
    private func updateEpisodeLocalPath(episodeId: String, localPath: String) {
        var linked = false
        if let index = episodes.firstIndex(where: { $0.id == episodeId }) {
            episodes[index] = episodes[index].with(localPath: localPath)
            saveEpisodes()
            linked = true
        }
        if let recentIndex = recentEpisodes.firstIndex(where: { $0.id == episodeId }) {
            recentEpisodes[recentIndex] = recentEpisodes[recentIndex].with(localPath: localPath)
            saveRecentEpisodes()
            linked = true
        }
        for (feedUrl, feedEpisodes) in libraryEpisodes {
            if let i = feedEpisodes.firstIndex(where: { $0.id == episodeId }) {
                libraryEpisodes[feedUrl]?[i] = feedEpisodes[i].with(localPath: localPath)
                linked = true
            }
        }
        if linked {
            logger.info("Linked download to episode \(episodeId): \(localPath)")
        } else {
            logger.debug("Download completed for \(episodeId) but it is not in any current list")
        }
    }
    
    // MARK: - Delete Downloaded File
    
    func deleteLocalFile(for episode: WatchEpisode) {
        guard let localPath = episode.localPath else { return }
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent(localPath)
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
                logger.info("Deleted local file: \(localPath)")
            }
            
            // Clear localPath everywhere it was linked (queue, recently-updated,
            // library) — mirrors updateEpisodeLocalPath's linking so a deleted
            // file doesn't leave a stale "downloaded" state in another list.
            if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
                episodes[index] = episodes[index].with(localPath: nil)
                saveEpisodes()
            }
            if let recentIndex = recentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                recentEpisodes[recentIndex] = recentEpisodes[recentIndex].with(localPath: nil)
                saveRecentEpisodes()
            }
            for (feedUrl, feedEpisodes) in libraryEpisodes {
                if let i = feedEpisodes.firstIndex(where: { $0.id == episode.id }) {
                    libraryEpisodes[feedUrl]?[i] = feedEpisodes[i].with(localPath: nil)
                }
            }

            downloadManager.completedDownloads.remove(episode.id)
            // Explicit user delete — drop the manifest protection so the file
            // (already removed above) can't be resurrected as "referenced".
            downloadManager.removeCompletedDownloadRecord(for: episode.id)
        } catch {
            logger.error("Failed to delete local file: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Persistence
    //
    // CAROUSEL FIX: All save methods now dispatch to a background queue
    // with 0.5s debouncing. Rapid queue updates from iPhone are coalesced
    // into a single write, keeping the main thread free for UI.
    
    private func loadEpisodes() {
        if let data = UserDefaults.standard.data(forKey: "saved_episodes"),
           let saved = try? JSONDecoder().decode([WatchEpisode].self, from: data) {
            self.episodes = saved
        }
    }
    
    private func saveEpisodes() {
        saveEpisodesWorkItem?.cancel()
        let snapshot = episodes  // Capture current value on main thread
        let workItem = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "saved_episodes")
            }
        }
        saveEpisodesWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func loadRecentEpisodes() {
        if let data = UserDefaults.standard.data(forKey: "saved_recent_episodes"),
           let saved = try? JSONDecoder().decode([WatchEpisode].self, from: data) {
            self.recentEpisodes = saved
        }
    }
    
    private func saveRecentEpisodes() {
        saveRecentWorkItem?.cancel()
        let snapshot = recentEpisodes
        let workItem = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "saved_recent_episodes")
            }
        }
        saveRecentWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private func loadPositionSyncInterval() {
        if let saved = UserDefaults.standard.object(forKey: "positionSyncInterval") as? Double {
            self.positionSyncInterval = max(saved, 10.0)
        }
    }
    
    /// Decode a Codable type from UserDefaults on any thread.
    /// Used by loadPersistedData() to decode off-main-thread.
    private static func decodeFromDefaults<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    
    private func savePositionSyncInterval() {
        UserDefaults.standard.set(positionSyncInterval, forKey: "positionSyncInterval")
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        logger.info("Watch Session activated: \(activationState.rawValue)")
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
    }

    // Handle Application Context (Queue List Updates & Playback Info)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            // Handle Queue
            if let queue = applicationContext["queue"] as? [[String: Any]] {
                self.handleQueueUpdate(queue)
            }
            
            // Handle Speed
            if let speed = applicationContext["speed"] as? Double {
                self.playbackSpeed = speed
            }

            // Handle Playback Info
            if let info = applicationContext["playback_info"] as? [String: Any] {
                self.remoteTitle = info["title"] as? String ?? "Not Playing"
                self.remoteArtist = info["artist"] as? String ?? ""
                self.remoteIsPlaying = info["isPlaying"] as? Bool ?? false
                self.remoteEpisodeId = info["episodeId"] as? String
            }
            
            // Handle position sync interval setting from iPhone
            if let interval = applicationContext["positionSyncInterval"] as? Int {
                self.positionSyncInterval = Double(max(interval, 10))
                self.savePositionSyncInterval()
            }
            
            // Handle WiFi-only setting — push to download manager
            if let wifiOnly = applicationContext["wifiOnly"] as? Bool {
                self.downloadManager.updateNetworkPolicy(wifiOnly: wifiOnly)
            }

            // Handle skip-interval parity settings from iPhone
            if let fwd = applicationContext["skipForwardSeconds"] as? Int {
                self.skipForwardSeconds = fwd
                UserDefaults.standard.set(fwd, forKey: "skipForwardSeconds")
            }
            if let back = applicationContext["skipBackwardSeconds"] as? Int {
                self.skipBackwardSeconds = back
                UserDefaults.standard.set(back, forKey: "skipBackwardSeconds")
            }

            // Mark this payload as processed so a subsequent scene activation
            // (which re-reads receivedApplicationContext) skips it as unchanged.
            self.lastProcessedContext = applicationContext as NSDictionary
        }
    }

    // Handle incoming messages (library data, episodes)
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async {
            // Handle Library
            if let libraryData = message["library"] as? [[String: Any]] {
                self.handleLibraryUpdate(libraryData)
            }
            
            // Handle Episodes for a specific feed
            if let episodesData = message["episodes_for_feed"] as? [String: Any],
               let feedUrl = episodesData["feedUrl"] as? String,
               let episodes = episodesData["episodes"] as? [[String: Any]] {
                self.handleEpisodesForFeed(feedUrl: feedUrl, episodesData: episodes)
            }
            
            // Handle Recently Updated episodes
            if let recentData = message["recent_episodes"] as? [[String: Any]] {
                self.handleRecentEpisodes(recentData)
            }
        }
    }
    
    func sendRemoteCommand(_ command: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": command], replyHandler: nil) { [self] error in
            logger.error("Error sending command: \(error.localizedDescription)")
        }
    }
    
    func sendPlayQueue() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "playQueue"], replyHandler: nil) { [self] error in
            logger.error("Error sending playQueue: \(error.localizedDescription)")
        }
    }
    
    func sendPlayLatest(podcastName: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([
            "command": "playLatest",
            "podcastName": podcastName
        ], replyHandler: nil) { [self] error in
            logger.error("Error sending playLatest: \(error.localizedDescription)")
        }
    }
    
    /// Outstanding queued progress transfer per episode. Superseding a position
    /// must only cancel THIS episode's pending transfer — a single shared slot
    /// cancelled the previous episode's final position during offline
    /// multi-episode listening.
    private var progressTransfers: [String: WCSessionUserInfoTransfer] = [:]

    func sendProgress(episodeId: String, position: Int) {
        let payload = WatchWireFormat.encodeAction(
            .updateProgress, episodeId: episodeId, position: position,
            sentAt: Date().timeIntervalSince1970)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { [weak self] error in
                // Live send failed — fall back to the durable channel.
                self?.logger.error("Progress send failed, queueing transfer: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.queueProgressTransfer(payload, episodeId: episodeId) }
            }
        } else {
            queueProgressTransfer(payload, episodeId: episodeId)
        }
    }

    private func queueProgressTransfer(_ payload: [String: Any], episodeId: String) {
        progressTransfers[episodeId]?.cancel()
        progressTransfers[episodeId] = WCSession.default.transferUserInfo(payload)
    }

    /// Send an action durably: live message when reachable (with durable
    /// fallback on error), queued transfer otherwise. Action transfers are
    /// never cancelled/superseded.
    private func sendActionDurably(_ payload: [String: Any]) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { [weak self] error in
                self?.logger.error("Action send failed, queueing transfer: \(error.localizedDescription)")
                _ = WCSession.default.transferUserInfo(payload)
            }
        } else {
            _ = WCSession.default.transferUserInfo(payload)
        }
    }

    func markAsPlayed(for episodeId: String) {
        logger.info("Requesting mark as played for \(episodeId)")
        sendActionDurably(WatchWireFormat.encodeAction(
            .markAsPlayed, episodeId: episodeId, position: nil,
            sentAt: Date().timeIntervalSince1970))
        DispatchQueue.main.async {
            self.episodes.removeAll(where: { $0.id == episodeId })
            self.saveEpisodes()
        }
    }

    func removeFromQueue(for episodeId: String) {
        logger.info("Requesting remove from queue for \(episodeId)")
        sendActionDurably(WatchWireFormat.encodeAction(
            .removeFromQueue, episodeId: episodeId, position: nil,
            sentAt: Date().timeIntervalSince1970))
        DispatchQueue.main.async {
            self.episodes.removeAll(where: { $0.id == episodeId })
            self.saveEpisodes()
        }
    }

    private func handleQueueUpdate(_ queueData: [[String: Any]]) {
        // Parse+merge delegated to WatchQueueMerger — decodes
        // via WatchWireFormat.decodeQueueItem (the single source of truth) and
        // preserves watch-local state (localPath, and chapters/artUri when the
        // payload omits them) from the existing list, exactly as this method
        // did inline before.
        let newEpisodes = WatchQueueMerger.merge(rawQueue: queueData, existing: self.episodes)

        self.episodes = newEpisodes

        // Cold-launch gate: on a cold `.appRefresh` background launch, onAppear (and
        // therefore loadPersistedData) never ran, so `existing` above was empty
        // and WatchQueueMerger had nothing to preserve localPath from — every
        // merged episode's localPath is nil. Persisting that now would
        // overwrite the good on-disk "saved_episodes" list with a
        // localPath-stripped one, and auto-downloading over it would re-fetch
        // files that already exist on disk, over the radio, on every
        // background wake. Skip both; a later foreground load
        // (loadPersistedData) restores the authoritative list and its
        // localPaths. In-memory `episodes` above and everything below (orphan
        // GC — which self-gates on the same flag — and the complication
        // write) still run unconditionally so the queue UI/complication
        // reflect the fresh data immediately.
        if persistedDataLoaded {
            self.saveEpisodes()

            // Auto-download episodes flagged for it
            self.processAutoDownloads(queueData)
        } else {
            logger.debug("Skipping persistence/auto-downloads — persisted data not loaded (cold background launch)")
        }

        // Episodes leaving the queue (e.g. marked played, removed) can leave
        // their downloaded file behind with nothing referencing it anymore.
        self.collectOrphanedDownloads()

        let upNext = newEpisodes.first(where: { $0.id != WatchAudioManager.shared.currentEpisode?.id })
        WatchComplicationRefresher.update { data in
            data.queueCount = newEpisodes.count
            data.upNextTitle = upNext?.title
            data.upNextPodcast = upNext?.album
        }
    }

    /// Delete audio files no list references and no download is producing.
    ///
    /// Referenced = loaded-list localPaths ∪ current episode ∪ in-flight
    /// registry ∪ user-download manifest. Semantics: queue auto-downloads
    /// follow queue membership; user-initiated downloads never silently
    /// vanish (explicit delete only).
    private func collectOrphanedDownloads() {
        // C1 gate: on a cold `.appRefresh` background launch, onAppear (and
        // therefore loadPersistedData) never ran — the in-memory lists are
        // empty, NOT authoritative. Running the GC then would delete every
        // downloaded file. Called from handleQueueUpdate (main-confined),
        // matching where the flag is set.
        guard persistedDataLoaded else {
            logger.debug("Skipping orphan GC — persisted data not loaded")
            return
        }
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: docs.path) else {
                self.logger.warning("Orphan GC skipped — could not list Documents directory")
                return
            }

            var referenced = Set<String>()
            DispatchQueue.main.sync {
                referenced.formUnion(self.episodes.compactMap(\.localPath))
                referenced.formUnion(self.recentEpisodes.compactMap(\.localPath))
                for eps in self.libraryEpisodes.values { referenced.formUnion(eps.compactMap(\.localPath)) }
                if let current = WatchAudioManager.shared.currentEpisode?.localPath { referenced.insert(current) }
                // User-initiated downloads (I1): libraryEpisodes is never
                // persisted and the other lists may not mention the episode,
                // so the persistent manifest is what keeps a user's download
                // alive across relaunches. Manifest access is main-confined.
                referenced.formUnion(self.downloadManager.completedUserDownloadFilenames())
            }
            let registry = (UserDefaults.standard.dictionary(forKey: "watch_download_registry") as? [String: String]) ?? [:]
            referenced.formUnion(registry.values)   // in-flight downloads

            var deleted = Set<String>()
            for orphan in WatchDownloadHygiene.orphans(existingFiles: files, referenced: referenced) {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(orphan))
                self.logger.info("Removed orphaned download: \(orphan)")
                deleted.insert(orphan)
            }
            if !deleted.isEmpty {
                // Manifest writes are main-confined — hop before mutating.
                DispatchQueue.main.async {
                    self.downloadManager.removeManifestEntries(pointingTo: deleted)
                }
            }
        }
    }

    private func processAutoDownloads(_ queueData: [[String: Any]]) {
        for item in queueData {
            guard let autoDownload = item["autoDownload"] as? Bool, autoDownload,
                  let id = item["id"] as? String,
                  let url = item["url"] as? String,
                  let title = item["title"] as? String else { continue }
            
            // Skip if already downloaded
            if let episode = episodes.first(where: { $0.id == id }), episode.localPath != nil { continue }
            // Skip if already downloading
            if downloadManager.activeDownloads[id] != nil { continue }
            // Skip if completed in this session
            if downloadManager.completedDownloads.contains(id) { continue }
            
            // Network policy (wifiOnly) is enforced per-task via
            // URLRequest.allowsCellularAccess in WatchDownloadManager.startDownload().
            // No manual NWPathMonitor check needed.
            
            logger.info("Starting auto-download for \(title)")
            downloadManager.startDownload(episodeId: id, url: url, title: title, origin: .queue)
        }
    }
    
    // MARK: - Library
    
    private func handleLibraryUpdate(_ libraryData: [[String: Any]]) {
        var newLibrary: [WatchPodcast] = []
        for item in libraryData {
            guard let feedUrl = item["feedUrl"] as? String else { continue }
            let podcast = WatchPodcast(
                id: feedUrl,
                title: item["title"] as? String ?? "Unknown",
                feedUrl: feedUrl,
                artUri: item["artUri"] as? String,
                author: item["author"] as? String ?? ""
            )
            newLibrary.append(podcast)
        }
        self.library = newLibrary
        self.saveLibrary()
        logger.info("Library updated: \(newLibrary.count) podcasts")
    }
    
    private func handleEpisodesForFeed(feedUrl: String, episodesData: [[String: Any]]) {
        var episodes: [WatchEpisode] = []
        for item in episodesData {
            guard let decoded = WatchWireFormat.decodeEpisodeListItem(item) else { continue }
            episodes.append(WatchEpisode(
                id: decoded.guid,
                title: decoded.title,
                album: "",
                artist: "",
                duration: decoded.duration,
                localPath: nil,
                streamUrl: decoded.audioUrl,
                artUri: decoded.imageUrl,
                isAvailableOnPhone: false,
                chapters: nil,
                position: 0))
        }
        self.libraryEpisodes[feedUrl] = episodes
        self.episodeRequestFailed.remove(feedUrl)
        logger.info("Got \(episodes.count) episodes for feed \(feedUrl)")
    }
    
    func requestLibrary() {
        guard WCSession.default.isReachable else {
            logger.debug("iPhone not reachable for library request")
            return
        }
        WCSession.default.sendMessage(
            ["command": "request_library"],
            replyHandler: nil,
            errorHandler: { [self] error in
                logger.error("Library request failed: \(error.localizedDescription)")
            }
        )
    }
    
    func requestEpisodes(feedUrl: String) {
        guard WCSession.default.isReachable else {
            logger.debug("iPhone not reachable for episodes request")
            return
        }
        // Called from view callbacks (main thread) — reset any previous failure
        // for this feed so the view returns to its loading state.
        episodeRequestFailed.remove(feedUrl)
        WCSession.default.sendMessage(
            ["command": "request_episodes", "feedUrl": feedUrl],
            replyHandler: nil,
            errorHandler: { [self] error in
                logger.error("Episodes request failed: \(error.localizedDescription)")
                // errorHandler arrives on a non-main queue — hop before mutating @Published.
                DispatchQueue.main.async {
                    self.episodeRequestFailed.insert(feedUrl)
                }
            }
        )
    }
    
    // MARK: - Recently Updated
    
    func requestRecentEpisodes() {
        guard WCSession.default.isReachable else {
            logger.debug("iPhone not reachable for recent episodes request")
            return
        }
        WCSession.default.sendMessage(
            ["command": "request_recent_episodes"],
            replyHandler: nil,
            errorHandler: { [self] error in
                logger.error("Recent episodes request failed: \(error.localizedDescription)")
            }
        )
    }
    
    private func handleRecentEpisodes(_ episodesData: [[String: Any]]) {
        var episodes: [WatchEpisode] = []
        let dateFormatter = ISO8601DateFormatter()
        
        for item in episodesData {
            guard let decoded = WatchWireFormat.decodeEpisodeListItem(item) else { continue }

            var pubDate: Date? = nil
            if let dateStr = item["pubDate"] as? String {
                pubDate = dateFormatter.date(from: dateStr)
            }

            let episode = WatchEpisode(
                id: decoded.guid,
                title: decoded.title,
                album: item["podcastTitle"] as? String ?? "",
                artist: item["podcastTitle"] as? String ?? "",
                duration: decoded.duration,
                localPath: nil,
                streamUrl: decoded.audioUrl,
                artUri: decoded.imageUrl,
                isAvailableOnPhone: true,
                chapters: nil,
                position: 0,
                pubDate: pubDate,
                podcastTitle: item["podcastTitle"] as? String,
                podcastArtUri: item["podcastArtUri"] as? String
            )
            episodes.append(episode)
        }
        
        // Enforce limit and sort by pubDate descending
        self.recentEpisodes = Array(
            episodes
                .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                .prefix(Self.recentEpisodesLimit)
        )
        self.saveRecentEpisodes()
        logger.info("Recently updated: \(self.recentEpisodes.count) episodes")
    }
    
    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: "saved_library"),
           let saved = try? JSONDecoder().decode([WatchPodcast].self, from: data) {
            self.library = saved
        }
    }
    
    private func saveLibrary() {
        saveLibraryWorkItem?.cancel()
        let snapshot = library
        let workItem = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "saved_library")
            }
        }
        saveLibraryWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    // Handle File Transfer
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata else { return }
        self.handleReceivedFile(file: file, metadata: metadata)
    }
    
    private func handleReceivedFile(file: WCSessionFile, metadata: [String: Any]) {
        let destURL = getDocumentsDirectory().appendingPathComponent(file.fileURL.lastPathComponent)

        DispatchQueue.global(qos: .background).async {
            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.moveItem(at: file.fileURL, to: destURL)

                let id = metadata["id"] as? String ?? UUID().uuidString
                let filename = file.fileURL.lastPathComponent

                DispatchQueue.main.async {
                    // W24: route through the same linking logic as an on-watch
                    // download (updateEpisodeLocalPath) instead of hand-reconstructing
                    // the episode — the hand-rolled version dropped pubDate/
                    // podcastTitle/podcastArtUri and only ever checked `episodes`,
                    // missing Library/Recently-Updated links.
                    self.updateEpisodeLocalPath(episodeId: id, localPath: filename)
                }

            } catch {
                self.logger.error("Error moving file: \(error.localizedDescription)")
            }
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

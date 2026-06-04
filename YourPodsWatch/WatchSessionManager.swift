import Foundation
import WatchConnectivity
import Combine
import WatchKit
import os

struct WatchChapter: Identifiable, Codable {
    var id: Double { startTime }
    let startTime: Double // seconds
    let title: String
    let img: String?
    let url: String?
}

struct WatchEpisode: Identifiable, Codable {
    let id: String
    let title: String
    let album: String
    let artist: String
    let duration: Int
    let localPath: String? // Path relative to Documents directory
    let streamUrl: String? // Remote URL for streaming
    let artUri: String? // Cover art URL
    let isAvailableOnPhone: Bool // If true, can be manually downloaded
    let chapters: [WatchChapter]? // Episode chapters (if available)
    var position: Int // Playback position in seconds (synced from iOS)
    let pubDate: Date? // Episode publish date (for Recently Updated sorting)
    let podcastTitle: String? // Podcast name (for cross-podcast display)
    let podcastArtUri: String? // Podcast artwork URL (for Recently Updated)
    
    /// Backward-compatible decoder — new optional fields default to nil
    /// when decoding payloads from older iOS app versions or persisted data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        album = try container.decode(String.self, forKey: .album)
        artist = try container.decode(String.self, forKey: .artist)
        duration = try container.decode(Int.self, forKey: .duration)
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
        streamUrl = try container.decodeIfPresent(String.self, forKey: .streamUrl)
        artUri = try container.decodeIfPresent(String.self, forKey: .artUri)
        isAvailableOnPhone = try container.decode(Bool.self, forKey: .isAvailableOnPhone)
        chapters = try container.decodeIfPresent([WatchChapter].self, forKey: .chapters)
        position = try container.decode(Int.self, forKey: .position)
        pubDate = try container.decodeIfPresent(Date.self, forKey: .pubDate)
        podcastTitle = try container.decodeIfPresent(String.self, forKey: .podcastTitle)
        podcastArtUri = try container.decodeIfPresent(String.self, forKey: .podcastArtUri)
    }
    
    init(id: String, title: String, album: String, artist: String, duration: Int,
         localPath: String?, streamUrl: String?, artUri: String?,
         isAvailableOnPhone: Bool, chapters: [WatchChapter]?, position: Int,
         pubDate: Date? = nil, podcastTitle: String? = nil, podcastArtUri: String? = nil) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.duration = duration
        self.localPath = localPath
        self.streamUrl = streamUrl
        self.artUri = artUri
        self.isAvailableOnPhone = isAvailableOnPhone
        self.chapters = chapters
        self.position = position
        self.pubDate = pubDate
        self.podcastTitle = podcastTitle
        self.podcastArtUri = podcastArtUri
    }
}

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
    
    @Published var activeDownloads: [String: Double] = [:] // episodeId -> progress (0.0-1.0)
    @Published var completedDownloads: Set<String> = []
    
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var episodeInfo: [String: (url: String, title: String)] = [:]
    private var downloadQueue: [(episodeId: String, url: String, title: String)] = []
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
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    override init() {
        super.init()
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
        device.isBatteryMonitoringEnabled = true
        return device.batteryLevel >= 0 && device.batteryLevel < 0.10
    }
    
    /// Max concurrent downloads to avoid radio contention
    private let maxConcurrentDownloads = 1
    
    /// Update the Wi-Fi-only network policy. New downloads will respect this;
    /// in-flight downloads are not interrupted.
    func updateNetworkPolicy(wifiOnly: Bool) {
        currentWifiOnly = wifiOnly
    }
    
    func startDownload(episodeId: String, url: String, title: String) {
        guard downloadTasks[episodeId] == nil else {
            logger.debug("Download already in progress for \(episodeId)")
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
            downloadQueue.append((episodeId: episodeId, url: url, title: title))
            return
        }
        
        guard let downloadUrl = URL(string: url) else {
            logger.error("Invalid URL for download: \(url)")
            return
        }
        
        logger.info("Starting on-watch download for: \(title) (wifiOnly: \(self.currentWifiOnly))")
        episodeInfo[episodeId] = (url, title)
        activeDownloads[episodeId] = 0.0
        lastBytesReceived[episodeId] = Date()
        
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
        
        // Start next queued download if any
        processQueue()
    }
    
    private func processQueue() {
        guard downloadTasks.count < maxConcurrentDownloads,
              !downloadQueue.isEmpty else { return }
        let next = downloadQueue.removeFirst()
        startDownload(episodeId: next.episodeId, url: next.url, title: next.title)
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let episodeId = downloadTask.taskDescription else { return }
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Sanitize episode ID to create a valid filename
        let sanitizedId = episodeId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        
        let filename: String
        if sanitizedId.count > 100 {
            let hash = episodeId.data(using: .utf8)?.hashValue ?? Int.random(in: 0..<Int.max)
            filename = "episode_\(abs(hash)).mp3"
        } else {
            filename = "\(sanitizedId).mp3"
        }
        
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
                self.onDownloadComplete?(episodeId, filename)
                self.processQueue()
            }
        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.downloadTasks.removeValue(forKey: episodeId)
                self.activeDownloads.removeValue(forKey: episodeId)
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
    
    // Track pending downloads (from iPhone) to show UI state if needed
    @Published var pendingDownloads: Set<String> = []
    
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
    
    override init() {
        super.init()
        // CRASH FIX: Do NOT call setupSession() or setupBackgroundRefreshHandler()
        // here. When this singleton is created as `private let ... = .shared` in the
        // App struct, init() runs BEFORE SwiftUI evaluates body and wires observation.
        // WCSession.activate() can deliver pending applicationContext immediately,
        // mutating @Published properties on an un-observed ObservableObject
        // → double-free / use-after-free in Combine → intermittent crash at $main().
        //
        // These are now called from activate(), invoked by onAppear.
        
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
        setupBackgroundRefreshHandler()
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
    
    /// Listen for background refresh notifications from BackgroundRefreshManager.
    private func setupBackgroundRefreshHandler() {
        NotificationCenter.default.addObserver(
            forName: .backgroundQueueRefresh,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let queue = notification.userInfo?["queue"] as? [[String: Any]] {
                self?.logger.info("Processing background queue refresh with \(queue.count) items")
                self?.handleQueueUpdate(queue)
            }
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
        downloadManager.startDownload(episodeId: episode.id, url: streamUrl, title: episode.title)
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
    
    private func updateEpisodeLocalPath(episodeId: String, localPath: String) {
        if let index = episodes.firstIndex(where: { $0.id == episodeId }) {
            let old = episodes[index]
            let updated = WatchEpisode(
                id: old.id,
                title: old.title,
                album: old.album,
                artist: old.artist,
                duration: old.duration,
                localPath: localPath,
                streamUrl: old.streamUrl,
                artUri: old.artUri,
                isAvailableOnPhone: old.isAvailableOnPhone,
                chapters: old.chapters,
                position: old.position
            )
            episodes[index] = updated
            saveEpisodes()
            logger.info("Updated episode with local path: \(updated.title)")
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
            
            // Update episode to clear localPath
            if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
                let old = episodes[index]
                let updated = WatchEpisode(
                    id: old.id,
                    title: old.title,
                    album: old.album,
                    artist: old.artist,
                    duration: old.duration,
                    localPath: nil, // Clear local path
                    streamUrl: old.streamUrl,
                    artUri: old.artUri,
                    isAvailableOnPhone: old.isAvailableOnPhone,
                    chapters: old.chapters,
                    position: old.position
                )
                episodes[index] = updated
                saveEpisodes()
            }
            
            downloadManager.completedDownloads.remove(episode.id)
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
    
    func requestDownload(for episodeId: String) {
        guard WCSession.default.isReachable else { return }
        logger.info("Requesting download for \(episodeId)")
        pendingDownloads.insert(episodeId)
        
        WCSession.default.sendMessage([
            "command": "request_download",
            "episodeId": episodeId
        ], replyHandler: nil) { [self] error in
            logger.error("Error requesting download: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingDownloads.remove(episodeId)
            }
        }
    }
    
    func removeFromQueue(for episodeId: String) {
        guard WCSession.default.isReachable else { return }
        logger.info("Requesting remove from queue for \(episodeId)")
        
        WCSession.default.sendMessage([
            "command": "remove_from_queue",
            "episodeId": episodeId
        ], replyHandler: nil)
        
        // Optimistically remove from local list
        DispatchQueue.main.async {
            self.episodes.removeAll(where: { $0.id == episodeId })
            self.saveEpisodes()
        }
    }
    
    func sendProgress(episodeId: String, position: Int) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([
            "command": "update_progress",
            "episodeId": episodeId,
            "position": position
        ], replyHandler: nil) { [self] error in
            logger.error("Error sending progress: \(error.localizedDescription)")
        }
    }

    func markAsPlayed(for episodeId: String) {
        guard WCSession.default.isReachable else { return }
        logger.info("Requesting mark as played for \(episodeId)")
        
        WCSession.default.sendMessage([
            "command": "mark_as_played",
            "episodeId": episodeId
        ], replyHandler: nil)
        
        // Optimistically remove/update? Usually playing means it's done. 
        // Let's remove it from queue as standard behavior for "Mark as Played" in this app context often means "Archived"
        DispatchQueue.main.async {
            self.episodes.removeAll(where: { $0.id == episodeId })
            self.saveEpisodes()
        }
    }

    private func handleQueueUpdate(_ queueData: [[String: Any]]) {
        var newEpisodes: [WatchEpisode] = []
        
        // 1. Build list from Context (Order matters!)
        for item in queueData {
            guard let id = item["id"] as? String else { continue }
            
            // Try to find existing episode to preserve local path if we had it
            let existing = self.episodes.first(where: { $0.id == id })
            
            // If we have a local path but the file is gone, reset it?
            // For now, assume if we have a path, it's good.
            
            // Parse chapters if present
            var parsedChapters: [WatchChapter]? = nil
            if let chaptersData = item["chapters"] as? [[String: Any]] {
                parsedChapters = chaptersData.compactMap { chData in
                    guard let startTime = chData["startTime"] as? Double,
                          let title = chData["title"] as? String else { return nil }
                    return WatchChapter(
                        startTime: startTime,
                        title: title,
                        img: chData["img"] as? String,
                        url: chData["url"] as? String
                    )
                }
                if parsedChapters?.isEmpty == true { parsedChapters = nil }
            }
            
            // Use the server position, but preserve local position if it's ahead
            // (e.g., watch was actively playing this episode)
            let serverPosition = item["position"] as? Int ?? 0
            let localPosition = existing?.position ?? 0
            let effectivePosition = max(serverPosition, localPosition)
            
            let newEpisode = WatchEpisode(
                id: id,
                title: item["title"] as? String ?? "Unknown",
                album: item["album"] as? String ?? "",
                artist: item["artist"] as? String ?? "",
                duration: item["duration"] as? Int ?? 0,
                localPath: existing?.localPath, // Keep path if we had it, otherwise nil
                streamUrl: item["url"] as? String,
                artUri: item["artUri"] as? String ?? existing?.artUri,
                isAvailableOnPhone: item["isAvailableOnPhone"] as? Bool ?? false,
                chapters: parsedChapters ?? existing?.chapters,
                position: effectivePosition
            )
            newEpisodes.append(newEpisode)
        }
        
        self.episodes = newEpisodes
        self.saveEpisodes()
        
        // Auto-download episodes flagged for it
        self.processAutoDownloads(queueData)
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
            downloadManager.startDownload(episodeId: id, url: url, title: title)
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
            guard let guid = item["guid"] as? String else { continue }
            let episode = WatchEpisode(
                id: guid,
                title: item["title"] as? String ?? "Unknown",
                album: "",
                artist: "",
                duration: item["duration"] as? Int ?? 0,
                localPath: nil,
                streamUrl: item["audioUrl"] as? String,
                artUri: item["imageUrl"] as? String,
                isAvailableOnPhone: false,
                chapters: nil,
                position: 0
            )
            episodes.append(episode)
        }
        self.libraryEpisodes[feedUrl] = episodes
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
        WCSession.default.sendMessage(
            ["command": "request_episodes", "feedUrl": feedUrl],
            replyHandler: nil,
            errorHandler: { [self] error in
                logger.error("Episodes request failed: \(error.localizedDescription)")
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
            guard let id = item["id"] as? String else { continue }
            
            var pubDate: Date? = nil
            if let dateStr = item["pubDate"] as? String {
                pubDate = dateFormatter.date(from: dateStr)
            }
            
            let episode = WatchEpisode(
                id: id,
                title: item["title"] as? String ?? "Unknown",
                album: item["podcastTitle"] as? String ?? "",
                artist: item["podcastTitle"] as? String ?? "",
                duration: item["duration"] as? Int ?? 0,
                localPath: nil,
                streamUrl: item["audioUrl"] as? String,
                artUri: item["imageUrl"] as? String,
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

                DispatchQueue.main.async {
                    self.pendingDownloads.remove(id) // Clear pending state

                    // We need to update the specific episode in our list with the new local path
                    if let index = self.episodes.firstIndex(where: { $0.id == id }) {
                        let old = self.episodes[index]
                        let updated = WatchEpisode(
                            id: old.id,
                            title: old.title,
                            album: old.album,
                            artist: old.artist,
                            duration: old.duration,
                            localPath: file.fileURL.lastPathComponent,
                            streamUrl: old.streamUrl,
                            artUri: old.artUri,
                            isAvailableOnPhone: old.isAvailableOnPhone,
                            chapters: old.chapters,
                            position: old.position
                        )
                        self.episodes[index] = updated
                        self.saveEpisodes()
                        self.logger.info("Received and updated episode: \(updated.title)")
                    } else {
                        // If it wasn't in list (maybe synced in background?), add it?
                        // Usually we only care about queue itms.
                        self.logger.debug("Received file for episode not in queue: \(id)")
                    }
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

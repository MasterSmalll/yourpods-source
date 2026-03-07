import Foundation
import WatchConnectivity
import Combine
import WatchKit

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
    
    /// Whether to restrict downloads to Wi-Fi only (blocks watch cellular radio).
    private var currentWifiOnly: Bool = true
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionId)
        config.isDiscretionary = false          // download ASAP, not at system discretion
        config.sessionSendsLaunchEvents = true  // wake app on download completion
        config.allowsCellularAccess = true      // per-task override in startDownload()
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    var onDownloadComplete: ((String, String) -> Void)? // (episodeId, localPath)
    
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
            print("Download already in progress for \(episodeId)")
            return
        }
        
        // Skip if battery too low
        if isBatteryTooLow {
            print("Skipping download for \(title) — battery too low")
            return
        }
        
        // Queue if max concurrent reached
        if downloadTasks.count >= maxConcurrentDownloads {
            print("Queueing download for \(title) (max concurrent reached)")
            downloadQueue.append((episodeId: episodeId, url: url, title: title))
            return
        }
        
        guard let downloadUrl = URL(string: url) else {
            print("Invalid URL for download: \(url)")
            return
        }
        
        print("Starting on-watch download for: \(title) (wifiOnly: \(currentWifiOnly))")
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
                print("Download stalled for \(episodeId) — cancelling")
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
            print("Download complete for \(episodeId): \(destinationURL.path)")
            
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
            print("Failed to move downloaded file: \(error)")
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
        
        print("Download failed for \(episodeId): \(error?.localizedDescription ?? "unknown")")
        
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
    @Published var episodes: [WatchEpisode] = []
    @Published var playbackSpeed: Double = 1.0
    
    // Remote Control State
    @Published var remoteTitle: String = "Not Playing"
    @Published var remoteArtist: String = ""
    @Published var remoteIsPlaying: Bool = false
    @Published var remoteEpisodeId: String? = nil
    
    // Library (subscriptions)
    @Published var library: [WatchPodcast] = []
    @Published var libraryEpisodes: [String: [WatchEpisode]] = [:] // feedUrl -> episodes
    
    // Track pending downloads (from iPhone) to show UI state if needed
    @Published var pendingDownloads: Set<String> = []
    
    // On-device download manager
    let downloadManager = WatchDownloadManager.shared
    
    /// The currently-playing episode (looked up from episodes list)
    var currentEpisode: WatchEpisode? {
        guard let id = remoteEpisodeId else { return nil }
        return episodes.first(where: { $0.id == id })
    }
    
    override init() {
        super.init()
        setupSession()
        loadEpisodes()
        loadLibrary()
        setupDownloadHandler()
        setupBackgroundRefreshHandler()
    }
    
    func setupSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
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
                print("[WatchSession] Processing background queue refresh with \(queue.count) items")
                self?.handleQueueUpdate(queue)
            }
        }
    }
    

    
    /// Request fresh queue data from the iPhone.
    func requestQueueRefresh() {
        guard WCSession.default.isReachable else {
            print("[WatchSession] iPhone not reachable for queue refresh")
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
            errorHandler: { error in
                print("[WatchSession] Queue refresh request failed: \(error.localizedDescription)")
            }
        )
    }
    
    // MARK: - On-Device Download
    
    func downloadOnWatch(episode: WatchEpisode) {
        guard let streamUrl = episode.streamUrl else {
            print("No stream URL available for: \(episode.title)")
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
                chapters: old.chapters
            )
            episodes[index] = updated
            saveEpisodes()
            print("Updated episode with local path: \(updated.title)")
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
                print("Deleted local file: \(localPath)")
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
                    chapters: old.chapters
                )
                episodes[index] = updated
                saveEpisodes()
            }
            
            downloadManager.completedDownloads.remove(episode.id)
        } catch {
            print("Failed to delete local file: \(error)")
        }
    }
    
    // MARK: - Persistence
    private func loadEpisodes() {
        if let data = UserDefaults.standard.data(forKey: "saved_episodes"),
           let saved = try? JSONDecoder().decode([WatchEpisode].self, from: data) {
            self.episodes = saved
        }
    }
    
    private func saveEpisodes() {
        if let data = try? JSONEncoder().encode(episodes) {
            UserDefaults.standard.set(data, forKey: "saved_episodes")
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print("Watch Session activated: \(activationState.rawValue)")
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
        }
    }
    
    func sendRemoteCommand(_ command: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": command], replyHandler: nil) { error in
            print("Error sending command: \(error.localizedDescription)")
        }
    }
    
    func sendPlayQueue() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "playQueue"], replyHandler: nil) { error in
            print("Error sending playQueue: \(error.localizedDescription)")
        }
    }
    
    func sendPlayLatest(podcastName: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([
            "command": "playLatest",
            "podcastName": podcastName
        ], replyHandler: nil) { error in
            print("Error sending playLatest: \(error.localizedDescription)")
        }
    }
    
    func requestDownload(for episodeId: String) {
        guard WCSession.default.isReachable else { return }
        print("Requesting download for \(episodeId)")
        pendingDownloads.insert(episodeId)
        
        WCSession.default.sendMessage([
            "command": "request_download",
            "episodeId": episodeId
        ], replyHandler: nil) { error in
            print("Error requesting download: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingDownloads.remove(episodeId)
            }
        }
    }
    
    func removeFromQueue(for episodeId: String) {
        guard WCSession.default.isReachable else { return }
        print("Requesting remove from queue for \(episodeId)")
        
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
        ], replyHandler: nil) { error in
            print("Error sending progress: \(error.localizedDescription)")
        }
    }

    func markAsPlayed(for episodeId: String) {
        guard WCSession.default.isReachable else { return }
        print("Requesting mark as played for \(episodeId)")
        
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
                chapters: parsedChapters ?? existing?.chapters
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
            
            print("[AutoDownload] Starting auto-download for \(title)")
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
        print("[WatchSession] Library updated: \(newLibrary.count) podcasts")
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
                chapters: nil
            )
            episodes.append(episode)
        }
        self.libraryEpisodes[feedUrl] = episodes
        print("[WatchSession] Got \(episodes.count) episodes for feed \(feedUrl)")
    }
    
    func requestLibrary() {
        guard WCSession.default.isReachable else {
            print("[WatchSession] iPhone not reachable for library request")
            return
        }
        WCSession.default.sendMessage(
            ["command": "request_library"],
            replyHandler: nil,
            errorHandler: { error in
                print("[WatchSession] Library request failed: \(error.localizedDescription)")
            }
        )
    }
    
    func requestEpisodes(feedUrl: String) {
        guard WCSession.default.isReachable else {
            print("[WatchSession] iPhone not reachable for episodes request")
            return
        }
        WCSession.default.sendMessage(
            ["command": "request_episodes", "feedUrl": feedUrl],
            replyHandler: nil,
            errorHandler: { error in
                print("[WatchSession] Episodes request failed: \(error.localizedDescription)")
            }
        )
    }
    
    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: "saved_library"),
           let saved = try? JSONDecoder().decode([WatchPodcast].self, from: data) {
            self.library = saved
        }
    }
    
    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: "saved_library")
        }
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
                            chapters: old.chapters
                        )
                        self.episodes[index] = updated
                        self.saveEpisodes()
                        print("Received and updated episode: \(updated.title)")
                    } else {
                        // If it wasn't in list (maybe synced in background?), add it?
                        // Usually we only care about queue itms.
                        print("Received file for episode not in queue: \(id)")
                    }
                }

            } catch {
                print("Error moving file: \(error)")
            }
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

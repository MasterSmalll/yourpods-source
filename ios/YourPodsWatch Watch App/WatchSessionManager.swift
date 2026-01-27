import Foundation
import WatchConnectivity
import Combine

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
}

// MARK: - Download Manager for on-device downloads
class WatchDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = WatchDownloadManager()
    
    @Published var activeDownloads: [String: Double] = [:] // episodeId -> progress (0.0-1.0)
    @Published var completedDownloads: Set<String> = []
    
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var episodeInfo: [String: (url: String, title: String)] = [:]
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    var onDownloadComplete: ((String, String) -> Void)? // (episodeId, localPath)
    
    func startDownload(episodeId: String, url: String, title: String) {
        guard downloadTasks[episodeId] == nil else {
            print("Download already in progress for \(episodeId)")
            return
        }
        
        guard let downloadUrl = URL(string: url) else {
            print("Invalid URL for download: \(url)")
            return
        }
        
        print("Starting on-watch download for: \(title)")
        episodeInfo[episodeId] = (url, title)
        activeDownloads[episodeId] = 0.0
        
        let task = session.downloadTask(with: downloadUrl)
        task.taskDescription = episodeId
        downloadTasks[episodeId] = task
        task.resume()
    }
    
    func cancelDownload(episodeId: String) {
        downloadTasks[episodeId]?.cancel()
        downloadTasks.removeValue(forKey: episodeId)
        activeDownloads.removeValue(forKey: episodeId)
        episodeInfo.removeValue(forKey: episodeId)
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let episodeId = downloadTask.taskDescription else { return }
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Sanitize episode ID to create a valid filename
        // Replace invalid characters and hash if too long
        let sanitizedId = episodeId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        
        // If still too long, use a hash
        let filename: String
        if sanitizedId.count > 100 {
            // Create a simple hash from the episode ID
            let hash = episodeId.data(using: .utf8)?.hashValue ?? Int.random(in: 0..<Int.max)
            filename = "episode_\(abs(hash)).mp3"
        } else {
            filename = "\(sanitizedId).mp3"
        }
        
        let destinationURL = documentsURL.appendingPathComponent(filename)
        
        do {
            // Remove existing file if present
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            // Move downloaded file
            try fileManager.moveItem(at: location, to: destinationURL)
            
            print("Download complete for \(episodeId): \(destinationURL.path)")
            
            DispatchQueue.main.async {
                self.downloadTasks.removeValue(forKey: episodeId)
                self.activeDownloads.removeValue(forKey: episodeId)
                self.completedDownloads.insert(episodeId)
                self.onDownloadComplete?(episodeId, filename)
            }
        } catch {
            print("Failed to move downloaded file: \(error)")
            DispatchQueue.main.async {
                self.downloadTasks.removeValue(forKey: episodeId)
                self.activeDownloads.removeValue(forKey: episodeId)
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
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let episodeId = task.taskDescription, error != nil else { return }
        
        print("Download failed for \(episodeId): \(error?.localizedDescription ?? "unknown")")
        
        DispatchQueue.main.async {
            self.downloadTasks.removeValue(forKey: episodeId)
            self.activeDownloads.removeValue(forKey: episodeId)
        }
    }
}

class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    @Published var episodes: [WatchEpisode] = []
    
    // Remote Control State
    @Published var remoteTitle: String = "Not Playing"
    @Published var remoteArtist: String = ""
    @Published var remoteIsPlaying: Bool = false
    
    // Track pending downloads (from iPhone) to show UI state if needed
    @Published var pendingDownloads: Set<String> = []
    
    // On-device download manager
    let downloadManager = WatchDownloadManager.shared
    
    override init() {
        super.init()
        setupSession()
        loadEpisodes()
        setupDownloadHandler()
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
                isAvailableOnPhone: old.isAvailableOnPhone
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
                    isAvailableOnPhone: old.isAvailableOnPhone
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
            
            // Handle Playback Info
            if let info = applicationContext["playback_info"] as? [String: Any] {
                self.remoteTitle = info["title"] as? String ?? "Not Playing"
                self.remoteArtist = info["artist"] as? String ?? ""
                self.remoteIsPlaying = info["isPlaying"] as? Bool ?? false
            }
        }
    }
    
    func sendRemoteCommand(_ command: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": command], replyHandler: nil) { error in
            print("Error sending command: \(error.localizedDescription)")
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
            
            let newEpisode = WatchEpisode(
                id: id,
                title: item["title"] as? String ?? "Unknown",
                album: item["album"] as? String ?? "",
                artist: item["artist"] as? String ?? "",
                duration: item["duration"] as? Int ?? 0,
                localPath: existing?.localPath, // Keep path if we had it, otherwise nil
                streamUrl: item["url"] as? String,
                artUri: item["artUri"] as? String ?? existing?.artUri,
                isAvailableOnPhone: item["isAvailableOnPhone"] as? Bool ?? false
            )
            newEpisodes.append(newEpisode)
        }
        
        self.episodes = newEpisodes
        self.saveEpisodes() 
    }
    
    // Handle File Transfer
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata else { return }
        
        DispatchQueue.main.async {
            self.handleReceivedFile(file: file, metadata: metadata)
        }
    }
    
    private func handleReceivedFile(file: WCSessionFile, metadata: [String: Any]) {
        let fileManager = FileManager.default
        let destURL = getDocumentsDirectory().appendingPathComponent(file.fileURL.lastPathComponent)
        
        do {
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: file.fileURL, to: destURL)
            
            let id = metadata["id"] as? String ?? UUID().uuidString
            pendingDownloads.remove(id) // Clear pending state
            
            // We need to update the specific episode in our list with the new local path
            if let index = episodes.firstIndex(where: { $0.id == id }) {
                let old = episodes[index]
                let updated = WatchEpisode(
                    id: old.id,
                    title: old.title,
                    album: old.album,
                    artist: old.artist,
                    duration: old.duration,
                    localPath: file.fileURL.lastPathComponent,
                    streamUrl: old.streamUrl,
                    artUri: old.artUri,
                    isAvailableOnPhone: old.isAvailableOnPhone
                )
                episodes[index] = updated
                saveEpisodes()
                print("Received and updated episode: \(updated.title)")
            } else {
                // If it wasn't in list (maybe synced in background?), add it?
                // Usually we only care about queue itms.
                print("Received file for episode not in queue: \(id)")
            }
            
        } catch {
            print("Error moving file: \(error)")
        }
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

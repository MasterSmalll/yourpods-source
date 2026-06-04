import Foundation
import os
import CryptoKit

/// Manages episode downloads for offline listening.
///
/// Uses `URLSession` background downloads so downloads survive app backgrounding.
///
/// **Limitation: Password-protected feeds**
/// `URLSessionConfiguration.background` does not support custom request headers
/// (like `Authorization`) set at the task level. For protected feeds, downloads
/// fall back to a foreground URLSession. If the app is backgrounded during a
/// protected-feed download, it will be retried on next app launch.
@Observable
@MainActor
final class DownloadManager: NSObject {
    private let logger = Logger(subsystem: "com.yourpods", category: "DownloadManager")
    
    var activeDownloads: [String: DownloadTask] = [:]  // episodeGuid → task
    var downloadedFiles: [String: URL] = [:]  // episodeGuid → local file URL
    
    private let fileManager = FileManager.default
    private var backgroundSession: URLSession!
    
    /// Completion handler provided by the system when the app is woken for background download events.
    /// Must be called after all delegate events have been delivered.
    var backgroundSessionCompletionHandler: (() -> Void)?
    
    private var downloadsDirectory: URL {
        let paths = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("Downloads", isDirectory: true)
    }
    
    /// Manifest file mapping GUID → filename, stored alongside downloads.
    private var manifestURL: URL {
        downloadsDirectory.appendingPathComponent("_manifest.json")
    }
    
    /// In-memory manifest: episodeGuid → relative filename
    private var manifest: [String: String] = [:]
    
    override init() {
        super.init()
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourpods.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        self.backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        loadManifest()
        scanExistingDownloads()
        loadPlayedDates()
    }
    
    // MARK: - Download
    
    /// Start downloading an episode for offline listening.
    ///
    /// For protected feeds, pass `authHeaders` with the `Authorization` header.
    /// Note: Protected-feed downloads use a foreground session (background sessions
    /// don't support custom auth headers). These downloads will pause if the app
    /// is backgrounded and resume on next launch.
    func downloadEpisode(guid: String, audioUrl: String, authHeaders: [String: String]? = nil, privacyMode: Bool = false) {
        if let existing = activeDownloads[guid], existing.status != .failed {
            return
        }
        
        // P3: strip tracking/DAI prefixes before downloading
        var effectiveUrl = audioUrl
        if privacyMode {
            let result = TrackingURLStripper.strip(audioUrl)
            if result.wasModified {
                logger.info("P3: downloading with stripped URL [\(result.trackersRemoved.joined(separator: ", "))]")
            }
            effectiveUrl = result.url
        }
        
        guard let url = URL(string: effectiveUrl) else { return }
        
        let task = DownloadTask(guid: guid, url: audioUrl, progress: 0, status: .downloading)
        activeDownloads[guid] = task
        
        if let headers = authHeaders, !headers.isEmpty {
            // Protected feed: use foreground download (background sessions
            // strip custom headers). Falls back gracefully.
            logger.info("Starting foreground download for protected feed: \(guid)")
            Task {
                do {
                    var request = URLRequest(url: url)
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    let (tempUrl, _) = try await URLSession.shared.download(for: request)
                    handleDownloadCompleted(guid: guid, url: url, location: tempUrl)
                } catch {
                    activeDownloads[guid]?.status = .failed
                    logger.error("Foreground download failed for \(guid): \(error.localizedDescription)")
                }
            }
        } else {
            // Public feed: use background session for best reliability
            let downloadTask = backgroundSession.downloadTask(with: url)
            downloadTask.taskDescription = guid
            downloadTask.resume()
            logger.info("Started background download for \(guid)")
        }
    }
    
    /// Handle completed download (shared between foreground and background paths).
    private func handleDownloadCompleted(guid: String, url: URL, location: URL) {
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let safeFilename = "\(safeFilePrefix(for: guid)).\(ext)"
        let localUrl = downloadsDirectory.appendingPathComponent(safeFilename)
        
        do {
            if fileManager.fileExists(atPath: localUrl.path) {
                try? fileManager.removeItem(at: localUrl)
            }
            try fileManager.moveItem(at: location, to: localUrl)
            
            downloadedFiles[guid] = localUrl
            manifest[guid] = safeFilename
            saveManifest()
            
            activeDownloads.removeValue(forKey: guid)
            logger.info("Completed download for \(guid) → \(safeFilename)")
        } catch {
            activeDownloads[guid]?.status = .failed
            logger.error("Failed to move downloaded file for \(guid): \(error.localizedDescription)")
        }
    }
    
    func deleteDownload(guid: String) {
        if let url = downloadedFiles[guid] {
            try? fileManager.removeItem(at: url)
            downloadedFiles.removeValue(forKey: guid)
            manifest.removeValue(forKey: guid)
            saveManifest()
        }
    }
    
    func isDownloaded(_ guid: String) -> Bool {
        downloadedFiles[guid] != nil
    }
    
    func localUrl(for guid: String) -> URL? {
        downloadedFiles[guid]
    }
    
    // MARK: - Filename Safety
    
    /// Convert a GUID (which may be a URL or contain filesystem-unsafe chars)
    /// to a safe, fixed-length filename prefix using SHA256.
    private func safeFilePrefix(for guid: String) -> String {
        let hash = SHA256.hash(data: Data(guid.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Manifest Persistence
    
    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        manifest = decoded
    }
    
    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
    
    // MARK: - Scan
    
    private func scanExistingDownloads() {
        // 1. Rebuild downloadedFiles from manifest entries that still exist on disk
        for (guid, filename) in manifest {
            let url = downloadsDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) {
                downloadedFiles[guid] = url
            } else {
                // File was deleted externally — remove from manifest
                manifest.removeValue(forKey: guid)
            }
        }
        
        // 2. Pick up legacy files not in the manifest (pre-manifest downloads).
        //    These use the raw guid as the filename, which only works for
        //    filesystem-safe guids (e.g. UUIDs).
        guard let files = try? fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }
        
        let manifestFilenames = Set(manifest.values)
        for file in files {
            let filename = file.lastPathComponent
            // Skip manifest file and files already tracked
            if filename == "_manifest.json" || manifestFilenames.contains(filename) {
                continue
            }
            // Legacy file: guid was used directly as filename
            let guid = file.deletingPathExtension().lastPathComponent
            if downloadedFiles[guid] == nil {
                downloadedFiles[guid] = file
                manifest[guid] = filename
            }
        }
        
        // Save any newly discovered legacy mappings
        saveManifest()
    }
    
    // MARK: - Played Date Tracking (for time-based cleanup)
    
    /// Dates when episodes were marked as played, for time-based cleanup.
    /// episodeGuid → date played
    var playedDates: [String: Date] = [:]
    
    private var playedDatesURL: URL {
        downloadsDirectory.appendingPathComponent("_played_dates.json")
    }
    
    /// Record that a downloaded episode has been played (for time-based cleanup).
    func markPlayed(guid: String) {
        guard downloadedFiles[guid] != nil else { return }
        playedDates[guid] = Date()
        savePlayedDates()
        logger.info("Marked played date for download: \(guid)")
    }
    
    /// Delete downloads whose played date exceeds the retention period.
    /// - Parameters:
    ///   - globalPolicy: The global default cleanup policy.
    ///   - podcastPolicies: Per-podcast policy overrides, keyed by episode guid.
    func cleanupExpiredDownloads(globalPolicy: DownloadCleanupPolicy, podcastPolicies: [String: DownloadCleanupPolicy]) {
        let now = Date()
        var cleaned = 0
        
        for (guid, playedDate) in playedDates {
            guard downloadedFiles[guid] != nil else {
                // Download was already removed — clean up stale entry
                playedDates.removeValue(forKey: guid)
                continue
            }
            
            let policy = podcastPolicies[guid] ?? globalPolicy
            let shouldDelete: Bool
            
            switch policy {
            case .oncePlayed:
                shouldDelete = true // Should have been deleted immediately, clean up
            case .afterOneWeek:
                shouldDelete = now.timeIntervalSince(playedDate) >= 7 * 24 * 3600
            case .afterOneMonth:
                shouldDelete = now.timeIntervalSince(playedDate) >= 30 * 24 * 3600
            case .never:
                shouldDelete = false
            }
            
            if shouldDelete {
                deleteDownload(guid: guid)
                playedDates.removeValue(forKey: guid)
                cleaned += 1
            }
        }
        
        if cleaned > 0 {
            savePlayedDates()
            logger.info("Cleaned up \(cleaned) expired downloads")
        }
    }
    
    private func loadPlayedDates() {
        guard let data = try? Data(contentsOf: playedDatesURL),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }
        playedDates = decoded
    }
    
    private func savePlayedDates() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(playedDates) else { return }
        try? data.write(to: playedDatesURL, options: .atomic)
    }
    
    // MARK: - Bulk Operations
    
    /// Delete all downloaded episodes.
    func deleteAllDownloads() {
        for (guid, url) in downloadedFiles {
            try? fileManager.removeItem(at: url)
            logger.info("Deleted download: \(guid)")
        }
        downloadedFiles.removeAll()
        manifest.removeAll()
        saveManifest()
    }
    
    /// Delete all downloads whose GUID matches any of the provided set.
    func deleteDownloads(guids: Set<String>) {
        for guid in guids {
            deleteDownload(guid: guid)
        }
    }
    
    /// File size in bytes for a downloaded episode, or 0 if not downloaded.
    func fileSize(for guid: String) -> Int64 {
        guard let url = downloadedFiles[guid],
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
    
    /// Total size of all downloads in bytes.
    var totalDownloadSize: Int64 {
        downloadedFiles.keys.reduce(0) { $0 + fileSize(for: $1) }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let guid = downloadTask.taskDescription,
                  let originalUrl = downloadTask.originalRequest?.url else { return }
            handleDownloadCompleted(guid: guid, url: originalUrl, location: location)
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let guid = downloadTask.taskDescription else { return }
            if totalBytesExpectedToWrite > 0 {
                let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                activeDownloads[guid]?.progress = progress
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let guid = task.taskDescription else { return }
            if let error {
                activeDownloads[guid]?.status = .failed
                logger.error("Background download failed for \(guid): \(error.localizedDescription)")
            }
        }
    }
    
    /// Called when all background session delegate messages have been delivered.
    /// Must call the system completion handler to let iOS know we're done.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            logger.info("Background session finished delivering events")
            backgroundSessionCompletionHandler?()
            backgroundSessionCompletionHandler = nil
        }
    }
}

// MARK: - Download Task

struct DownloadTask: Identifiable {
    let id = UUID()
    let guid: String
    let url: String
    var progress: Double
    var status: DownloadStatus
}

enum DownloadStatus {
    case downloading, completed, failed, paused
}

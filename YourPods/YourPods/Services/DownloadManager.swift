import Foundation
import os
import CryptoKit

/// Manages episode downloads for offline listening.
@Observable
@MainActor
final class DownloadManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "DownloadManager")
    
    var activeDownloads: [String: DownloadTask] = [:]  // episodeGuid → task
    var downloadedFiles: [String: URL] = [:]  // episodeGuid → local file URL
    
    private let fileManager = FileManager.default
    
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
    
    init() {
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        loadManifest()
        scanExistingDownloads()
    }
    
    // MARK: - Download
    
    func downloadEpisode(guid: String, audioUrl: String) async throws {
        guard activeDownloads[guid] == nil else { return }
        guard let url = URL(string: audioUrl) else { return }
        
        let task = DownloadTask(guid: guid, url: audioUrl, progress: 0, status: .downloading)
        activeDownloads[guid] = task
        
        do {
            let (tempUrl, _) = try await URLSession.shared.download(from: url)
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let safeFilename = "\(safeFilePrefix(for: guid)).\(ext)"
            let localUrl = downloadsDirectory.appendingPathComponent(safeFilename)
            
            if fileManager.fileExists(atPath: localUrl.path) {
                try? fileManager.removeItem(at: localUrl)
            }
            try fileManager.moveItem(at: tempUrl, to: localUrl)
            
            downloadedFiles[guid] = localUrl
            manifest[guid] = safeFilename
            saveManifest()
            
            activeDownloads[guid]?.status = .completed
            activeDownloads.removeValue(forKey: guid)
            
            logger.info("Downloaded episode \(guid) → \(safeFilename)")
        } catch {
            activeDownloads[guid]?.status = .failed
            logger.error("Download failed for \(guid): \(error.localizedDescription)")
            throw error
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

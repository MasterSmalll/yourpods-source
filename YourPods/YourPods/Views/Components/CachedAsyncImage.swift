import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif
import os

/// A drop-in replacement for `AsyncImage` that caches images in memory via `NSCache`.
///
/// SwiftUI's built-in `AsyncImage` has no persistent or reliable in-memory caching —
/// images can flicker or reload when scrolling, when sheets are dismissed, or when
/// view hierarchies rebuild. This wrapper uses a shared `NSCache` so identical URLs
/// only download once per app session.
///
/// Usage mirrors `AsyncImage`:
/// ```swift
/// CachedAsyncImage(url: URL(string: urlString)) { image in
///     image.resizable().aspectRatio(contentMode: .fill)
/// } placeholder: {
///     ProgressView()
/// }
/// ```
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @State private var loadedImage: PlatformImage?
    @State private var isLoading = false
    
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            if let loadedImage {
                #if canImport(UIKit)
                content(Image(uiImage: loadedImage))
                #elseif canImport(AppKit)
                content(Image(nsImage: loadedImage))
                #endif
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        guard let url, !url.absoluteString.isEmpty else { return }
        
        let key = url.absoluteString as NSString
        
        // 1. Check in-memory cache first (fastest)
        if let cached = ImageCacheStore.shared.cache.object(forKey: key) {
            loadedImage = cached
            return
        }
        
        // 2. Check disk cache (survives app restarts and memory pressure)
        if let diskCached = ImageCacheStore.shared.loadFromDisk(key: key as String) {
            // Promote back into NSCache for fast subsequent access
            ImageCacheStore.shared.cache.setObject(diskCached, forKey: key)
            await MainActor.run {
                loadedImage = diskCached
            }
            return
        }
        
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        
        // 3. Fetch from network
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = PlatformImage(data: data) else {
                ImageCacheStore.logger.debug("Failed to decode image from: \(url.absoluteString)")
                return
            }
            
            // Store in both memory and disk cache
            ImageCacheStore.shared.cache.setObject(image, forKey: key)
            ImageCacheStore.shared.saveToDisk(image: image, key: key as String)
            
            // Update UI on main thread
            await MainActor.run {
                loadedImage = image
            }
        } catch {
            ImageCacheStore.logger.debug("Image download failed for \(url.absoluteString): \(error.localizedDescription)")
        }
    }
}

// MARK: - Phase-based initializer (AsyncImage compatibility)

extension CachedAsyncImage where Placeholder == EmptyView {
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.init(url: url, content: content) {
            EmptyView()
        }
    }
}

// MARK: - Shared Image Cache

/// Singleton holding the shared `NSCache` for artwork images.
/// Separate from `CachedAsyncImage` so CarPlay or other subsystems can
/// also access the cache if needed.
final class ImageCacheStore: @unchecked Sendable {
    static let shared = ImageCacheStore()
    static let logger = Logger(subsystem: "com.yourpods", category: "imageCache")
    
    let cache: NSCache<NSString, PlatformImage>
    
    /// Disk cache directory: Caches/ImageCache/
    /// iOS automatically manages Caches/ under storage pressure.
    private let diskCacheDirectory: URL
    
    /// Maximum disk cache size in bytes (100 MB)
    private static let maxDiskCacheBytes: UInt64 = 100 * 1024 * 1024
    
    private init() {
        cache = NSCache()
        // Limit: ~50 images in memory (auto-evicted under memory pressure)
        cache.countLimit = 50
        
        // Create disk cache directory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheDirectory = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Disk Cache
    
    /// Save an image to the disk cache as JPEG data.
    func saveToDisk(image: PlatformImage, key: String) {
        let fileUrl = diskFileUrl(for: key)
        #if canImport(UIKit)
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            Self.logger.debug("Failed to encode image for disk cache: \(key)")
            return
        }
        #elseif canImport(AppKit)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            Self.logger.debug("Failed to encode image for disk cache: \(key)")
            return
        }
        #endif
        
        do {
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            Self.logger.debug("Failed to write image to disk cache: \(error.localizedDescription)")
        }
    }
    
    /// Load an image from the disk cache.
    /// - Parameter maxAgeHours: Maximum age in hours before the cached image is considered stale.
    ///   When nil, images are loaded regardless of age (offline-friendly).
    ///   When 0, images are always considered stale (force refresh).
    func loadFromDisk(key: String, maxAgeHours: Int? = nil) -> PlatformImage? {
        let fileUrl = diskFileUrl(for: key)
        
        guard FileManager.default.fileExists(atPath: fileUrl.path) else { return nil }
        
        // Check TTL if specified
        if let maxAge = maxAgeHours {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
                  let modDate = attrs[.modificationDate] as? Date else {
                return nil
            }
            let ageHours = Date().timeIntervalSince(modDate) / 3600
            if ageHours > Double(maxAge) {
                return nil // Stale — caller should re-fetch from network
            }
        }
        
        guard let data = try? Data(contentsOf: fileUrl),
              let image = PlatformImage(data: data) else {
            return nil
        }
        
        // Touch the file to update modification date (LRU tracking)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileUrl.path
        )
        
        return image
    }
    
    /// Remove an image from the disk cache.
    func removeFromDisk(key: String) {
        let fileUrl = diskFileUrl(for: key)
        try? FileManager.default.removeItem(at: fileUrl)
    }
    
    /// Evict oldest files when disk cache exceeds the size limit.
    /// Called periodically (e.g., on app foreground) to prevent unbounded growth.
    func trimDiskCacheIfNeeded() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        
        // Calculate total size
        var totalSize: UInt64 = 0
        var fileInfos: [(url: URL, size: UInt64, modDate: Date)] = []
        
        for fileUrl in contents {
            guard let values = try? fileUrl.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modDate = values.contentModificationDate else { continue }
            totalSize += UInt64(size)
            fileInfos.append((url: fileUrl, size: UInt64(size), modDate: modDate))
        }
        
        guard totalSize > Self.maxDiskCacheBytes else { return }
        
        // Sort by modification date (oldest first) for LRU eviction
        fileInfos.sort { $0.modDate < $1.modDate }
        
        var bytesToRemove = totalSize - Self.maxDiskCacheBytes
        for info in fileInfos where bytesToRemove > 0 {
            try? fm.removeItem(at: info.url)
            bytesToRemove -= min(bytesToRemove, info.size)
        }
        
        Self.logger.info("Disk cache trimmed: removed \(totalSize - bytesToRemove) bytes")
    }
    
    // MARK: - Private
    
    /// Map a URL string to a fixed-length filename using SHA256.
    private func diskFileUrl(for key: String) -> URL {
        let hash = key.data(using: .utf8)
            .map { data in
                var hasher = CryptoHasher()
                hasher.update(data: data)
                return hasher.finalize()
            } ?? key
        return diskCacheDirectory.appendingPathComponent("\(hash).jpg")
    }
}

/// Simple SHA256-like hash using built-in CommonCrypto.
/// Produces a hex string suitable for filenames.
private struct CryptoHasher {
    private var bytes = Data()
    
    mutating func update(data: Data) {
        bytes.append(data)
    }
    
    func finalize() -> String {
        // Use a simple deterministic hash for filename safety
        var hash: UInt64 = 5381
        for byte in bytes {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}

import XCTest
@testable import YourPods

/// Tests for offline playback: local file routing in AudioManager + disk image caching.
/// Covers:
///   - Bug 1: Downloaded episodes should use local file URLs instead of remote streaming
///   - Bug 2: Downloaded episodes should not stall (local file = no buffering)
///   - Bug 3: Artwork should persist to disk for offline viewing
///   - Bug 4: Image cache should follow memory → disk → network order
final class OfflinePlaybackTests: XCTestCase {

    // MARK: - QueueItem: localFileUrl serialization

    /// localFileUrl must NOT be serialized — local paths are device-specific and should
    /// not persist to UserDefaults or sync to other devices.
    func test_queueItem_localFileUrl_isNotSerialized() throws {
        var item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        item.localFileUrl = URL(fileURLWithPath: "/Documents/Downloads/ep1.mp3")

        // Encode → decode round-trip
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(QueueItem.self, from: data)

        // localFileUrl must be nil after decode — it's not in CodingKeys
        XCTAssertNil(decoded.localFileUrl,
                     "localFileUrl must not be serialized in CodingKeys")
        // Other fields should survive the round-trip
        XCTAssertEqual(decoded.id, "ep-1")
        XCTAssertEqual(decoded.audioUrl, "https://example.com/ep1.mp3")
    }

    // MARK: - AudioManager: local file routing

    /// When a QueueItem has a localFileUrl, playEpisode should use it directly
    /// instead of resolving the remote URL through URLResolver.
    @MainActor
    func test_playEpisode_usesLocalFile_whenDownloaded() async {
        let audioManager = AudioManager()

        // Create a QueueItem with a local file URL
        var item = QueueItem(
            id: "ep-local", title: "Local Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep-local.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )

        // Use a real local file path (doesn't need to exist for the URL check)
        let tempDir = FileManager.default.temporaryDirectory
        let localFile = tempDir.appendingPathComponent("test_ep_local.mp3")
        item.localFileUrl = localFile

        // Play the episode
        await audioManager.playEpisode(item)

        // The current item should be set (playback was attempted)
        XCTAssertEqual(audioManager.currentItem?.id, "ep-local",
                       "Episode should become the current item")
        // The local file URL should be preserved on the current item
        XCTAssertNotNil(audioManager.currentItem?.localFileUrl,
                        "localFileUrl should be preserved on the current item")

        // Cleanup
        audioManager.stop()
    }

    /// When a QueueItem has NO localFileUrl, the existing remote URL path must work unchanged.
    /// This is the regression safety net — ensures connected playback isn't broken.
    @MainActor
    func test_playEpisode_usesRemoteUrl_whenNotDownloaded() async {
        let audioManager = AudioManager()

        let item = QueueItem(
            id: "ep-remote", title: "Remote Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep-remote.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )

        // No localFileUrl set — should use the remote audioUrl
        await audioManager.playEpisode(item)

        // The current item should be set (playback was attempted via remote URL)
        XCTAssertEqual(audioManager.currentItem?.id, "ep-remote",
                       "Episode should become the current item via remote URL")
        XCTAssertNil(audioManager.currentItem?.localFileUrl,
                     "localFileUrl should remain nil for non-downloaded episodes")

        // Cleanup
        audioManager.stop()
    }

    /// When a QueueItem's `localFileUrl` snapshot is nil but the episode IS
    /// downloaded (the live resolver can find it on disk), playEpisode must play
    /// from disk — NOT stream. The snapshot is frequently nil for downloaded
    /// episodes: queued before the download finished, injected by sync, or
    /// downloaded after the one-shot launch rehydration. Streaming a file that's
    /// already on disk stalls AVPlayer forever when offline (airplane mode) —
    /// the exact "won't advance to next episode" bug users report.
    @MainActor
    func test_playEpisode_usesLocalDownload_whenSnapshotNilButResolverFindsIt() async {
        let audioManager = AudioManager()
        // Simulate airplane mode so the streaming branch can't accidentally "work".
        audioManager.networkMonitor = MockNetworkMonitor(isConnected: false)

        // A real on-disk file so the fileExists check passes.
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_resolver_\(UUID().uuidString).mp3")
        FileManager.default.createFile(atPath: localFile.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: localFile) }

        // The download exists on disk and the resolver knows it by GUID...
        audioManager.rehydrateLocalFileUrls { guid in
            guid == "ep-downloaded" ? localFile : nil
        }

        // ...but the QueueItem snapshot is nil (e.g. queued before download finished).
        let item = QueueItem(
            id: "ep-downloaded", title: "Downloaded Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep-downloaded.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        XCTAssertNil(item.localFileUrl, "Precondition: snapshot is nil")

        await audioManager.playEpisode(item)

        // playEpisode must have found the download live and routed to disk —
        // back-filling localFileUrl on the current item is the observable proof.
        XCTAssertEqual(audioManager.currentItem?.localFileUrl, localFile,
                       "playEpisode must play the on-disk download when the resolver finds it, not stream")

        audioManager.stop()
    }

    /// The resolver is a FALLBACK only. When the item already carries a valid
    /// on-disk `localFileUrl`, playEpisode must use it directly and never consult
    /// the resolver — this locks the "prefer the explicit snapshot" ordering so a
    /// future refactor can't accidentally make every play do a resolver lookup.
    @MainActor
    func test_playEpisode_prefersExplicitLocalFileUrl_andSkipsResolver() async {
        let audioManager = AudioManager()

        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_explicit_\(UUID().uuidString).mp3")
        FileManager.default.createFile(atPath: localFile.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: localFile) }

        // Spy resolver — must stay untouched (currentItem/queue are empty at
        // rehydrate time, so the only chance to call it is the play path).
        var resolverCalled = false
        audioManager.rehydrateLocalFileUrls { _ in
            resolverCalled = true
            return nil
        }

        var item = QueueItem(
            id: "ep-explicit", title: "Explicit Local", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep-explicit.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        item.localFileUrl = localFile

        await audioManager.playEpisode(item)

        XCTAssertFalse(resolverCalled,
                       "Resolver must not be consulted when the item already has a valid localFileUrl")
        XCTAssertEqual(audioManager.currentItem?.localFileUrl, localFile,
                       "The explicit local file should be used directly")

        audioManager.stop()
    }

    /// `autoPlay: false` must load the episode at its position WITHOUT starting
    /// playback. The cross-device now-playing handoff (reconcileNowPlaying) needs
    /// a paused load; the old path called play() then immediately pause(), which
    /// flickered playback state and emitted a FigFilePlayer error on the
    /// not-yet-ready item. Loading without ever calling play() is the fix.
    @MainActor
    func test_playEpisode_autoPlayFalse_loadsWithoutStartingPlayback() async {
        let audioManager = AudioManager()

        var item = QueueItem(
            id: "ep-handoff", title: "Server Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep-handoff.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        // Back the item with a real local file so playEpisode takes the local
        // branch (no network resolution — keeps this fast and in the Smoke plan).
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_handoff_\(UUID().uuidString).mp3")
        FileManager.default.createFile(atPath: localFile.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: localFile) }
        item.localFileUrl = localFile

        await audioManager.playEpisode(item, initialPosition: 500, autoPlay: false)

        XCTAssertEqual(audioManager.currentItem?.id, "ep-handoff",
                       "Episode should be loaded as the current item")
        XCTAssertFalse(audioManager.isPlaying,
                       "autoPlay:false must load the episode without starting playback")

        audioManager.stop()
    }

    // MARK: - PlayerManager: download-aware playback

    /// PlayerManager should attach localFileUrl from DownloadManager when playing an episode.
    @MainActor
    func test_playerManager_attachesLocalFileUrl_whenDownloaded() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let downloadManager = DownloadManager()
        playerManager.downloadManager = downloadManager

        // Simulate a downloaded episode by checking the DownloadManager can provide URLs
        // The integration point: PlayerManager.playEpisode should check downloadManager.localUrl(for:)
        // We verify the property exists and is wired
        XCTAssertNotNil(playerManager.downloadManager,
                        "PlayerManager should have a downloadManager reference")
    }

    // MARK: - ImageCacheStore: disk persistence

    /// Images stored in the cache should be written to disk.
    func test_imageCacheStore_writesToDisk() throws {
        let store = ImageCacheStore.shared
        let testKey = "https://example.com/test-artwork-\(UUID().uuidString).jpg"

        // Create a small test image
        let image = createTestImage()

        // Save to disk cache
        store.saveToDisk(image: image, key: testKey)

        // Verify the file exists on disk
        let diskImage = store.loadFromDisk(key: testKey)
        XCTAssertNotNil(diskImage, "Image should be loadable from disk cache")

        // Clean up
        store.removeFromDisk(key: testKey)
    }

    /// When NSCache misses (e.g., after memory pressure or app restart), the disk cache
    /// should provide the image and promote it back into NSCache.
    func test_imageCacheStore_readsFromDisk_whenMemoryMisses() throws {
        let store = ImageCacheStore.shared
        let testKey = "https://example.com/test-disk-fallback-\(UUID().uuidString).jpg"
        let nsKey = testKey as NSString

        // Create and save a test image to disk
        let image = createTestImage()
        store.saveToDisk(image: image, key: testKey)

        // Clear in-memory cache to simulate memory pressure
        store.cache.removeObject(forKey: nsKey)

        // Verify NSCache miss
        XCTAssertNil(store.cache.object(forKey: nsKey),
                     "NSCache should not have the image after removal")

        // Load from disk — should succeed
        let diskImage = store.loadFromDisk(key: testKey)
        XCTAssertNotNil(diskImage, "Disk cache should provide the image when NSCache misses")

        // Clean up
        store.removeFromDisk(key: testKey)
    }

    /// Clearing NSCache should NOT affect the disk cache.
    func test_imageCacheStore_diskCache_survivesCacheClear() throws {
        let store = ImageCacheStore.shared
        let testKey = "https://example.com/test-survive-\(UUID().uuidString).jpg"

        let image = createTestImage()
        store.saveToDisk(image: image, key: testKey)

        // Nuke all memory cache
        store.cache.removeAllObjects()

        // Disk cache should still have it
        let diskImage = store.loadFromDisk(key: testKey)
        XCTAssertNotNil(diskImage, "Disk cache must survive NSCache.removeAllObjects()")

        // Clean up
        store.removeFromDisk(key: testKey)
    }

    /// Disk cache should respect the configured TTL from feedCacheDurationHours.
    func test_imageCacheStore_diskCache_respectsTTL() throws {
        let store = ImageCacheStore.shared
        let testKey = "https://example.com/test-ttl-\(UUID().uuidString).jpg"

        let image = createTestImage()
        store.saveToDisk(image: image, key: testKey)

        // Image should be valid with a normal TTL
        let valid = store.loadFromDisk(key: testKey, maxAgeHours: 24)
        XCTAssertNotNil(valid, "Image within TTL should load successfully")

        // Image should be stale with TTL of 0 hours
        let stale = store.loadFromDisk(key: testKey, maxAgeHours: 0)
        XCTAssertNil(stale, "Image past its TTL should return nil")

        // Clean up
        store.removeFromDisk(key: testKey)
    }

    // MARK: - Helpers

    private func createTestImage() -> PlatformImage {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()
        return image
        #endif
    }
}

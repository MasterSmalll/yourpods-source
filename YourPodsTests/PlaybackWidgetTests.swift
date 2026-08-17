import XCTest
import UIKit
@testable import YourPods

/// TDD tests for the Home Screen playback widget data pipeline.
///
/// These tests verify that `LiveActivityService.updateWidgetData` correctly
/// writes playback state and Up Next queue to `ComplicationDataStore`,
/// and that `clearWidgetData` resets to empty state.
final class PlaybackWidgetTests: XCTestCase {
    
    private var service: LiveActivityService!
    private var store: ComplicationDataStore!
    private var testDefaults: UserDefaults!
    
    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "PlaybackWidgetTests")
        testDefaults.removePersistentDomain(forName: "PlaybackWidgetTests")
        store = ComplicationDataStore(defaults: testDefaults)
    }
    
    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "PlaybackWidgetTests")
        super.tearDown()
    }
    
    // MARK: - Test 1: updateWidgetData writes now-playing state
    
    func test_updateWidgetData_writesNowPlayingToStore() {
        // Given
        let service = LiveActivityService.shared
        
        // When
        service.updateWidgetData(
            episodeTitle: "The State of AI",
            podcastName: "Lex Fridman Podcast",
            artworkPath: "/tmp/art.jpg",
            isPlaying: true,
            positionSeconds: 1234,
            durationSeconds: 5400,
            upNextItems: []
        )
        
        // Then — read from the REAL shared store
        let data = ComplicationDataStore.shared.read()
        XCTAssertEqual(data.nowPlayingTitle, "The State of AI")
        XCTAssertEqual(data.nowPlayingPodcast, "Lex Fridman Podcast")
        XCTAssertEqual(data.artworkPath, "/tmp/art.jpg")
        XCTAssertTrue(data.isPlaying)
        XCTAssertEqual(data.positionSeconds, 1234)
        XCTAssertEqual(data.durationSeconds, 5400)
    }
    
    // MARK: - Test 2: updateWidgetData writes Up Next queue
    
    func test_updateWidgetData_writesUpNextQueue() {
        // Given
        let service = LiveActivityService.shared
        let queue: [(title: String, podcastTitle: String, artworkPath: String?, artworkUrl: String?, episodeId: String?)] = [
            (title: "Episode 42", podcastTitle: "No Agenda", artworkPath: nil, artworkUrl: nil, episodeId: nil),
            (title: "Building in Public", podcastTitle: "Indie Hackers", artworkPath: "/tmp/indie.jpg", artworkUrl: nil, episodeId: nil),
            (title: "Deep Work", podcastTitle: "Cal Newport", artworkPath: nil, artworkUrl: nil, episodeId: nil),
        ]
        
        // When
        service.updateWidgetData(
            episodeTitle: "Current Episode",
            podcastName: "Current Podcast",
            artworkPath: nil,
            isPlaying: false,
            positionSeconds: 0,
            durationSeconds: 3600,
            upNextItems: queue
        )
        
        // Then
        let data = ComplicationDataStore.shared.read()
        XCTAssertEqual(data.upNextItems.count, 3)
        XCTAssertEqual(data.upNextItems[0].title, "Episode 42")
        XCTAssertEqual(data.upNextItems[0].podcastTitle, "No Agenda")
        XCTAssertEqual(data.upNextItems[1].artworkPath, "/tmp/indie.jpg")
        XCTAssertEqual(data.upNextItems[2].title, "Deep Work")
    }
    
    // MARK: - Test 3: clearWidgetData resets to empty
    
    func test_clearWidgetData_resetsToEmptyState() {
        // Given — write some data first
        let service = LiveActivityService.shared
        service.updateWidgetData(
            episodeTitle: "Some Episode",
            podcastName: "Some Podcast",
            artworkPath: nil,
            isPlaying: true,
            positionSeconds: 500,
            durationSeconds: 3000,
            upNextItems: [(title: "Next", podcastTitle: "Pod", artworkPath: nil, artworkUrl: nil, episodeId: nil)]
        )
        
        // Precondition: verify data was actually written
        let preCheck = ComplicationDataStore.shared.read()
        XCTAssertEqual(preCheck.nowPlayingTitle, "Some Episode", "Precondition: data should be written before clearing")
        
        // When
        service.clearWidgetData()
        
        // Then
        let data = ComplicationDataStore.shared.read()
        XCTAssertNil(data.nowPlayingTitle)
        XCTAssertNil(data.nowPlayingPodcast)
        XCTAssertFalse(data.isPlaying)
        XCTAssertEqual(data.positionSeconds, 0)
        XCTAssertEqual(data.durationSeconds, 0)
        XCTAssertTrue(data.upNextItems.isEmpty)
    }
    
    // MARK: - Per-episode artwork (Home Screen widget stale-artwork regression)

    private func widgetArtContainer() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: LiveActivityService.appGroupId)
    }

    private func removeAllWidgetArt() {
        guard let dir = widgetArtContainer(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("widget_art") && name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func seedCache(url: String) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        ImageCacheStore.shared.cache.setObject(image, forKey: url as NSString)
    }

    func test_updateWidgetData_writesPerEpisodeArtworkPath_fromCache_REGRESSION() throws {
        guard widgetArtContainer() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        removeAllWidgetArt()
        defer { removeAllWidgetArt() }

        // GIVEN: the now-playing image for this episode is already in the cache
        // (Fix 2's loadImage populates it just before the widget update).
        let url = "https://example.com/ep-cache-1.jpg"
        seedCache(url: url)

        // WHEN: the widget data is pushed with an episode id and remote URL
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Cached Episode",
            podcastName: "Pod",
            artworkPath: nil,
            artworkUrl: url,
            episodeId: "ep-cache-1",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 3600,
            upNextItems: []
        )

        // THEN: a per-episode artwork file is written synchronously (no network)
        // and its path is stored — so the widget re-decodes a fresh, correct image.
        let stored = ComplicationDataStore.shared.read().artworkPath
        XCTAssertNotNil(stored, "Cached artwork should be resolved to a local path")
        XCTAssertTrue(stored?.hasSuffix("widget_art_ep-cache-1.jpg") == true,
                      "Artwork path should be per-episode, got: \(stored ?? "nil")")
        let path = try XCTUnwrap(stored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "Per-episode artwork file should exist")
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "Artwork file should be non-empty")
    }

    func test_updateWidgetData_doesNotReuseStalePathOnEpisodeChange_EDGE() throws {
        guard widgetArtContainer() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        removeAllWidgetArt()
        defer { removeAllWidgetArt() }

        // GIVEN: episode 1 artwork resolved from cache
        let url1 = "https://example.com/ep-stale-1.jpg"
        seedCache(url: url1)
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Ep1", podcastName: "Pod", artworkPath: nil, artworkUrl: url1,
            episodeId: "ep-stale-1", isPlaying: true, positionSeconds: 0, durationSeconds: 100,
            upNextItems: [])
        let firstPath = ComplicationDataStore.shared.read().artworkPath
        XCTAssertTrue(firstPath?.hasSuffix("widget_art_ep-stale-1.jpg") == true,
                      "Precondition: ep1 path should be set")

        // WHEN: episode 2 changes with an UNCACHED url (cache miss, network async)
        let url2 = "https://example.com/ep-stale-2-uncached.jpg"
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Ep2", podcastName: "Pod", artworkPath: nil, artworkUrl: url2,
            episodeId: "ep-stale-2", isPlaying: true, positionSeconds: 0, durationSeconds: 100,
            upNextItems: [])

        // THEN: the stored path must NOT still be episode 1's artwork — the old
        // fixed-file fallback (which kept showing the previous image) is gone.
        let secondPath = ComplicationDataStore.shared.read().artworkPath
        XCTAssertNotEqual(secondPath, firstPath,
                          "Episode change must not keep reusing the previous episode's artwork path")
    }

    func test_updateWidgetData_skipsArtworkReencode_whenEpisodeUnchanged() throws {
        guard widgetArtContainer() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        removeAllWidgetArt()
        defer { removeAllWidgetArt() }

        let url = "https://example.com/ep-memo-1.jpg"
        seedCache(url: url)
        let call: () -> Void = {
            LiveActivityService.shared.updateWidgetData(
                episodeTitle: "Memo", podcastName: "Pod", artworkPath: nil, artworkUrl: url,
                episodeId: "ep-memo-1", isPlaying: true, positionSeconds: 0, durationSeconds: 100,
                upNextItems: [])
        }
        call()
        let path = try XCTUnwrap(ComplicationDataStore.shared.read().artworkPath)
        let firstModified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)

        // WHEN: the same episode is pushed again (e.g. the 5s progress tick)
        call()

        // THEN: the artwork file is NOT re-encoded/rewritten (mtime unchanged).
        let secondModified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        XCTAssertEqual(firstModified, secondModified,
                       "Artwork must not be re-encoded when the episode is unchanged")
    }

    // MARK: - Test 4: ComplicationData backward compatibility
    
    func test_complicationData_decodesWithoutNewFields() {
        // Given — encode data with only the old fields (simulating watchOS data)
        let oldStyleJSON = """
        {
            "isPlaying": true,
            "nowPlayingTitle": "Old Episode",
            "nowPlayingPodcast": "Old Podcast",
            "queueCount": 2,
            "lastUpdated": 0
        }
        """.data(using: .utf8)!
        
        // When
        let decoded = try? JSONDecoder().decode(ComplicationData.self, from: oldStyleJSON)
        
        // Then — new fields have defaults
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.nowPlayingTitle, "Old Episode")
        XCTAssertNil(decoded?.artworkPath)
        XCTAssertEqual(decoded?.positionSeconds, 0)
        XCTAssertEqual(decoded?.durationSeconds, 0)
        XCTAssertEqual(decoded?.upNextItems.count, 0)
    }

    // MARK: - Test 5: redundant-write change-guard (0xDEAD10CC write-amplification)

    private static let storeKey = "complication_data"

    private func makeData(
        timestamp: TimeInterval,
        position: Int = 978,
        isPlaying: Bool = false
    ) -> ComplicationData {
        ComplicationData(
            nowPlayingTitle: "Snap",
            nowPlayingPodcast: "Markets",
            isPlaying: isPlaying,
            upNextTitle: "Next",
            upNextPodcast: "P2",
            queueCount: 3,
            lastUpdated: Date(timeIntervalSince1970: timestamp),
            artworkPath: "/tmp/a.jpg",
            positionSeconds: position,
            durationSeconds: 3600,
            upNextItems: []
        )
    }

    /// A push that changes ONLY the `lastUpdated` timestamp (identical playback +
    /// queue state) must NOT hit the app-group defaults again. The widget update
    /// fires in bursts during sync / scene transitions; without this guard each
    /// identical push is a redundant suspension-straddling write to the very
    /// container that causes 0xDEAD10CC kills.
    func test_write_skipsRedundantWrite_whenOnlyTimestampDiffers() {
        store.write(makeData(timestamp: 1000))
        let afterFirst = testDefaults.data(forKey: Self.storeKey)

        // Identical material state, newer refresh stamps (the burst).
        store.write(makeData(timestamp: 2000))
        store.write(makeData(timestamp: 3000))
        let afterRedundant = testDefaults.data(forKey: Self.storeKey)

        XCTAssertNotNil(afterFirst, "First write should persist")
        XCTAssertEqual(afterFirst, afterRedundant,
            "Pushes that differ only by lastUpdated must not rewrite the app-group store")
    }

    /// The guard must not over-suppress: a genuine material change (here, an
    /// advancing playback position) still writes.
    func test_write_persistsWrite_whenMaterialFieldChanges() {
        store.write(makeData(timestamp: 1000, position: 100))
        let afterBase = testDefaults.data(forKey: Self.storeKey)

        store.write(makeData(timestamp: 2000, position: 105))
        let afterChange = testDefaults.data(forKey: Self.storeKey)

        XCTAssertNotEqual(afterBase, afterChange,
            "A real material change (position) must still be persisted")
    }

    /// `write` must REPORT whether it actually persisted, so callers can gate
    /// write-accounting (WriteInstrumentation) on real disk writes. Without this
    /// the deduped burst pushes get tallied as "widget" writes that never hit the
    /// app-group store, inflating the 0xDEAD10CC disk-write triage counts.
    func test_write_returnsTrue_whenStatePersisted() {
        XCTAssertTrue(store.write(makeData(timestamp: 1000)),
            "First write of fresh state must report it persisted")
    }

    func test_write_returnsFalse_whenRedundant() {
        XCTAssertTrue(store.write(makeData(timestamp: 1000)))
        XCTAssertFalse(store.write(makeData(timestamp: 2000)),
            "A push differing only by lastUpdated must report it did NOT write")
    }
}

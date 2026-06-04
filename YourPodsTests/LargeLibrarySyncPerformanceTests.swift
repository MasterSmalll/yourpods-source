import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for large-library sync performance fixes.
///
/// Root cause: gPodder sync with ~5000 episodes becomes unusably slow due to:
/// 1. O(N×M) nested loops for metadata lookups during conflict detection
/// 2. Per-podcast modelContext.save() calls (100 saves for 100 podcasts)
/// 3. force:true re-pulls all episode actions every sync
/// 4. actionMap stored in UserDefaults (2-3 MB JSON blob on main thread)
///
/// These tests verify the fixes: episode index, batch saves, incremental sync,
/// and file-based persistence.
@MainActor
final class LargeLibrarySyncPerformanceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-large-lib"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        cleanupActionMapFile()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        clearTestDefaults()
        cleanupActionMapFile()
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
            "lastSubscriptionSync_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func cleanupActionMapFile() {
        let url = EpisodeActionSyncService.actionMapFileURL
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast", episodeCount: Int = 3) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        for i in 0..<episodeCount {
            let ep = Episode(
                guid: "\(url)-ep-\(i)",
                title: "Episode \(i)",
                episodeDescription: nil,
                audioUrl: "https://example.com/\(url)-ep-\(i).mp3",
                pubDate: Date(),
                imageUrl: nil,
                durationSeconds: 3600,
                link: nil,
                chaptersUrl: nil,
                transcriptUrl: nil,
                podcast: podcast
            )
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - A. Episode Index (GUID → Episode O(1) Lookup)

    /// The episode index must resolve lookups by GUID in O(1) instead of O(N).
    /// This test creates a large dataset and calls lookupEpisodeMetadata —
    /// verifying that the index-based lookup returns correct results.
    func test_episodeIndex_lookupByGuid_returnsCorrectMetadata() {
        // GIVEN: 10 podcasts × 50 episodes = 500 episodes
        for i in 0..<10 {
            insertPodcast(url: "https://perf-test-\(i).com/feed", title: "Podcast \(i)", episodeCount: 50)
        }
        XCTAssertEqual(manager.subscriptions.count, 10, "Precondition: 10 podcasts")
        let totalEpisodes = manager.subscriptions.flatMap(\.episodes).count
        XCTAssertEqual(totalEpisodes, 500, "Precondition: 500 episodes")

        // Build the index
        let index = manager.episodeActionSync.buildEpisodeIndex()

        // WHEN: Looking up a specific episode by GUID
        let targetGuid = "https://perf-test-5.com/feed-ep-25"
        let result = index.byGuid[targetGuid]

        // THEN: The lookup returns the correct episode and podcast
        XCTAssertNotNil(result, "Index should find episode by GUID")
        XCTAssertEqual(result?.episode.guid, targetGuid)
        XCTAssertEqual(result?.podcast.title, "Podcast 5")
    }

    /// The episode index must resolve lookups by audioUrl as a fallback.
    func test_episodeIndex_lookupByAudioUrl_returnsCorrectMetadata() {
        // GIVEN: 10 podcasts × 50 episodes
        for i in 0..<10 {
            insertPodcast(url: "https://audio-test-\(i).com/feed", title: "Audio Podcast \(i)", episodeCount: 50)
        }

        let index = manager.episodeActionSync.buildEpisodeIndex()

        // WHEN: Looking up by audio URL
        let targetUrl = "https://example.com/https://audio-test-5.com/feed-ep-25.mp3"
        let result = index.byAudioUrl[targetUrl]

        // THEN: Correct episode found
        XCTAssertNotNil(result, "Index should find episode by audio URL")
        XCTAssertEqual(result?.podcast.title, "Audio Podcast 5")
    }

    /// Case-insensitive GUID lookup must work through the index.
    func test_episodeIndex_caseInsensitiveGuidLookup() {
        insertPodcast(url: "https://ci-test.com/feed", title: "CI Podcast", episodeCount: 5)

        let index = manager.episodeActionSync.buildEpisodeIndex()

        // GUIDs are stored as-is; the case-insensitive variant uses lowercased keys
        let targetGuid = "https://ci-test.com/feed-ep-2"
        let uppercased = targetGuid.uppercased()
        let result = index.byGuidCaseInsensitive[uppercased.lowercased()]

        XCTAssertNotNil(result, "Case-insensitive index should find episode")
        XCTAssertEqual(result?.episode.guid, targetGuid)
    }

    // MARK: - B. Batch Saves (cross-podcast batching)

    /// applyEpisodeActionsWithStats should produce fewer saves than the number of podcasts
    /// when using cross-podcast batching.
    func test_batchSaves_reducesSaveCount() async {
        // GIVEN: 20 podcasts × 50 episodes = 1000 episodes, all with action map entries
        for i in 0..<20 {
            insertPodcast(url: "https://batch-test-\(i).com/feed", title: "Batch \(i)", episodeCount: 50)
        }

        // Populate action map with positions for every episode
        var map: [String: EpisodeAction] = [:]
        for podcast in manager.subscriptions {
            for episode in podcast.episodes {
                map[episode.guid] = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: 300,
                    started: 0,
                    total: 3600,
                    device: "test"
                )
            }
        }
        manager.episodeActionSync.replaceActionMap(map)

        // WHEN: Applying episode actions
        let (_, saveCount) = await manager.episodeActionSync.applyEpisodeActionsWithStatsAsync(strategy: .serverWins)

        // THEN: Save count should be significantly less than 20 (the podcast count)
        // With batch size of 500 episodes, 1000 episodes → ~2-3 saves
        XCTAssertGreaterThan(saveCount, 0, "Should have saved at least once")
        XCTAssertLessThanOrEqual(saveCount, 5,
            "With cross-podcast batching, 1000 episodes should need ≤5 saves, got \(saveCount) (was 20 per-podcast saves before fix)")
    }

    /// Positions must still be applied correctly with batch saves.
    func test_batchSaves_positionsAppliedCorrectly() async {
        // GIVEN: 10 podcasts × 20 episodes, each with different positions
        for i in 0..<10 {
            insertPodcast(url: "https://correct-test-\(i).com/feed", title: "Correct \(i)", episodeCount: 20)
        }

        var map: [String: EpisodeAction] = [:]
        for podcast in manager.subscriptions {
            for episode in podcast.episodes {
                let position = 100 + (episode.guid.hashValue % 500).magnitude
                map[episode.guid] = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: Int(position),
                    started: 0,
                    total: 3600,
                    device: "test"
                )
            }
        }
        manager.episodeActionSync.replaceActionMap(map)

        // WHEN: Applying
        await manager.episodeActionSync.applyEpisodeActionsAsync(strategy: .serverWins)

        // THEN: Every episode has the correct position from its action map entry
        for podcast in manager.subscriptions {
            for episode in podcast.episodes {
                let expected = map[episode.guid]?.position ?? 0
                XCTAssertEqual(episode.listenedSeconds, expected,
                    "Episode \(episode.guid) should have position \(expected), got \(episode.listenedSeconds)")
            }
        }
    }

    // MARK: - C. Incremental Sync (force: false by default for gPodder)

    /// The gPodder orchestrator should pass force:false to syncEpisodeActions,
    /// resulting in incremental sync using the stored timestamp.
    func test_gPodderOrchestrator_usesIncrementalSync() async {
        // GIVEN: A podcast and a spy that records the `since` parameter
        insertPodcast(url: "https://incr-test.com/feed", title: "Incremental Test", episodeCount: 5)

        let spy = IncrementalSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // Set a previous sync timestamp
        UserDefaults.standard.set(1700000000, forKey: "lastEpisodeActionSync_\(testProfileId)")

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let orchestrator = GPodderSyncOrchestrator(client: spy)

        // WHEN: Running the orchestrator
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // THEN: getEpisodeActions should have been called with since > 0 (incremental)
        let sinceCalled = await spy.lastEpisodeActionsSince
        XCTAssertNotNil(sinceCalled, "getEpisodeActions should have been called")
        XCTAssertGreaterThan(sinceCalled ?? 0, 0,
            "gPodder orchestrator should use incremental sync (since > 0), got since=\(sinceCalled ?? 0)")
    }

    /// Force Pull from Server should still use force:true (since=0) for full resync.
    func test_forcePullFromServer_usesFullSync() async {
        insertPodcast(url: "https://force-test.com/feed", title: "Force Test", episodeCount: 3)

        let spy = IncrementalSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // Set a previous sync timestamp
        UserDefaults.standard.set(1700000000, forKey: "lastEpisodeActionSync_\(testProfileId)")

        // WHEN: Force pull
        _ = try? await manager.forcePullFromServer()

        // THEN: since=0 (full pull)
        let sinceCalled = await spy.lastEpisodeActionsSince
        XCTAssertEqual(sinceCalled, 0,
            "Force pull should use since=0 for full resync, got \(sinceCalled ?? -1)")
    }

    // MARK: - D. File-Based ActionMap Persistence

    /// actionMap should persist to a file, not UserDefaults.
    func test_actionMapFilePersistence_roundTrip() {
        // GIVEN: An action map with entries
        let action = EpisodeAction(
            podcast: "https://file-test.com/feed",
            episode: "https://file-test.com/ep1.mp3",
            guid: "file-test-ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 500,
            started: 0,
            total: 3600,
            device: "test"
        )
        manager.episodeActionSync.replaceActionMap(["file-test-ep-1": action])

        // WHEN: Creating a fresh service and loading
        let freshService = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test" }
        )
        freshService.loadActionMap()

        // THEN: The action map was loaded from file
        XCTAssertEqual(freshService.actionMap.count, 1, "Should load 1 entry from file")
        XCTAssertEqual(freshService.actionMap["file-test-ep-1"]?.position, 500)
    }

    /// On first load, if file doesn't exist but UserDefaults has data, migrate once.
    func test_actionMapFilePersistence_migratesFromUserDefaults() {
        // GIVEN: Action map data in UserDefaults (legacy location)
        let legacyAction = EpisodeAction(
            podcast: "https://migrate-test.com/feed",
            episode: "https://migrate-test.com/ep1.mp3",
            guid: "migrate-ep-1",
            action: "play",
            timestamp: 1700000000,
            position: 250,
            started: 0,
            total: 3600,
            device: "legacy"
        )
        let legacyMap: [String: EpisodeAction] = ["migrate-ep-1": legacyAction]
        let encoded = try! JSONEncoder().encode(legacyMap)
        UserDefaults.standard.set(encoded, forKey: "episodeActionMap")

        // Ensure no file exists
        cleanupActionMapFile()

        // WHEN: Loading the action map (should trigger migration)
        let freshService = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test" }
        )
        freshService.loadActionMap()

        // THEN: Data was migrated
        XCTAssertEqual(freshService.actionMap.count, 1, "Should have migrated 1 entry")
        XCTAssertEqual(freshService.actionMap["migrate-ep-1"]?.position, 250)

        // AND: The file now exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: EpisodeActionSyncService.actionMapFileURL.path),
            "Action map file should exist after migration")

        // AND: UserDefaults entry was cleaned up
        XCTAssertNil(UserDefaults.standard.data(forKey: "episodeActionMap"),
            "Legacy UserDefaults key should be removed after migration")
    }

    /// actionMapFileURL should be a static accessible property.
    func test_actionMapFileURL_isAccessible() {
        let url = EpisodeActionSyncService.actionMapFileURL
        XCTAssertTrue(url.path.hasSuffix("episodeActionMap.json"),
            "File URL should end with episodeActionMap.json, got: \(url.path)")
    }

    // MARK: - E. End-to-End Large Library Performance

    /// The full applyEpisodeActionsCore path with 5000 episodes should complete
    /// in a reasonable time. This is a smoke test for the combined optimizations.
    func test_largeLibrary_applyPerformance_completesQuickly() async {
        // GIVEN: 20 podcasts × 50 episodes = 1000 episodes
        for i in 0..<20 {
            insertPodcast(url: "https://e2e-perf-\(i).com/feed", title: "E2E \(i)", episodeCount: 50)
        }
        let totalEpisodes = manager.subscriptions.flatMap(\.episodes).count
        XCTAssertEqual(totalEpisodes, 1000, "Precondition: 1000 episodes")

        // Populate action map
        var map: [String: EpisodeAction] = [:]
        for podcast in manager.subscriptions {
            for episode in podcast.episodes {
                map[episode.guid] = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: 120,
                    started: 0,
                    total: 3600,
                    device: "test"
                )
            }
        }
        manager.episodeActionSync.replaceActionMap(map)

        // WHEN: Applying actions
        let start = CFAbsoluteTimeGetCurrent()
        let (_, saveCount) = await manager.episodeActionSync.applyEpisodeActionsWithStatsAsync(strategy: .serverWins)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // THEN: Should complete in < 5 seconds
        XCTAssertLessThan(elapsed, 5.0,
            "1000-episode apply should complete in <5s, took \(String(format: "%.2f", elapsed))s")

        // AND: Save count should be reasonable (not 20 per-podcast saves)
        XCTAssertLessThanOrEqual(saveCount, 5,
            "1000 episodes should need ≤5 batched saves, got \(saveCount)")
    }
}

// MARK: - Spy SyncClient for incremental sync testing

/// Records the `since` parameter passed to getEpisodeActions.
actor IncrementalSyncSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    private(set) var lastEpisodeActionsSince: Int?

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        lastEpisodeActionsSince = since
        return []
    }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

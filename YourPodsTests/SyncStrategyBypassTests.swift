import XCTest
import SwiftData
@testable import YourPods

/// Tests that all sync paths honor the user's conflict strategy preference.
///
/// Bug: Three code paths bypass the user's `syncConflictStrategy` setting:
/// 1. BackgroundRefreshService.performSync() hardcodes `.serverWins`
/// 2. PlayerManager.pullQueueFromProServer() unconditionally overwrites positions
/// 3. PlayerManager.syncPlaybackState() auto-seeks without checking strategy
///
/// These tests verify each path respects `.deviceWins`, `.serverWins`, and `.ask`.
@MainActor
final class SyncStrategyBypassTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private var bgService: BackgroundRefreshService!
    private let testProfileId = "test-profile-strategy"

    override func setUp() {
        super.setUp()
        clearTestDefaults()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        playerManager.settingsManager = settingsManager
        manager.downloadManager = downloadManager
        manager.settingsManager = settingsManager

        bgService = BackgroundRefreshService()
        bgService.podcastManager = manager
        bgService.audioManager = audioManager
        bgService.settingsManager = settingsManager
        bgService.downloadManager = downloadManager
        bgService.playerManager = playerManager
    }

    override func tearDown() {
        clearTestDefaults()
        bgService = nil
        downloadManager = nil
        settingsManager = nil
        playerManager = nil
        audioManager = nil
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
            "episodeActionMap",
            "syncConflictStrategy",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @discardableResult
    private func insertPodcast(
        url: String = "https://example.com/feed",
        title: String = "Test Podcast",
        episodeCount: Int = 3
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    // MARK: - Fix 1: Background sync must honor user's strategy

    /// When user sets `.deviceWins`, background sync must NOT overwrite local positions.
    func test_backgroundSync_honorsDeviceWinsStrategy() async {
        // GIVEN: User has set conflict strategy to .deviceWins
        settingsManager.syncConflictStrategy = .deviceWins

        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 200 // local position
        try! context.save()

        // Server says 400 (ahead of local)
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 400,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])

        let spy = SpySyncClientForBGFG()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Background sync runs
        await bgService.performSync()

        // THEN: Device position (200) must be preserved — NOT overwritten to 400
        XCTAssertEqual(episode.listenedSeconds, 200,
                       "Background sync must honor .deviceWins — device position must be preserved")
    }

    /// When user sets `.ask`, background sync should fall back to `.deviceWins`
    /// (can't show UI in background) and preserve local positions.
    func test_backgroundSync_askFallsBackToDeviceWins() async {
        // GIVEN: User has set conflict strategy to .ask
        settingsManager.syncConflictStrategy = .ask

        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 200
        try! context.save()

        // Server says 400
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 400,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])

        let spy = SpySyncClientForBGFG()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Background sync runs
        await bgService.performSync()

        // THEN: Local position must be preserved (can't show conflict UI in background)
        XCTAssertEqual(episode.listenedSeconds, 200,
                       "Background sync with .ask must fall back to .deviceWins — can't show UI")
    }

    /// When user sets `.serverWins`, background sync should still overwrite (existing behavior).
    func test_backgroundSync_serverWinsStillOverwrites() async {
        // GIVEN: User has set conflict strategy to .serverWins
        settingsManager.syncConflictStrategy = .serverWins

        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 200
        try! context.save()

        // Server says 400
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 400,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])

        let spy = SpySyncClientForBGFG()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Background sync runs
        await bgService.performSync()

        // THEN: Server position should be applied (serverWins is explicit)
        // Refetch: async path writes on SyncStore background context.
        // Direct Episode fetch avoids stale relationship caches.
        let guid = episode.guid
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        let refetchedEp = try! context.fetch(descriptor).first
        XCTAssertEqual(refetchedEp?.listenedSeconds, 400,
                       "Background sync with .serverWins should overwrite local with server position")
    }

    // MARK: - Fix 2: Queue pull respects strategy

    /// Queue pull with `.deviceWins` must NOT overwrite a local queue item position > 0.
    func test_queuePull_deviceWins_doesNotOverwriteLocalPosition() async {
        // GIVEN: User has set conflict strategy to .deviceWins
        settingsManager.syncConflictStrategy = .deviceWins

        // Add an item to the local queue at position 200
        let localItem = QueueItem(
            id: "ep-1",
            title: "Episode 1",
            podcastTitle: "Test",
            audioUrl: "https://example.com/ep1.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 200,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([localItem])

        // Set up spy client that returns the same episode at position 500
        let spy = SpyQueueSyncClient(
            queueItems: [
                QueueSyncItem(
                    podcastUrl: "https://example.com/feed",
                    episodeUrl: "https://example.com/ep1.mp3",
                    episodeGuid: "ep-1",
                    sortOrder: 0,
                    positionSec: 500,
                    title: "Episode 1",
                    podcastTitle: "Test",
                    durationSec: 3600
                )
            ]
        )
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Queue pull runs
        await playerManager.pullQueueFromProServer()

        // THEN: Local position (200) must be preserved
        let queueItem = audioManager.queue.first { $0.id == "ep-1" }
        XCTAssertEqual(queueItem?.positionSeconds, 200,
                       "Queue pull with .deviceWins must NOT overwrite local position (200) with server (500)")
    }

    /// Queue pull with `.serverWins` SHOULD overwrite local queue position.
    func test_queuePull_serverWins_overwritesLocalPosition() async {
        // GIVEN: User has set conflict strategy to .serverWins
        settingsManager.syncConflictStrategy = .serverWins

        let localItem = QueueItem(
            id: "ep-1",
            title: "Episode 1",
            podcastTitle: "Test",
            audioUrl: "https://example.com/ep1.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 200,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([localItem])

        let spy = SpyQueueSyncClient(
            queueItems: [
                QueueSyncItem(
                    podcastUrl: "https://example.com/feed",
                    episodeUrl: "https://example.com/ep1.mp3",
                    episodeGuid: "ep-1",
                    sortOrder: 0,
                    positionSec: 500,
                    title: "Episode 1",
                    podcastTitle: "Test",
                    durationSec: 3600
                )
            ]
        )
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Queue pull runs
        await playerManager.pullQueueFromProServer()

        // THEN: Server position (500) should be applied
        let queueItem = audioManager.queue.first { $0.id == "ep-1" }
        XCTAssertEqual(queueItem?.positionSeconds, 500,
                       "Queue pull with .serverWins should overwrite local position with server position")
    }

    /// Queue pull should always set position for NEW items (not in local queue).
    func test_queuePull_newItems_alwaysGetServerPosition() async {
        // GIVEN: Strategy is .deviceWins, local queue is empty
        settingsManager.syncConflictStrategy = .deviceWins

        let spy = SpyQueueSyncClient(
            queueItems: [
                QueueSyncItem(
                    podcastUrl: "https://example.com/feed",
                    episodeUrl: "https://example.com/ep1.mp3",
                    episodeGuid: "new-ep-1",
                    sortOrder: 0,
                    positionSec: 300,
                    title: "New Episode",
                    podcastTitle: "Test",
                    durationSec: 3600
                )
            ]
        )
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Queue pull runs
        await playerManager.pullQueueFromProServer()

        // THEN: New item gets server position regardless of strategy
        let queueItem = audioManager.queue.first { $0.id == "new-ep-1" }
        XCTAssertNotNil(queueItem, "New item should be added to queue")
        XCTAssertEqual(queueItem?.positionSeconds, 300,
                       "New queue items should always get the server position")
    }
}

// MARK: - Spy SyncClient for Queue Sync Tests

actor SpyQueueSyncClient: SyncClient {
    let queueItems: [QueueSyncItem]
    
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }

    init(queueItems: [QueueSyncItem]) {
        self.queueItems = queueItems
    }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }

    func getQueue() async throws -> [QueueSyncItem] {
        return queueItems
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
}

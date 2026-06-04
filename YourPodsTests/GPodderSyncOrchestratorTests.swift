import XCTest
import SwiftData
@testable import YourPods

/// Tests for `GPodderSyncOrchestrator` — subscriptions + RSS + episode actions.
///
/// The gPodder orchestrator must sync subscriptions and episode actions via
/// the `SyncClient` protocol, refresh RSS feeds, and run auto-queue/download.
/// It must NEVER call queue sync, settings sync, stats flush, or groups sync
/// — those are Pro-only operations.
@MainActor
final class GPodderSyncOrchestratorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-gpodder-orch"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()
        manager.downloadManager = downloadManager
        manager.settingsManager = settingsManager
    }

    override func tearDown() {
        clearTestDefaults()
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
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Positive: gPodder steps run

    /// gPodder sync must pull subscription changes from the server.
    func test_gPodder_syncsSubscriptions() async {
        let spy = GPodderOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = GPodderSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let wasCalled = await spy.pullSubscriptionsCalled
        XCTAssertTrue(wasCalled,
                      "gPodder orchestrator must sync subscriptions")
    }

    /// gPodder sync must fetch episode actions (listening positions).
    func test_gPodder_syncsEpisodeActions() async {
        let spy = GPodderOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = GPodderSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let wasCalled = await spy.getEpisodeActionsCalled
        XCTAssertTrue(wasCalled,
                      "gPodder orchestrator must sync episode actions")
    }

    // MARK: - Negative: Pro-only steps must NOT run

    /// gPodder sync must NEVER call queue sync.
    func test_gPodder_neverCallsQueueSync() async {
        let spy = GPodderOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = GPodderSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let syncQueueCalled = await spy.syncQueueCalled
        let getQueueCalled = await spy.getQueueCalled
        XCTAssertFalse(syncQueueCalled,
                       "gPodder orchestrator must NEVER call syncQueue — it's Pro-only")
        XCTAssertFalse(getQueueCalled,
                       "gPodder orchestrator must NEVER call getQueue — it's Pro-only")
    }

    /// gPodder orchestrator holds `SyncClient` protocol, not `YourPodsProClient`.
    /// This is a compile-time guarantee — if the client is a `YourPodsProClient`,
    /// someone has made a mistake.
    func test_gPodder_clientIsProtocolType() {
        let spy = GPodderOrchestratorSpy()
        let orchestrator = GPodderSyncOrchestrator(client: spy)
        // The `client` property type is `any SyncClient`, not `YourPodsProClient`.
        // This test documents that guarantee. If the client were a concrete Pro type,
        // Pro-only methods would be callable, breaking isolation.
        XCTAssertFalse(orchestrator.client is YourPodsProClient,
                       "gPodder orchestrator's client must be protocol-typed, not YourPodsProClient")
    }
}

// MARK: - Spy SyncClient for gPodder Orchestrator Tests

actor GPodderOrchestratorSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    var syncQueueCalled = false
    var getQueueCalled = false
    var getEpisodeActionsCalled = false
    var uploadEpisodeActionsCalled = false
    var pushSubscriptionsCalled = false
    var pullSubscriptionsCalled = false

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        getQueueCalled = true
        return []
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        pushSubscriptionsCalled = true
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        pullSubscriptionsCalled = true
        return SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        uploadEpisodeActionsCalled = true
        return []
    }

    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        getEpisodeActionsCalled = true
        return []
    }
}

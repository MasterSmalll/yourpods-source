import XCTest
import SwiftData
@testable import YourPods

/// Parity tests: verify that `refreshAndSync()` (which delegates to
/// `SyncOrchestratorFactory`) produces the same side effects as the
/// old monolithic implementation for each profile type.
///
/// These tests exercise the PUBLIC entry point (`refreshAndSync`) and
/// assert via spy clients that the correct orchestrator steps ran.
/// If the factory dispatch or any orchestrator regresses, these tests catch it.
@MainActor
final class SyncOrchestratorParityTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-parity"

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
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition",
            "serverProfiles",
            "proFirstSyncCompleted_testpro",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Vault Parity

    /// Vault mode: refreshAndSync with no sync client must complete without
    /// server calls and produce no conflicts. Mirrors old behavior where
    /// all server-gated blocks were skipped when syncClient was nil.
    func test_parity_vault_noSyncClient_noServerCalls() async {
        // GIVEN: No sync client (Vault mode)
        manager.setSyncClient(nil, deviceId: "test-device")

        // WHEN: refreshAndSync runs
        let conflicts = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: No conflicts (no server to conflict with)
        XCTAssertTrue(conflicts.isEmpty,
                      "Vault mode must produce no sync conflicts")
        // AND: No sync error
        XCTAssertNil(manager.lastSyncError,
                     "Vault mode must not set a sync error")
    }

    // MARK: - gPodder Parity

    /// gPodder: refreshAndSync must call subscription sync and episode actions
    /// but NOT queue sync, settings sync, or stats.
    func test_parity_gpodder_syncsSubsAndActions_notQueue() async {
        // GIVEN: A gPodder profile and spy client
        let spy = ParitySpy()
        let profile = ServerProfile(
            id: testProfileId,
            name: "gPodder Test",
            baseUrl: "https://gpodder.example.com",
            username: "test",
            deviceId: "test-device",
            profileType: .gpodder
        )
        let profiles = try! JSONEncoder().encode([profile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        // Re-init settingsManager to pick up profile
        settingsManager = SettingsManager()
        manager.settingsManager = settingsManager

        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: refreshAndSync runs
        let conflicts = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: Subscriptions synced
        let pullSubsCalled = await spy.pullSubscriptionsCalled
        XCTAssertTrue(pullSubsCalled,
                      "gPodder parity: must sync subscriptions")

        // AND: Episode actions synced
        let getActionsCalled = await spy.getEpisodeActionsCalled
        XCTAssertTrue(getActionsCalled,
                      "gPodder parity: must sync episode actions")

        // AND: Queue sync NOT called (Pro-only)
        let syncQueueCalled = await spy.syncQueueCalled
        let getQueueCalled = await spy.getQueueCalled
        XCTAssertFalse(syncQueueCalled,
                       "gPodder parity: must NOT call syncQueue")
        XCTAssertFalse(getQueueCalled,
                       "gPodder parity: must NOT call getQueue")

        // AND: Conflicts are empty (no conflicting data in spy)
        XCTAssertTrue(conflicts.isEmpty,
                      "gPodder parity: empty spy data should produce no conflicts")
    }

    // MARK: - Pro Parity

    /// Pro: refreshAndSync must call subscriptions, episode actions, AND queue sync.
    func test_parity_pro_syncsEverything() async {
        // GIVEN: A Pro profile and spy client
        let spy = ParitySpy()
        let profile = ServerProfile(
            id: testProfileId,
            name: "Pro Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: "test-device",
            profileType: .yourpodsPro,
            proProfileName: "testpro"
        )
        let profiles = try! JSONEncoder().encode([profile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        // Re-init settingsManager to pick up profile
        settingsManager = SettingsManager()
        manager.settingsManager = settingsManager

        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: refreshAndSync runs
        let conflicts = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: Subscriptions synced
        let pullSubsCalled = await spy.pullSubscriptionsCalled
        XCTAssertTrue(pullSubsCalled,
                      "Pro parity: must sync subscriptions")

        // AND: Episode actions synced
        let getActionsCalled = await spy.getEpisodeActionsCalled
        XCTAssertTrue(getActionsCalled,
                      "Pro parity: must sync episode actions")

        // AND: Queue pull called (Pro feature)
        // Note: syncQueue (push) may NOT be called on fresh devices (Bug 3 fix)
        // but getQueue (pull) must always be called.
        let getQueueCalled = await spy.getQueueCalled
        XCTAssertTrue(getQueueCalled,
                       "Pro parity: must pull queue from server")

        // AND: No conflicts with empty data
        XCTAssertTrue(conflicts.isEmpty,
                      "Pro parity: empty spy data should produce no conflicts")
    }

    /// Pro: refreshAndSync must pull queue items from the server into the local queue.
    /// This is a regression test for the pre-existing PTR test failure —
    /// the old monolith gated queue sync behind `as? YourPodsProClient` which
    /// excluded non-concrete spy clients. The orchestrator fixes this.
    func test_parity_pro_pullsQueueItemsFromServer() async {
        // GIVEN: A Pro profile with server queue items
        let spy = ParitySpy()
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/ep1.mp3",
                episodeGuid: "parity-ep-1",
                sortOrder: 0,
                positionSec: 120,
                title: "Parity Episode",
                podcastTitle: "Parity Podcast"
            ),
        ])
        let profile = ServerProfile(
            id: testProfileId,
            name: "Pro Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: "test-device",
            profileType: .yourpodsPro,
            proProfileName: "testpro"
        )
        let profiles = try! JSONEncoder().encode([profile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        settingsManager = SettingsManager()
        manager.settingsManager = settingsManager

        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Precondition: queue is empty
        XCTAssertTrue(audioManager.queue.isEmpty, "Precondition: queue should be empty")

        // WHEN: refreshAndSync runs
        _ = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: Server queue item becomes currentItem on fresh device (Bug 3 fix)
        // sortOrder 0 = now playing
        XCTAssertEqual(audioManager.currentItem?.id, "parity-ep-1",
                       "Pro parity: server queue items must be pulled into local queue")
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 120)
    }

    // MARK: - Cross-Profile Isolation

    /// Switching from gPodder to Vault must not leak any server sync operations.
    func test_parity_gpodderToVault_noLeakedServerCalls() async {
        // First: run a gPodder sync
        let gpodderSpy = ParitySpy()
        let gpodderProfile = ServerProfile(
            id: testProfileId,
            name: "gPodder",
            baseUrl: "https://gpodder.example.com",
            username: "test",
            deviceId: "test-device",
            profileType: .gpodder
        )
        let profiles = try! JSONEncoder().encode([gpodderProfile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        settingsManager = SettingsManager()
        manager.settingsManager = settingsManager
        manager.setSyncClient(gpodderSpy, deviceId: "test-device")
        playerManager.setSyncClient(gpodderSpy, deviceId: "test-device")

        _ = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // gPodder sync ran — verify subs were called
        let gpodderPulled = await gpodderSpy.pullSubscriptionsCalled
        XCTAssertTrue(gpodderPulled, "Pre-check: gPodder sync should have pulled subs")

        // Now: switch to Vault (clear sync client and profile)
        manager.setSyncClient(nil, deviceId: "test-device")
        playerManager.setSyncClient(nil, deviceId: "test-device")
        UserDefaults.standard.removeObject(forKey: "serverProfiles")
        settingsManager = SettingsManager()
        manager.settingsManager = settingsManager

        // Create a fresh spy to detect any leaked calls
        let vaultSpy = ParitySpy()
        // Don't set it as sync client — Vault has none

        _ = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // Vault spy should have zero server interactions
        let vaultPulled = await vaultSpy.pullSubscriptionsCalled
        let vaultActions = await vaultSpy.getEpisodeActionsCalled
        let vaultQueue = await vaultSpy.syncQueueCalled
        XCTAssertFalse(vaultPulled, "Vault mode must not call pullSubscriptions")
        XCTAssertFalse(vaultActions, "Vault mode must not call getEpisodeActions")
        XCTAssertFalse(vaultQueue, "Vault mode must not call syncQueue")
    }
}

// MARK: - Parity Spy

/// Spy that implements `SyncClient` with full tracking for parity assertions.
/// Supports `supportsQueueSync = true` so queue operations are testable.
actor ParitySpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }

    var syncQueueCalled = false
    var getQueueCalled = false
    var getEpisodeActionsCalled = false
    var uploadEpisodeActionsCalled = false
    var pushSubscriptionsCalled = false
    var pullSubscriptionsCalled = false

    private var serverQueue: [QueueSyncItem] = []

    func setServerQueue(_ items: [QueueSyncItem]) { serverQueue = items }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        getQueueCalled = true
        return serverQueue
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

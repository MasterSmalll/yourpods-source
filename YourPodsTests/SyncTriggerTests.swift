/// Unified Sync Trigger Tests — Force Pull, Pull-to-Refresh, Foreground/Background
import SwiftData
import XCTest
@testable import YourPods

// MARK: - From ForcePullSyncTests.swift

/// Tests for the Force Pull sync fix.
///
/// Bug 1: "Force Pull from Server" only called syncEpisodeActions(), never
///         syncSubscriptions(). Server podcasts were never discovered.
/// Bug 2: clearProfileData() didn't clean up pendingSubscriptionAdds/Removals
///         keys, leaving stale data for deleted profiles.
/// Bug 3: Force Pull needs to reset lastSubscriptionSync timestamp to 0 so the
///         server returns its complete subscription list.
@MainActor
final class ForcePullSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-force-pull"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        clearTestDefaults()
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
            "serverProfiles",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Bug 1: forcePullFromServer must sync subscriptions

    func test_forcePullFromServer_pullsSubscriptionsFromServer() async throws {
        // GIVEN: A server with 2 subscriptions, no local subscriptions
        let mockClient = MockSyncClientForForcePull()
        await mockClient.setServerSubscriptions([
            "https://example.com/podcast-a",
            "https://example.com/podcast-b"
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Force pull from server
        _ = try await manager.forcePullFromServer(strategy: .serverWins)

        // THEN: pullSubscriptionChanges must have been called
        let pullCalled = await mockClient.pullSubscriptionsCalled
        XCTAssertTrue(pullCalled,
                      "forcePullFromServer must call syncSubscriptions which calls pullSubscriptionChanges")
    }

    func test_forcePullFromServer_alsoSyncsEpisodeActions() async throws {
        // GIVEN: A server with episode actions
        let mockClient = MockSyncClientForForcePull()
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Force pull from server
        _ = try await manager.forcePullFromServer(strategy: .serverWins)

        // THEN: getEpisodeActions must also have been called
        let episodeActionsCalled = await mockClient.getEpisodeActionsCalled
        XCTAssertTrue(episodeActionsCalled,
                      "forcePullFromServer must also call syncEpisodeActions")
    }

    // MARK: - Bug 3: forcePullFromServer resets sync timestamp

    func test_forcePullFromServer_resetsSyncTimestamp() async throws {
        // GIVEN: A non-zero lastSubscriptionSync timestamp (from a previous sync)
        UserDefaults.standard.set(999999, forKey: "lastSubscriptionSync_\(testProfileId)")

        let mockClient = MockSyncClientForForcePull()
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Force pull from server
        _ = try await manager.forcePullFromServer(strategy: .serverWins)

        // THEN: The pull must have been called with since=0 (full sync)
        let sincePulled = await mockClient.lastPulledSince
        XCTAssertEqual(sincePulled, 0,
                       "forcePullFromServer must reset lastSubscriptionSync to 0 before syncing, so server returns full list")
    }

    // MARK: - Bug 2: clearProfileData cleans up pending queues

    func test_clearProfileData_removesPendingAdds() {
        // GIVEN: Pending subscription adds for a profile
        let profileId = "profile-to-delete"
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        let addsKey = "pendingSubscriptionAdds_\(profileId)"
        UserDefaults.standard.set(["https://a.com/feed", "https://b.com/feed"], forKey: addsKey)

        // WHEN: Profile data is cleared
        manager.clearProfileData(profileId: profileId)

        // THEN: Pending adds are removed
        let remaining = UserDefaults.standard.stringArray(forKey: addsKey)
        XCTAssertNil(remaining,
                     "clearProfileData must remove pendingSubscriptionAdds for the deleted profile")
    }

    func test_clearProfileData_removesPendingRemovals() {
        // GIVEN: Pending subscription removals for a profile
        let profileId = "profile-to-delete"
        let removalsKey = "pendingSubscriptionRemovals_\(profileId)"
        UserDefaults.standard.set(["https://deleted.com/feed"], forKey: removalsKey)

        // WHEN: Profile data is cleared
        manager.clearProfileData(profileId: profileId)

        // THEN: Pending removals are removed
        let remaining = UserDefaults.standard.stringArray(forKey: removalsKey)
        XCTAssertNil(remaining,
                     "clearProfileData must remove pendingSubscriptionRemovals for the deleted profile")
    }

    // MARK: - Scenario: Pro → gPodder profile switch

    func test_Scenario_proToGpodder_forcePullDiscoversPodcasts() async throws {
        // GIVEN: User deleted Pro profile, created new gPodder profile
        //        The gPodder server has 2 existing subscriptions
        let serverUrls = [
            "https://example.com/podcast-alpha",
            "https://example.com/podcast-beta"
        ]
        let mockClient = MockSyncClientForForcePull()
        await mockClient.setServerSubscriptions(serverUrls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // No local subscriptions (fresh profile after deletion)
        XCTAssertTrue(manager.subscriptions.isEmpty, "Precondition: no local subscriptions")

        // WHEN: User taps Force Pull from Server
        _ = try await manager.forcePullFromServer(strategy: .serverWins)

        // THEN: Server URLs should have been associated with the profile
        // (actual RSS fetch may fail for mock URLs, but associateWithCurrentProfile
        //  must have been called by syncSubscriptions for each server URL)
        let key = "subscriptionUrls_\(testProfileId)"
        if let data = UserDefaults.standard.data(forKey: key),
           let profileUrls = try? JSONDecoder().decode(Set<String>.self, from: data) {
            for url in serverUrls {
                XCTAssertTrue(profileUrls.contains(url),
                              "Server URL \(url) must be associated with the profile after force pull")
            }
        } else {
            XCTFail("subscriptionUrls must be set after force pull")
        }
    }

    // MARK: - Regression: Incremental sync must NOT delete subscriptions

    func test_incrementalSync_doesNotDeleteExistingSubscriptions() async throws {
        // GIVEN: A server with 2 subscriptions; we do a full sync first (simulating Force Pull)
        let serverUrls = [
            "https://example.com/podcast-1",
            "https://example.com/podcast-2"
        ]
        let mockClient = MockSyncClientForForcePull()
        await mockClient.setServerSubscriptions(serverUrls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // Full sync (since=0) — pulls all subscriptions
        _ = try await manager.forcePullFromServer(strategy: .serverWins)

        // Verify subscriptions were associated
        let key = "subscriptionUrls_\(testProfileId)"
        let dataBefore = UserDefaults.standard.data(forKey: key)
        XCTAssertNotNil(dataBefore, "Precondition: subscriptions must exist after force pull")
        let urlsBefore = try! JSONDecoder().decode(Set<String>.self, from: dataBefore!)
        XCTAssertEqual(urlsBefore.count, 2, "Precondition: should have 2 subscriptions")

        // WHEN: Incremental sync (Refresh & Sync) — server returns empty delta
        //       (nothing changed since last sync)
        _ = try await manager.syncSubscriptions()

        // THEN: Subscriptions must still be there — NOT deleted
        let dataAfter = UserDefaults.standard.data(forKey: key)
        XCTAssertNotNil(dataAfter, "Subscriptions must NOT be deleted by incremental sync")
        let urlsAfter = try! JSONDecoder().decode(Set<String>.self, from: dataAfter!)
        XCTAssertEqual(urlsAfter.count, 2,
                       "Incremental sync must NOT delete existing subscriptions — had \(urlsBefore.count) before, now \(urlsAfter.count)")
        for url in serverUrls {
            XCTAssertTrue(urlsAfter.contains(url),
                          "Subscription \(url) must survive incremental sync")
        }
    }
}

// MARK: - Mock SyncClient (Actor)

actor MockSyncClientForForcePull: SyncClient {
    var serverSubscriptions: [String] = []
    var pullSubscriptionsCalled = false
    var getEpisodeActionsCalled = false
    var lastPulledSince: Int = -1

    func setServerSubscriptions(_ urls: [String]) { serverSubscriptions = urls }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        pullSubscriptionsCalled = true
        lastPulledSince = since
        // Simulate realistic gPodder behavior:
        // since=0 → full list; since>0 → only changes (empty if nothing changed)
        if since == 0 {
            return SubscriptionDelta(add: serverSubscriptions, remove: [], timestamp: 2000)
        } else {
            return SubscriptionDelta(add: [], remove: [], timestamp: since + 100)
        }
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        getEpisodeActionsCalled = true
        return []
    }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

// MARK: - From PullToRefreshSyncTests.swift

/// Tests that pull-to-refresh triggers a full sync cycle (refreshAndSync),
/// not just a feed refresh (refreshAllFeeds). This is a regression test for the
/// bug where pull-to-refresh on Up Next, Library, and Home only fetched RSS feeds
/// but never synced subscriptions, episode actions, or queue items from the server.
///
/// Root cause: `.refreshable { refreshAllFeeds() }` — should be `refreshAndSync(...)`.
@MainActor
final class PullToRefreshSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-ptr"

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

    // MARK: - Pull-to-Refresh should trigger full sync

    /// Regression test: pull-to-refresh must call refreshAndSync (which includes
    /// queue sync from server), not just refreshAllFeeds (which only fetches RSS).
    ///
    /// This test verifies the contract by setting up a Pro sync client with server
    /// queue items and calling refreshAndSync — the queue items should appear locally.
    /// If the code were using refreshAllFeeds, the server queue would never be pulled.
    func test_pullToRefreshSync_pullsQueueFromServer() async {
        // GIVEN: A Pro sync client with queue items on the server
        // Queue sync requires a Pro profile — set one up for factory dispatch
        let proProfile = ServerProfile(
            id: testProfileId,
            name: "Pro Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: "test-device",
            profileType: .yourpodsPro,
            proProfileName: "testpro"
        )
        let profiles = try! JSONEncoder().encode([proProfile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        // Re-init settingsManager to pick up profile
        settingsManager = SettingsManager()

        let spy = SpySyncClientForPTR()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/ep1.mp3",
                episodeGuid: "server-ep-1",
                sortOrder: 0,
                positionSec: 300,
                title: "Server Episode 1",
                podcastTitle: "Test Podcast"
            ),
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Precondition: queue is empty
        XCTAssertTrue(audioManager.queue.isEmpty, "Precondition: queue should be empty")

        // WHEN: Pull-to-refresh is triggered (which should call refreshAndSync)
        _ = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: Server queue items are adopted via fresh-device path
        // sortOrder 0 becomes currentItem (Bug 3 fix)
        XCTAssertEqual(audioManager.currentItem?.id, "server-ep-1",
                       "Pull-to-refresh via refreshAndSync must pull server queue items")
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 300)
    }

    /// Verify that refreshAllFeeds does NOT pull queue items from the server.
    /// This documents the broken behavior we're fixing.
    func test_refreshAllFeeds_doesNotPullQueueFromServer() async {
        // GIVEN: A Pro sync client with queue items on the server
        let spy = SpySyncClientForPTR()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/ep1.mp3",
                episodeGuid: "server-ep-1",
                sortOrder: 0,
                positionSec: 300,
                title: "Server Episode 1",
                podcastTitle: "Test Podcast"
            ),
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Only refreshAllFeeds is called (the OLD pull-to-refresh behavior)
        _ = await manager.refreshAllFeeds()

        // THEN: Queue is still empty — refreshAllFeeds doesn't sync queue
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "refreshAllFeeds must NOT pull server queue — only refreshAndSync does")

        // Verify getQueue was never called
        let getQueueCalled = await spy.getQueueCalled
        XCTAssertFalse(getQueueCalled,
                       "refreshAllFeeds should not call getQueue on the sync client")
    }

    /// Verify that refreshAndSync in Vault mode (no sync client) is safe to call
    /// from pull-to-refresh — it should complete without error.
    func test_pullToRefreshSync_safeInVaultMode() async {
        // GIVEN: No sync client (Vault mode)
        // No setSyncClient call

        // WHEN: Pull-to-refresh triggers refreshAndSync
        let conflicts = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: Should complete without crashing, zero conflicts
        XCTAssertTrue(conflicts.isEmpty,
                      "Vault mode pull-to-refresh must produce zero conflicts")
    }

    /// Verify that refreshAndSync syncs episode actions (listening positions)
    /// from the server, which refreshAllFeeds does not do.
    func test_pullToRefreshSync_syncsEpisodeActions() async {
        // GIVEN: A sync client with episode actions on the server
        let spy = SpySyncClientForPTR()
        await spy.setSupportsQueue(false)  // gPodder client (no queue, but has episode actions)
        await spy.setServerEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/feed.xml",
                episode: "https://example.com/ep1.mp3",
                guid: "ep-guid-1",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 600,
                started: 0,
                total: 3600,
                device: "other-device"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Pull-to-refresh triggers refreshAndSync
        _ = await manager.refreshAndSync(
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            strategy: .serverWins
        )

        // THEN: Episode action was fetched from server
        let wasCalled = await spy.getEpisodeActionsCalled
        XCTAssertTrue(wasCalled,
                      "Pull-to-refresh via refreshAndSync must sync episode actions from server")
    }

    /// Verify that refreshAllFeeds does NOT sync episode actions.
    func test_refreshAllFeeds_doesNotSyncEpisodeActions() async {
        // GIVEN: A sync client
        let spy = SpySyncClientForPTR()
        await spy.setSupportsQueue(false)
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Only refreshAllFeeds is called
        _ = await manager.refreshAllFeeds()

        // THEN: No episode action sync
        let wasCalled = await spy.getEpisodeActionsCalled
        XCTAssertFalse(wasCalled,
                       "refreshAllFeeds must NOT sync episode actions")
    }
}

// MARK: - Spy SyncClient for Pull-to-Refresh Tests

actor SpySyncClientForPTR: SyncClient {
    private var _supportsQueueSync: Bool = false
    var supportsQueueSync: Bool { _supportsQueueSync }
    var supportsSettingsSync: Bool { false }

    var syncQueueCalled = false
    var getQueueCalled = false
    var getEpisodeActionsCalled = false
    var uploadEpisodeActionsCalled = false
    var pushSubscriptionsCalled = false
    var pullSubscriptionsCalled = false

    private var serverQueue: [QueueSyncItem] = []
    private var serverEpisodeActions: [EpisodeAction] = []

    func setSupportsQueue(_ value: Bool) { _supportsQueueSync = value }
    func setServerQueue(_ items: [QueueSyncItem]) { serverQueue = items }
    func setServerEpisodeActions(_ actions: [EpisodeAction]) { serverEpisodeActions = actions }

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
        return serverEpisodeActions
    }
}

// MARK: - From ForegroundAndBackgroundSyncTests.swift

/// Tests that background refresh and foreground (app-open) both trigger a full sync
/// cycle (refreshAndSync), not just a feed refresh (refreshAllFeeds).
///
/// Bug: Background refresh only called refreshAllFeeds(), missing subscription sync,
/// episode action sync, and server queue sync. App-open had no sync trigger at all.
///
/// Fix: BackgroundRefreshService.performSync() uses refreshAndSync(). App foreground
/// triggers refreshAndSync() with a 5-minute debounce.
@MainActor
final class ForegroundAndBackgroundSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private var bgService: BackgroundRefreshService!
    private let testProfileId = "test-profile-fgbg"

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
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Bug 1: Background refresh must do full sync

    /// Background refresh must call syncSubscriptions (via the sync client),
    /// not just refreshAllFeeds which only fetches RSS.
    func test_backgroundRefresh_performSync_callsSyncSubscriptions() async {
        // GIVEN: A sync client with subscriptions on the server
        let spy = SpySyncClientForBGFG()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Background refresh performs its sync
        await bgService.performSync()

        // THEN: Subscription sync was triggered
        let wasCalled = await spy.pullSubscriptionsCalled
        XCTAssertTrue(wasCalled,
                      "Background refresh must sync subscriptions, not just refresh RSS feeds")
    }

    /// Background refresh must sync episode actions (listening positions)
    /// from the server.
    func test_backgroundRefresh_performSync_callsSyncEpisodeActions() async {
        // GIVEN: A sync client
        let spy = SpySyncClientForBGFG()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: Background refresh performs its sync
        await bgService.performSync()

        // THEN: Episode action sync was triggered
        let wasCalled = await spy.getEpisodeActionsCalled
        XCTAssertTrue(wasCalled,
                      "Background refresh must sync episode actions from server")
    }

    /// Background refresh in Vault mode (no sync client) must complete safely.
    func test_backgroundRefresh_performSync_safeInVaultMode() async {
        // GIVEN: No sync client (Vault mode)

        // WHEN: Background refresh performs its sync
        await bgService.performSync()

        // THEN: No crash — this is sufficient
    }

    // MARK: - Bug 2: Foreground sync debounce

    /// Foreground sync should trigger when the app has never synced before.
    func test_foregroundSync_shouldSync_whenNeverSyncedBefore() {
        // GIVEN: lastForegroundSyncDate is nil (fresh launch)
        bgService.lastForegroundSyncDate = nil

        // THEN: Should sync
        XCTAssertTrue(bgService.shouldPerformForegroundSync(),
                      "Foreground sync should trigger on first launch (never synced)")
    }

    /// Foreground sync should NOT trigger if the last sync was less than 5 minutes ago.
    func test_foregroundSync_shouldNotSync_whenRecentlySynced() {
        // GIVEN: Last sync was 2 minutes ago
        bgService.lastForegroundSyncDate = Date(timeIntervalSinceNow: -120)

        // THEN: Should NOT sync (within 5-minute debounce window)
        XCTAssertFalse(bgService.shouldPerformForegroundSync(),
                       "Foreground sync should be debounced if last sync was < 5 minutes ago")
    }

    /// Foreground sync should trigger if the last sync was more than 5 minutes ago.
    func test_foregroundSync_shouldSync_whenLastSyncOlderThan5Minutes() {
        // GIVEN: Last sync was 6 minutes ago
        bgService.lastForegroundSyncDate = Date(timeIntervalSinceNow: -360)

        // THEN: Should sync
        XCTAssertTrue(bgService.shouldPerformForegroundSync(),
                      "Foreground sync should trigger if last sync was > 5 minutes ago")
    }

    /// Verify that performSync updates lastForegroundSyncDate.
    func test_performSync_updatesLastForegroundSyncDate() async {
        // GIVEN: No previous sync
        bgService.lastForegroundSyncDate = nil

        // WHEN: Performing sync
        await bgService.performSync()

        // THEN: lastForegroundSyncDate should be updated
        XCTAssertNotNil(bgService.lastForegroundSyncDate,
                        "performSync must update lastForegroundSyncDate after completing")
    }
}

// MARK: - Spy SyncClient for Foreground/Background Tests

actor SpySyncClientForBGFG: SyncClient {
    private var _supportsQueueSync: Bool = false
    var supportsQueueSync: Bool { _supportsQueueSync }
    var supportsSettingsSync: Bool { false }

    var syncQueueCalled = false
    var getQueueCalled = false
    var getEpisodeActionsCalled = false
    var uploadEpisodeActionsCalled = false
    var pushSubscriptionsCalled = false
    var pullSubscriptionsCalled = false

    func setSupportsQueue(_ value: Bool) { _supportsQueueSync = value }

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

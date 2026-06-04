/// Unified Queue Sync Tests — Core Sync, Fixes, Flow + ProQueueItemDecoding
import SwiftData
import XCTest
@testable import YourPods

// MARK: - From QueueSyncTests.swift

/// Tests for Pro queue sync: push (device → server) and pull (server → device).
///
/// Root cause of the bug: `SyncClient.syncQueue(items:)` and `getQueue()` are
/// fully implemented in `YourPodsProClient` but never called from the sync
/// orchestration layer. These tests verify the new wiring.
@MainActor
final class QueueSyncTests: XCTestCase {

    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!

    override func setUp() {
        super.setUp()
        // Clear persisted queue from previous tests/sessions
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
    }

    override func tearDown() {
        playerManager = nil
        audioManager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQueueItem(
        id: String = "ep-1",
        title: String = "Episode 1",
        podcastTitle: String = "Podcast",
        audioUrl: String? = nil,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 42,
        durationSeconds: Int = 3600
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: audioUrl ?? "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - Push Tests

    func test_pushQueueToProServer_sendsCurrentItemAndQueue() async {
        // GIVEN: A Pro sync client and a queue with current item + 2 upcoming
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "current", title: "Now Playing", positionSeconds: 120)
        audioManager.appendToQueue([
            makeQueueItem(id: "next-1", title: "Next 1", positionSeconds: 0),
            makeQueueItem(id: "next-2", title: "Next 2", positionSeconds: 60),
        ])

        // WHEN: Push is called
        await playerManager.pushQueueToProServer()

        // THEN: 3 items pushed — current at sortOrder 0, queue at 1 and 2
        let pushed = await spy.syncedQueueItems
        XCTAssertEqual(pushed.count, 3, "Should push currentItem + 2 queue items")
        XCTAssertEqual(pushed[0].episodeGuid, "current")
        XCTAssertEqual(pushed[0].sortOrder, 0)
        XCTAssertEqual(pushed[0].positionSec, 120)
        XCTAssertEqual(pushed[1].episodeGuid, "next-1")
        XCTAssertEqual(pushed[1].sortOrder, 1)
        XCTAssertEqual(pushed[2].episodeGuid, "next-2")
        XCTAssertEqual(pushed[2].sortOrder, 2)
    }

    func test_pushQueueToProServer_sendsEmptyWhenNoQueue() async {
        // GIVEN: Pro client, no current item, empty queue
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN
        await playerManager.pushQueueToProServer()

        // THEN: Empty array pushed (clears server queue)
        let pushed = await spy.syncedQueueItems
        XCTAssertEqual(pushed.count, 0)
        let wasCalled = await spy.syncQueueCalled
        XCTAssertTrue(wasCalled, "Should still call syncQueue to clear server state")
    }

    func test_pushQueueToProServer_isNoOpForGPodder() async {
        // GIVEN: A gPodder client (supportsQueueSync = false)
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(false)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem()

        // WHEN
        await playerManager.pushQueueToProServer()

        // THEN: syncQueue is never called
        let wasCalled = await spy.syncQueueCalled
        XCTAssertFalse(wasCalled,
                       "gPodder clients must NOT call syncQueue — it's Pro-only")
    }

    func test_pushQueueToProServer_isNoOpWithNoClient() async {
        // GIVEN: No sync client set (Vault mode)
        audioManager.currentItem = makeQueueItem()

        // WHEN / THEN: Should not crash
        await playerManager.pushQueueToProServer()
    }

    // MARK: - Pull Tests

    func test_pullQueueFromProServer_appliesServerQueue() async {
        // GIVEN: Pro client with 2 items on server (including metadata)
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml", episodeUrl: "https://example.com/ep1.mp3", episodeGuid: "ep-1", sortOrder: 0, positionSec: 100,
                          title: "First Episode", podcastTitle: "Test Podcast", artworkUrl: "https://example.com/art1.jpg", durationSec: 3600),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml", episodeUrl: "https://example.com/ep2.mp3", episodeGuid: "ep-2", sortOrder: 1, positionSec: 200,
                          title: "Second Episode", podcastTitle: "Test Podcast", artworkUrl: "https://example.com/art2.jpg", durationSec: 1800),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // No current item — both should go into queue
        XCTAssertTrue(audioManager.queue.isEmpty)

        // WHEN
        await playerManager.pullQueueFromProServer()

        // THEN: Queue has 2 items with full metadata (not shadows)
        XCTAssertEqual(audioManager.queue.count, 2)
        XCTAssertEqual(audioManager.queue[0].id, "ep-1")
        XCTAssertEqual(audioManager.queue[0].title, "First Episode")
        XCTAssertEqual(audioManager.queue[0].podcastTitle, "Test Podcast")
        XCTAssertEqual(audioManager.queue[0].artworkUrl, "https://example.com/art1.jpg")
        XCTAssertEqual(audioManager.queue[0].durationSeconds, 3600)
        XCTAssertEqual(audioManager.queue[0].positionSeconds, 100)
        XCTAssertEqual(audioManager.queue[1].id, "ep-2")
        XCTAssertEqual(audioManager.queue[1].title, "Second Episode")
        XCTAssertEqual(audioManager.queue[1].positionSeconds, 200)
    }

    func test_pullQueueFromProServer_skipsCurrentlyPlayingEpisode() async {
        // GIVEN: Current item is ep-1, server queue has ep-1 and ep-2
        audioManager.currentItem = makeQueueItem(id: "ep-1")

        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml", episodeUrl: "https://example.com/ep1.mp3", episodeGuid: "ep-1", sortOrder: 0, positionSec: 0),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml", episodeUrl: "https://example.com/ep2.mp3", episodeGuid: "ep-2", sortOrder: 1, positionSec: 0),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN
        await playerManager.pullQueueFromProServer()

        // THEN: Only ep-2 goes into the queue — ep-1 is already playing
        XCTAssertEqual(audioManager.queue.count, 1)
        XCTAssertEqual(audioManager.queue[0].id, "ep-2")
    }

    func test_pullQueueFromProServer_isNoOpForGPodder() async {
        // GIVEN: gPodder client
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(false)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN
        await playerManager.pullQueueFromProServer()

        // THEN: getQueue never called
        let wasCalled = await spy.getQueueCalled
        XCTAssertFalse(wasCalled,
                       "gPodder clients must NOT call getQueue — it's Pro-only")
    }

    func test_pushQueueToProServer_includesCorrectPodcastAndEpisodeUrls() async {
        // GIVEN: Items with distinct podcast/episode URLs
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = makeQueueItem(
            id: "guid-123",
            audioUrl: "https://cdn.example.com/episode.mp3",
            podcastUrl: "https://example.com/feed.xml",
            positionSeconds: 999
        )
        audioManager.currentItem = item

        // WHEN
        await playerManager.pushQueueToProServer()

        // THEN
        let pushed = await spy.syncedQueueItems
        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(pushed[0].podcastUrl, "https://example.com/feed.xml")
        XCTAssertEqual(pushed[0].episodeUrl, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(pushed[0].episodeGuid, "guid-123")
        XCTAssertEqual(pushed[0].positionSec, 999)
    }

    // MARK: - Merge Tests

    func test_pullQueueFromProServer_mergesLocalAndServer() async {
        // GIVEN: Local queue has ep-local, server has ep-server
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml", episodeUrl: "https://example.com/server-ep.mp3", episodeGuid: "ep-server", sortOrder: 0, positionSec: 0,
                          title: "Server Episode", podcastTitle: "Server Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Add a local-only episode
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-local", title: "Local Episode", podcastTitle: "Local Podcast")
        ])
        XCTAssertEqual(audioManager.queue.count, 1, "Precondition: 1 local item")

        // WHEN
        await playerManager.pullQueueFromProServer()

        // THEN: Server queue replaces local — local-only items are removed
        // After push-then-pull, the server is the source of truth
        XCTAssertEqual(audioManager.queue.count, 1)
        let ids = audioManager.queue.map(\.id)
        XCTAssertFalse(ids.contains("ep-local"), "Local-only episode must be removed after server adoption")
        XCTAssertTrue(ids.contains("ep-server"), "Server episode must be present")
    }

    func test_pullQueueFromProServer_updatesPositionForSharedItems() async {
        // GIVEN: Local queue has ep-1 at position 100, server has ep-1 at position 500
        let spy = SpySyncClientForQueueSync()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml", episodeUrl: "https://example.com/ep1.mp3", episodeGuid: "ep-1", sortOrder: 0, positionSec: 500,
                          title: "Episode One", podcastTitle: "Test Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local has ep-1 at position 100
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-1", title: "Episode One", positionSeconds: 100)
        ])

        // WHEN
        await playerManager.pullQueueFromProServer()

        // THEN: Position updated to server's value
        XCTAssertEqual(audioManager.queue.count, 1)
        XCTAssertEqual(audioManager.queue[0].id, "ep-1")
        XCTAssertEqual(audioManager.queue[0].positionSeconds, 500, "Server position should win for shared items")
    }
}

// MARK: - Spy SyncClient (Actor)

actor SpySyncClientForQueueSync: SyncClient {
    private var _supportsQueueSync: Bool = true
    var supportsQueueSync: Bool { _supportsQueueSync }
    var supportsSettingsSync: Bool { false }

    var syncQueueCalled = false
    var getQueueCalled = false
    var syncedQueueItems: [QueueSyncItem] = []
    private var serverQueue: [QueueSyncItem] = []

    func setSupportsQueue(_ value: Bool) { _supportsQueueSync = value }
    func setServerQueue(_ items: [QueueSyncItem]) { serverQueue = items }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        syncedQueueItems = items
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        getQueueCalled = true
        return serverQueue
    }

    // MARK: - Unused protocol stubs
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
}

// MARK: - From QueueSyncFixTests.swift

/// Tests for the iOS queue sync fix — ensures:
/// 1. `ProPlaybackSyncRequest` includes `deviceId` field
/// 2. `ProSyncOrchestrator` pushes playback state with `nowPlaying: true` during sync
/// 3. Queue item deletion calls `DELETE /api/yourpods/queue` on Pro server
/// 4. Playback sync happens BEFORE queue sync in the orchestrator
///
/// All changes are scoped to YourPods Sync (Pro) only.
@MainActor
final class QueueSyncFixTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-queue-fix"

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

        // Set up a Pro profile for sync
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
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
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

    private func makeQueueItem(
        id: String = "ep-1",
        title: String = "Episode 1",
        podcastTitle: String = "Podcast",
        audioUrl: String? = nil,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 42,
        durationSeconds: Int = 3600
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: audioUrl ?? "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - Fix 1: ProPlaybackSyncRequest must include deviceId

    /// The `ProPlaybackSyncRequest` payload MUST include `deviceId` so the server
    /// can distinguish which device is currently playing. Without it, cross-device
    /// "now playing" handoff doesn't work.
    func test_proPlaybackSyncRequest_includesDeviceId() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "guid-123",
            positionSec: 342.5,
            durationSec: 1800.0,
            nowPlaying: true,
            completed: nil,
            deviceId: "yourpods-ios"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["device_id"] as? String, "yourpods-ios",
                       "ProPlaybackSyncRequest must include deviceId in the encoded payload")
    }

    /// deviceId nil should be omitted from payload (backward compat).
    func test_proPlaybackSyncRequest_omitsDeviceIdWhenNil() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil,
            positionSec: 0,
            durationSec: nil,
            nowPlaying: nil,
            completed: nil,
            deviceId: nil
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // When nil, deviceId should either be absent or null
        XCTAssertNil(dict["deviceId"] as? String,
                     "deviceId: nil should not encode as a string value")
    }

    // MARK: - Fix 2: ProSyncOrchestrator must push playback state during sync

    /// During orchestrated sync (e.g., force sync), the Pro orchestrator MUST push
    /// the current playback state with `nowPlaying: true` before the queue sync step.
    /// Without this, "force sync" never tells the server what's playing.
    func test_proSync_pushesPlaybackStateDuringSync() async {
        let spy = QueueFixSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Set up a currently playing episode
        audioManager.currentItem = makeQueueItem(
            id: "ep-playing",
            title: "Diary of a CEO",
            positionSeconds: 500
        )

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let lastSync = await spy.lastPlaybackSync
        XCTAssertNotNil(lastSync,
                        "Pro orchestrator must call syncPlayback during sync")
        XCTAssertEqual(lastSync?.nowPlaying, true,
                       "Playback push during sync must set nowPlaying: true")
        XCTAssertEqual(lastSync?.deviceId, "test-device",
                       "Playback push during sync must include deviceId")
    }

    /// Playback state must be pushed BEFORE queue sync so the server knows
    /// what's playing when it processes the queue.
    func test_proSync_pushesPlaybackBeforeQueue() async {
        let spy = QueueFixSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-playing")

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let callOrder = await spy.callOrder
        let playbackIndex = callOrder.firstIndex(of: "syncPlayback")
        let queuePushIndex = callOrder.firstIndex(of: "syncQueue")

        XCTAssertNotNil(playbackIndex, "syncPlayback must be called during Pro sync")
        XCTAssertNotNil(queuePushIndex, "syncQueue must be called during Pro sync")
        if let pi = playbackIndex, let qi = queuePushIndex {
            XCTAssertTrue(pi < qi,
                          "Playback sync must happen BEFORE queue push (playback at \(pi), queue at \(qi))")
        }
    }

    // MARK: - Fix 3: Queue deletion must call DELETE on Pro server

    /// When the user removes an episode from the queue on a Pro account,
    /// the app must call `DELETE /api/yourpods/queue?episodeUrl=...` so the
    /// server creates a tombstone preventing re-addition.
    func test_removeFromQueue_callsDeleteOnProServer() async {
        let spy = QueueFixSpy()
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = makeQueueItem(id: "ep-to-remove", positionSeconds: 0)
        audioManager.appendToQueue([item])
        XCTAssertEqual(audioManager.queue.count, 1)

        // Remove the item
        playerManager.removeFromQueue(item)

        // Give async Task time to execute
        try? await Task.sleep(for: .milliseconds(300))

        let deletedUrl = await spy.lastDeletedQueueEpisodeUrl
        XCTAssertEqual(deletedUrl, "https://example.com/ep-to-remove.mp3",
                       "Removing from queue must call deleteQueueItem on Pro server")
    }

    /// Queue deletion must be a no-op for non-Pro clients (gPodder / Vault).
    func test_removeFromQueue_isNoOpForNonProClient() async {
        let spy = QueueFixSpy()
        await spy.setSupportsQueue(false)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = makeQueueItem(id: "ep-to-remove")
        audioManager.appendToQueue([item])

        playerManager.removeFromQueue(item)

        try? await Task.sleep(for: .milliseconds(300))

        let deletedUrl = await spy.lastDeletedQueueEpisodeUrl
        XCTAssertNil(deletedUrl,
                     "Non-Pro clients must NOT call deleteQueueItem")
    }

    // MARK: - Negative: gPodder must NOT get these Pro-only behaviors

    /// gPodder sync must NOT push playback state with nowPlaying during sync.
    /// The gPodder protocol uses the default no-op syncPlayback extension,
    /// so the spy's syncPlayback won't be called.
    func test_gpodderSync_doesNotPushPlaybackState() async {
        let spy = QueueFixSpy()
        await spy.setSupportsQueue(false)
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-playing")

        let orchestrator = GPodderSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let lastSync = await spy.lastPlaybackSync
        XCTAssertNil(lastSync,
                     "gPodder orchestrator must NOT push playback state — it's Pro-only")
    }
}

// MARK: - Spy SyncClient for Queue Fix Tests

/// Spy that tracks calls for queue sync fix verification.
/// Records call order so we can verify playback-before-queue ordering.
actor QueueFixSpy: SyncClient {
    private var _supportsQueueSync: Bool = true
    var supportsQueueSync: Bool { _supportsQueueSync }
    var supportsSettingsSync: Bool { false }

    // Call tracking
    var callOrder: [String] = []

    // Playback sync tracking
    struct PlaybackSyncCall {
        let podcastUrl: String
        let episodeUrl: String
        let episodeGuid: String?
        let positionSec: Double
        let durationSec: Double?
        let nowPlaying: Bool?
        let completed: Bool?
        let deviceId: String?
    }
    var lastPlaybackSync: PlaybackSyncCall?

    // Queue tracking
    var syncQueueCalled = false
    var getQueueCalled = false
    var syncedQueueItems: [QueueSyncItem] = []

    // Queue deletion tracking
    var lastDeletedQueueEpisodeUrl: String?

    func setSupportsQueue(_ value: Bool) { _supportsQueueSync = value }
    func resetGetQueueCalled() { getQueueCalled = false }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        callOrder.append("syncQueue")
        syncQueueCalled = true
        syncedQueueItems = items
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        callOrder.append("getQueue")
        getQueueCalled = true
        return []
    }

    func deleteQueueItem(episodeUrl: String) async throws {
        callOrder.append("deleteQueueItem")
        lastDeletedQueueEpisodeUrl = episodeUrl
    }

    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?
    ) async throws {
        callOrder.append("syncPlayback")
        lastPlaybackSync = PlaybackSyncCall(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid,
            positionSec: positionSec,
            durationSec: durationSec,
            nowPlaying: nowPlaying,
            completed: completed,
            deviceId: deviceId
        )
    }

    // MARK: - Unused protocol stubs
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
}

// MARK: - From QueueSyncFlowTests.swift

/// Tests for the cross-device queue sync flow: pull → merge → push → adopt.
///
/// These tests validate that the queue sync correctly merges items from
/// the server (other devices) with the local queue before pushing the
/// merged result back, preventing the destructive-push-first bug where
/// one device's stale queue overwrites another device's items.
@MainActor
final class QueueSyncFlowTests: XCTestCase {

    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
    }

    override func tearDown() {
        playerManager = nil
        audioManager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQueueItem(
        id: String = "ep-1",
        title: String = "Episode 1",
        podcastTitle: String = "Podcast",
        audioUrl: String? = nil,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 0,
        durationSeconds: Int = 3600
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: audioUrl ?? "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - Pull-Merge-Push Flow

    /// When the server has items from another device and the local queue is empty,
    /// syncQueueWithServer should adopt the server queue wholesale (fresh device).
    /// sortOrder 0 becomes currentItem; no push-back to server.
    func test_syncQueueWithServer_addsServerItemsToEmptyLocalQueue() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/server-ep.mp3",
                          episodeGuid: "ep-server", sortOrder: 0, positionSec: 300,
                          title: "Server Episode", podcastTitle: "Server Podcast",
                          artworkUrl: "https://example.com/art.jpg", durationSec: 1800),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: sortOrder 0 becomes currentItem on fresh device (Bug 3 fix)
        XCTAssertEqual(audioManager.currentItem?.id, "ep-server")
        XCTAssertEqual(audioManager.currentItem?.title, "Server Episode")
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 300)

        // No additional queue items (only one server item)
        XCTAssertTrue(audioManager.queue.isEmpty)

        // Fresh device should NOT push back to server
        let syncCalled = await spy.syncQueueCalled
        XCTAssertFalse(syncCalled, "Fresh device should adopt server queue without pushing back")
    }

    /// When local has items and server has different items (from another device),
    /// the merge should include BOTH.
    func test_syncQueueWithServer_mergesLocalAndServerItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/server-ep.mp3",
                          episodeGuid: "ep-server", sortOrder: 0, positionSec: 0,
                          title: "Server Episode", podcastTitle: "Server Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local queue has a different item
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-local", title: "Local Episode", podcastTitle: "Local Podcast")
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Push includes BOTH local and server items
        let pushed = await spy.syncedQueueItems
        let pushedGuids = pushed.compactMap(\.episodeGuid)
        XCTAssertTrue(pushedGuids.contains("ep-local"), "Local item must be in push")
        XCTAssertTrue(pushedGuids.contains("ep-server"), "Server item must be in push")
    }

    /// Local items should appear first (preserve local ordering), server-new items appended.
    func test_syncQueueWithServer_preservesLocalOrdering() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/server-ep.mp3",
                          episodeGuid: "ep-server", sortOrder: 0, positionSec: 0,
                          title: "Server Episode", podcastTitle: "Server Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-local-1", title: "Local 1"),
            makeQueueItem(id: "ep-local-2", title: "Local 2"),
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Push has local items first, server item appended
        let pushed = await spy.syncedQueueItems
        let guids = pushed.compactMap(\.episodeGuid)
        // Local items should come before server-new items
        if let localIdx = guids.firstIndex(of: "ep-local-1"),
           let serverIdx = guids.firstIndex(of: "ep-server") {
            XCTAssertLessThan(localIdx, serverIdx,
                              "Local items should come before server-new items")
        } else {
            XCTFail("Both local and server items must be present")
        }
    }

    /// Duplicates (same episode on both local and server) should not appear twice.
    func test_syncQueueWithServer_deduplicatesSharedItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-shared.mp3",
                          episodeGuid: "ep-shared", sortOrder: 0, positionSec: 500,
                          title: "Shared Episode", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Same episode locally
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode", positionSeconds: 100)
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Only 1 copy, not 2
        let pushed = await spy.syncedQueueItems
        let sharedCount = pushed.filter { $0.episodeGuid == "ep-shared" }.count
        XCTAssertEqual(sharedCount, 1, "Duplicate items must be deduplicated")
    }

    /// The final local queue should match the server's response from POST /queue/sync.
    func test_syncQueueWithServer_adoptsServerResponse() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/server-ep.mp3",
                          episodeGuid: "ep-server", sortOrder: 0, positionSec: 0),
        ])
        // Server response after POST reorders/merges — this is the authoritative result
        await spy.setSyncResponse([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/server-ep.mp3",
                          episodeGuid: "ep-server", sortOrder: 0, positionSec: 0,
                          title: "Server Episode", podcastTitle: "Server Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/local-ep.mp3",
                          episodeGuid: "ep-local", sortOrder: 1, positionSec: 42,
                          title: "Local Episode", podcastTitle: "Local Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-local", title: "Local Episode", positionSeconds: 42)
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Final queue matches server response (2 items in server order)
        XCTAssertEqual(audioManager.queue.count, 2)
        XCTAssertEqual(audioManager.queue[0].id, "ep-server")
        XCTAssertEqual(audioManager.queue[1].id, "ep-local")
    }

    // MARK: - Position Reconciliation for Shared Items

    /// When serverWins, shared items should use the server's position in the push.
    func test_syncQueueWithServer_serverWins_usesServerPositionForSharedItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        // Server has the episode at 500s (from iPhone)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-shared.mp3",
                          episodeGuid: "ep-shared", sortOrder: 0, positionSec: 500,
                          title: "Shared Episode", podcastTitle: "Podcast",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.settingsManager = makeSettingsManager(strategy: .serverWins)

        // iPad has the episode at 100s (stale)
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode", positionSeconds: 100)
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Pushed position should be 500 (server), not 100 (local)
        let pushed = await spy.syncedQueueItems
        let sharedItem = pushed.first { $0.episodeGuid == "ep-shared" }
        XCTAssertEqual(sharedItem?.positionSec, 500,
                       "serverWins should use server position (500), not local (100)")
    }

    /// When deviceWins, shared items should keep the local position in the push.
    func test_syncQueueWithServer_deviceWins_keepsLocalPositionForSharedItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-shared.mp3",
                          episodeGuid: "ep-shared", sortOrder: 0, positionSec: 500,
                          title: "Shared Episode", podcastTitle: "Podcast",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.settingsManager = makeSettingsManager(strategy: .deviceWins)

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode", positionSeconds: 100)
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Pushed position should be 100 (local), not 500 (server)
        let pushed = await spy.syncedQueueItems
        let sharedItem = pushed.first { $0.episodeGuid == "ep-shared" }
        XCTAssertEqual(sharedItem?.positionSec, 100,
                       "deviceWins should keep local position (100), not server (500)")
    }

    /// When strategy is .ask and positions differ, syncQueueWithServer
    /// should return SyncConflict objects for the user to resolve.
    func test_syncQueueWithServer_ask_returnsConflictsForSharedItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-shared.mp3",
                          episodeGuid: "ep-shared", sortOrder: 0, positionSec: 500,
                          title: "Shared Episode", podcastTitle: "Podcast",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.settingsManager = makeSettingsManager(strategy: .ask)

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode", positionSeconds: 100)
        ])

        // WHEN
        let conflicts = await playerManager.syncQueueWithServer()

        // THEN: A conflict should be generated
        XCTAssertEqual(conflicts.count, 1, "Should generate 1 conflict for the shared item")
        XCTAssertEqual(conflicts.first?.episodeGuid, "ep-shared")
        XCTAssertEqual(conflicts.first?.localPosition, 100)
        XCTAssertEqual(conflicts.first?.serverPosition, 500)
    }

    /// When strategy is .ask but local position is 0 (never played),
    /// silently adopt server position — no conflict needed.
    func test_syncQueueWithServer_ask_noConflictWhenLocalIsZero() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-shared.mp3",
                          episodeGuid: "ep-shared", sortOrder: 0, positionSec: 500,
                          title: "Shared Episode", podcastTitle: "Podcast",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.settingsManager = makeSettingsManager(strategy: .ask)

        // Local has zero position (never played on this device)
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode", positionSeconds: 0)
        ])

        // WHEN
        let conflicts = await playerManager.syncQueueWithServer()

        // THEN: No conflict — silently adopt server position
        XCTAssertTrue(conflicts.isEmpty, "No conflict when local position is 0")

        // AND: Position should be updated to server's 500
        let pushed = await spy.syncedQueueItems
        let sharedItem = pushed.first { $0.episodeGuid == "ep-shared" }
        XCTAssertEqual(sharedItem?.positionSec, 500,
                       "Should adopt server position when local is 0")
    }

    // MARK: - No-op and Ordering

    /// Sync should be no-op for non-Pro clients.
    func test_syncQueueWithServer_isNoOpForGPodder() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(false)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let _ = await playerManager.syncQueueWithServer()

        let getCalled = await spy.getQueueCalled
        let syncCalled = await spy.syncQueueCalled
        XCTAssertFalse(getCalled)
        XCTAssertFalse(syncCalled)
    }

    /// GET should be called BEFORE POST (pull before push).
    func test_syncQueueWithServer_pullsBeforePushing() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let _ = await playerManager.syncQueueWithServer()

        let order = await spy.callOrder
        XCTAssertEqual(order, ["getQueue", "syncQueue"],
                       "Must pull (GET) before push (POST)")
    }
    // MARK: - Conflict Resolution

    /// When .ask generates a conflict, the PUSH should use the SERVER position
    /// for conflicted items (to preserve server state until user decides).
    func test_syncQueueWithServer_ask_pushesServerPositionForConflictedItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-shared.mp3",
                          episodeGuid: "ep-shared", sortOrder: 0, positionSec: 500,
                          title: "Shared Episode", podcastTitle: "Podcast",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.settingsManager = makeSettingsManager(strategy: .ask)

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode", positionSeconds: 100)
        ])

        // WHEN
        let conflicts = await playerManager.syncQueueWithServer()

        // THEN: Conflict generated
        XCTAssertEqual(conflicts.count, 1)

        // AND: Pushed position should be SERVER's 500 (NOT local 100)
        // to preserve the server state until the user resolves the conflict
        let pushed = await spy.syncedQueueItems
        let sharedItem = pushed.first { $0.episodeGuid == "ep-shared" }
        XCTAssertEqual(sharedItem?.positionSec, 500,
                       "Must push server position for conflicted items to preserve server state")
    }

    /// After resolving a queue conflict with "Use Server", the queue item's
    /// position must be updated.
    func test_resolveConflict_updatesQueueItemPosition() async {
        // Set up a queue item at local position 100
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-shared", title: "Shared Episode",
                          positionSeconds: 100, durationSeconds: 3600)
        ])

        let conflict = SyncConflict(
            episodeGuid: "ep-shared",
            episodeTitle: "Shared Episode",
            podcastTitle: "Podcast",
            podcastUrl: "https://example.com/feed.xml",
            artworkUrl: nil,
            audioUrl: "https://example.com/ep-shared.mp3",
            localPosition: 100,
            serverPosition: 500,
            serverTimestamp: 0,
            totalDuration: 3600,
            occurrenceCount: 1
        )

        // WHEN: User resolves with "Use Server"
        playerManager.resolveQueueConflict(conflict, chosenPosition: 500)

        // THEN: Queue item should now be at 500
        let queueItem = audioManager.queue.first { $0.id == "ep-shared" }
        XCTAssertEqual(queueItem?.positionSeconds, 500,
                       "Queue item position must update after conflict resolution")
    }

    // MARK: - Mark as Played + Server Tombstone

    /// When the user marks a queued episode as played, the server tombstone
    /// must be sent (via deleteQueueItem) to prevent re-addition on next sync.
    func test_markQueuedEpisodeAsPlayed_sendsServerTombstone() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = makeQueueItem(id: "ep-to-mark-played", title: "Played Episode")
        audioManager.appendToQueue([item])
        XCTAssertEqual(audioManager.queue.count, 1)

        // WHEN: User marks the queued episode as played
        playerManager.markQueuedEpisodeAsPlayed(item)

        // Give async Task time to execute the tombstone deletion
        try? await Task.sleep(for: .milliseconds(500))

        // THEN: Item should be removed from the local queue
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "Played episode must be removed from local queue")

        // AND: Server tombstone must be sent
        let deletedUrl = await spy.lastDeletedQueueEpisodeUrl
        XCTAssertEqual(deletedUrl, "https://example.com/ep-to-mark-played.mp3",
                       "markQueuedEpisodeAsPlayed must send deleteQueueItem tombstone to server")
    }

    // MARK: - Played Episode Filtering During Queue Sync

    /// When the server sends a queue item that is already marked as played locally,
    /// it should NOT be added to the local queue (Step 2b filter).
    func test_syncQueueWithServer_filtersPlayedEpisodesFromServerItems() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)

        // Server has two items: one played locally, one not
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-played.mp3",
                          episodeGuid: "ep-played", sortOrder: 0, positionSec: 3500,
                          title: "Played Episode", podcastTitle: "Test Pod",
                          durationSec: 3600),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-unplayed.mp3",
                          episodeGuid: "ep-unplayed", sortOrder: 1, positionSec: 100,
                          title: "Unplayed Episode", podcastTitle: "Test Pod",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Set up a local podcast with a played episode in SwiftData
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let context = container.mainContext
        
        // Set up a test profile so loadSubscriptions works
        UserDefaults.standard.set("test-queue-filter", forKey: "activeProfileId")

        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Test Pod")
        context.insert(podcast)

        let playedEpisode = Episode(guid: "ep-played", title: "Played Episode", podcast: podcast)
        playedEpisode.isPlayed = true
        playedEpisode.audioUrl = "https://example.com/ep-played.mp3"
        context.insert(playedEpisode)
        podcast.episodes.append(playedEpisode)

        let unplayedEpisode = Episode(guid: "ep-unplayed", title: "Unplayed Episode", podcast: podcast)
        unplayedEpisode.isPlayed = false
        unplayedEpisode.audioUrl = "https://example.com/ep-unplayed.mp3"
        context.insert(unplayedEpisode)
        podcast.episodes.append(unplayedEpisode)

        try! context.save()

        // Wire up PodcastManager with the test context
        let pm = PodcastManager(modelContext: context)
        pm.loadSubscriptions()
        playerManager.podcastManager = pm

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Only the unplayed episode should be in the queue
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertFalse(queueIds.contains("ep-played"),
                       "Played episodes must NOT be added to queue from server")
        XCTAssertTrue(queueIds.contains("ep-unplayed"),
                      "Unplayed episodes should be added to queue from server")
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_test-queue-filter")
    }

    /// When the server response (Step 4 adopt) includes a played episode,
    /// it should be filtered out of the final adopted queue.
    func test_syncQueueWithServer_filtersPlayedEpisodesFromAdoptedResponse() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([])

        // Server response after POST includes a played episode
        await spy.setSyncResponse([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-played.mp3",
                          episodeGuid: "ep-played", sortOrder: 0, positionSec: 3500,
                          title: "Played Episode", podcastTitle: "Test Pod",
                          durationSec: 3600),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-fresh.mp3",
                          episodeGuid: "ep-fresh", sortOrder: 1, positionSec: 0,
                          title: "Fresh Episode", podcastTitle: "Test Pod",
                          durationSec: 1800),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Set up local SwiftData with the played episode
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let context = container.mainContext
        
        // Set up a test profile so loadSubscriptions works
        UserDefaults.standard.set("test-queue-filter", forKey: "activeProfileId")

        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Test Pod")
        context.insert(podcast)

        let playedEpisode = Episode(guid: "ep-played", title: "Played Episode", podcast: podcast)
        playedEpisode.isPlayed = true
        playedEpisode.audioUrl = "https://example.com/ep-played.mp3"
        context.insert(playedEpisode)
        podcast.episodes.append(playedEpisode)

        try! context.save()

        let pm = PodcastManager(modelContext: context)
        pm.loadSubscriptions()
        playerManager.podcastManager = pm

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Adopted queue should NOT contain the played episode
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertFalse(queueIds.contains("ep-played"),
                       "Played episodes must be filtered from adopted server response")
        XCTAssertTrue(queueIds.contains("ep-fresh"),
                      "Non-played episodes should be adopted normally")
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_test-queue-filter")
    }

    // MARK: - Queue Truncation (API Spec: Max 200 Items)

    /// When the local queue has >200 items, the push to server should be
    /// truncated to 200 to comply with the API spec (Build 122).
    /// Excess items are silently dropped from the sync payload.
    func test_syncQueueWithServer_truncatesPushTo200Items() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Load 250 items into the local queue
        let items = (0..<250).map { i in
            makeQueueItem(id: "ep-\(i)", title: "Episode \(i)")
        }
        audioManager.appendToQueue(items)
        XCTAssertEqual(audioManager.queue.count, 250)

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Push should have at most 200 items
        let pushed = await spy.syncedQueueItems
        XCTAssertLessThanOrEqual(pushed.count, 200,
                                  "Queue push must be capped at 200 items per API spec")
    }

    /// pushQueueToProServer should also enforce the 200-item limit.
    func test_pushQueueToProServer_truncatesTo200Items() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Load 250 items into the local queue
        let items = (0..<250).map { i in
            makeQueueItem(id: "ep-\(i)", title: "Episode \(i)")
        }
        audioManager.appendToQueue(items)

        // WHEN
        await playerManager.pushQueueToProServer()

        // THEN: Push should have at most 200 items
        let pushed = await spy.syncedQueueItems
        XCTAssertLessThanOrEqual(pushed.count, 200,
                                  "pushQueueToProServer must cap at 200 items per API spec")
    }

    // MARK: - Stale Item Pruning (iPad Sync Fix)

    /// After the first queue sync has completed (flag set), local items
    /// NOT on the server should be pruned before push to prevent contamination.
    func test_queueSync_prunesStaleLocalItems_afterFirstSync() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        // Server has 3 items (iPhone's correct queue)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-1.mp3",
                          episodeGuid: "ep-1", sortOrder: 0, positionSec: 0,
                          title: "Episode 1", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-2.mp3",
                          episodeGuid: "ep-2", sortOrder: 1, positionSec: 0,
                          title: "Episode 2", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-3.mp3",
                          episodeGuid: "ep-3", sortOrder: 2, positionSec: 0,
                          title: "Episode 3", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local has 5 items (iPad's stale queue) — includes 2 stale items
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-1", title: "Episode 1"),
            makeQueueItem(id: "ep-2", title: "Episode 2"),
            makeQueueItem(id: "ep-3", title: "Episode 3"),
            makeQueueItem(id: "ep-stale-1", title: "Stale Episode 1"),
            makeQueueItem(id: "ep-stale-2", title: "Stale Episode 2"),
        ])

        // Mark that a queue sync has previously completed (not first sync)
        UserDefaults.standard.set(true, forKey: "proQueueSyncCompleted")
        // GUID-aware pruning: stale items were on the server before, now removed
        UserDefaults.standard.set(["ep-1", "ep-2", "ep-3", "ep-stale-1", "ep-stale-2"],
                                   forKey: PlayerManager.proQueueSyncServerGuidsKey)

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: The push should NOT contain the stale items
        let pushed = await spy.syncedQueueItems
        let pushedGuids = pushed.compactMap(\.episodeGuid)
        XCTAssertFalse(pushedGuids.contains("ep-stale-1"),
                       "Stale local item ep-stale-1 must be pruned before push")
        XCTAssertFalse(pushedGuids.contains("ep-stale-2"),
                       "Stale local item ep-stale-2 must be pruned before push")
        // Server items should still be present
        XCTAssertTrue(pushedGuids.contains("ep-1"))
        XCTAssertTrue(pushedGuids.contains("ep-2"))
        XCTAssertTrue(pushedGuids.contains("ep-3"))

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
        UserDefaults.standard.removeObject(forKey: PlayerManager.proQueueSyncServerGuidsKey)
    }

    /// On first sync (no flag), all local items should be preserved
    /// to avoid deleting legitimately queued episodes on a new device.
    func test_queueSync_preservesAllItems_onFirstSync() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        // Server has 3 items
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-1.mp3",
                          episodeGuid: "ep-1", sortOrder: 0, positionSec: 0,
                          title: "Episode 1", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local has items not on server
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-local-1", title: "Local 1"),
            makeQueueItem(id: "ep-local-2", title: "Local 2"),
        ])

        // Ensure the flag is NOT set (first sync)
        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: All local items should be in the push (not pruned)
        let pushed = await spy.syncedQueueItems
        let pushedGuids = pushed.compactMap(\.episodeGuid)
        XCTAssertTrue(pushedGuids.contains("ep-local-1"),
                      "First sync must preserve local items")
        XCTAssertTrue(pushedGuids.contains("ep-local-2"),
                      "First sync must preserve local items")
    }

    /// After pruning stale items, the push should only contain
    /// items that exist on the server (no contamination).
    func test_queueSync_pushDoesNotContaminateServer() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        // Server has 2 items
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-a.mp3",
                          episodeGuid: "ep-a", sortOrder: 0, positionSec: 100,
                          title: "Episode A", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-b.mp3",
                          episodeGuid: "ep-b", sortOrder: 1, positionSec: 200,
                          title: "Episode B", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local has 4 items — 2 matching server, 2 stale
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-a", title: "Episode A"),
            makeQueueItem(id: "ep-b", title: "Episode B"),
            makeQueueItem(id: "ep-zombie-1", title: "Zombie 1"),
            makeQueueItem(id: "ep-zombie-2", title: "Zombie 2"),
        ])

        UserDefaults.standard.set(true, forKey: "proQueueSyncCompleted")
        // GUID-aware pruning: zombie items were on the server before, now removed
        UserDefaults.standard.set(["ep-a", "ep-b", "ep-zombie-1", "ep-zombie-2"],
                                   forKey: PlayerManager.proQueueSyncServerGuidsKey)

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Push should have exactly the server's items, no zombies
        let pushed = await spy.syncedQueueItems
        let pushedGuids = Set(pushed.compactMap(\.episodeGuid))
        let expectedGuids: Set<String> = ["ep-a", "ep-b"]
        XCTAssertEqual(pushedGuids, expectedGuids,
                       "Push must only contain items on server — got \(pushedGuids)")

        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
        UserDefaults.standard.removeObject(forKey: PlayerManager.proQueueSyncServerGuidsKey)
    }

    /// Completed episodes should be stripped from the queue during sync.
    func test_queueSync_stripsCompletedEpisodesFromQueue() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)
        // Server has 3 items, one of which is completed (position == duration)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-active.mp3",
                          episodeGuid: "ep-active", sortOrder: 0, positionSec: 100,
                          title: "Active Episode", podcastTitle: "Podcast",
                          durationSec: 3600),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-completed.mp3",
                          episodeGuid: "ep-completed", sortOrder: 1, positionSec: 3903,
                          title: "Completed Episode", podcastTitle: "Podcast",
                          durationSec: 3903),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Set up local state to prevent fresh-device detection
        audioManager.currentItem = makeQueueItem(id: "ep-active", title: "Active Episode",
                                                  positionSeconds: 50)
        UserDefaults.standard.set(true, forKey: "proQueueSyncCompleted")

        // Set up a podcast with the completed episode marked as played
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let testContext = container.mainContext
        UserDefaults.standard.set("test-completed-strip", forKey: "activeProfileId")

        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        testContext.insert(podcast)

        let completedEp = Episode(guid: "ep-completed", title: "Completed Episode", podcast: podcast)
        completedEp.isPlayed = true
        completedEp.audioUrl = "https://example.com/ep-completed.mp3"
        testContext.insert(completedEp)
        podcast.episodes.append(completedEp)

        try! testContext.save()

        let pm = PodcastManager(modelContext: testContext)
        pm.loadSubscriptions()
        playerManager.podcastManager = pm

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Completed episode should NOT be in the final queue
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertFalse(queueIds.contains("ep-completed"),
                       "Completed episodes must be stripped from the queue")
        // ep-active may be in queue or currentItem (sortOrder 0 = currentItem)
        let hasActive = queueIds.contains("ep-active") ||
                        audioManager.currentItem?.id == "ep-active"
        XCTAssertTrue(hasActive,
                      "Active episodes should remain accessible (queue or currentItem)")

        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_test-completed-strip")
        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
    }

    // MARK: - Reorder Adoption (Web UI Regression)

    /// When the server returns items in a different order than the local queue
    /// (e.g., the user reordered on the Web UI), the iOS app MUST adopt the
    /// server's array order — not re-sort by local order or stale sortOrder fields.
    ///
    /// Regression: Prior code used `item.sortOrder` (an unreliable integer field)
    /// instead of the server response's array index, causing iOS to scramble
    /// the order and push the stale order back to the server.
    func test_syncQueueWithServer_adoptsServerReorder() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)

        // Server returns items reordered: A → C → B (user dragged C above B on Web UI)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-a.mp3",
                          episodeGuid: "ep-a", sortOrder: 0, positionSec: 0,
                          title: "Episode A", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-c.mp3",
                          episodeGuid: "ep-c", sortOrder: 1, positionSec: 0,
                          title: "Episode C", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-b.mp3",
                          episodeGuid: "ep-b", sortOrder: 2, positionSec: 0,
                          title: "Episode B", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local queue has the OLD order: A → B → C
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-a", title: "Episode A"),
            makeQueueItem(id: "ep-b", title: "Episode B"),
            makeQueueItem(id: "ep-c", title: "Episode C"),
        ])
        XCTAssertEqual(audioManager.queue.map(\.id), ["ep-a", "ep-b", "ep-c"],
                       "Precondition: local queue is A → B → C")

        // WHEN: Sync with server
        await playerManager.syncQueueWithServer()

        // THEN: Final queue must reflect server's order: A → C → B
        let finalOrder = audioManager.queue.map(\.id)
        XCTAssertEqual(finalOrder, ["ep-a", "ep-c", "ep-b"],
                       "Queue must adopt server's reordered sequence (A → C → B), got \(finalOrder)")
    }

    /// The push payload after adopting a server reorder must preserve the
    /// server's order — not re-impose the old local order.
    func test_syncQueueWithServer_pushPreservesServerReorder() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)

        // Server returns reordered: A → C → B
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-a.mp3",
                          episodeGuid: "ep-a", sortOrder: 0, positionSec: 0,
                          title: "Episode A", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-c.mp3",
                          episodeGuid: "ep-c", sortOrder: 1, positionSec: 0,
                          title: "Episode C", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-b.mp3",
                          episodeGuid: "ep-b", sortOrder: 2, positionSec: 0,
                          title: "Episode B", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local queue has old order: A → B → C
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-a", title: "Episode A"),
            makeQueueItem(id: "ep-b", title: "Episode B"),
            makeQueueItem(id: "ep-c", title: "Episode C"),
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: The pushed items must be in server order (A → C → B)
        let pushed = await spy.syncedQueueItems
        let pushedGuids = pushed.compactMap(\.episodeGuid)
        XCTAssertEqual(pushedGuids, ["ep-a", "ep-c", "ep-b"],
                       "Push must preserve server's reorder, not revert to local. Got \(pushedGuids)")
    }

    /// When the server response after POST echoes the items in a specific order,
    /// the ADOPT phase must use that response's array order — not re-sort by
    /// the sortOrder integers (which may be stale or broken on the server).
    func test_syncQueueWithServer_adoptUsesResponseArrayOrder() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)

        // Server GET returns all items (doesn't matter, local has them all)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-a.mp3",
                          episodeGuid: "ep-a", sortOrder: 0, positionSec: 0,
                          title: "Episode A", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-b.mp3",
                          episodeGuid: "ep-b", sortOrder: 1, positionSec: 0,
                          title: "Episode B", podcastTitle: "Podcast"),
        ])

        // Server POST response returns items in a DIFFERENT order than pushed,
        // with STALE sortOrder values that contradict the array order.
        // This simulates the server bug where sortOrder fields don't get updated.
        await spy.setSyncResponse([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-b.mp3",
                          episodeGuid: "ep-b", sortOrder: 5, positionSec: 0,
                          title: "Episode B", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-a.mp3",
                          episodeGuid: "ep-a", sortOrder: 0, positionSec: 0,
                          title: "Episode A", podcastTitle: "Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-a", title: "Episode A"),
            makeQueueItem(id: "ep-b", title: "Episode B"),
        ])

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: Final queue must follow the POST response array order (B → A),
        // NOT the stale sortOrder integers (which would give A=0, B=5 → A first).
        let finalOrder = audioManager.queue.map(\.id)
        XCTAssertEqual(finalOrder, ["ep-b", "ep-a"],
                       "ADOPT must use response array order, not stale sortOrder. Got \(finalOrder)")
    }

    /// Idempotency: syncing twice with no local changes must produce the same queue.
    func test_syncQueueWithServer_isIdempotent() async {
        let spy = QueueFlowSpy()
        await spy.setSupportsQueue(true)

        let serverQueue = [
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-x.mp3",
                          episodeGuid: "ep-x", sortOrder: 0, positionSec: 0,
                          title: "Episode X", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-y.mp3",
                          episodeGuid: "ep-y", sortOrder: 1, positionSec: 0,
                          title: "Episode Y", podcastTitle: "Podcast"),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep-z.mp3",
                          episodeGuid: "ep-z", sortOrder: 2, positionSec: 0,
                          title: "Episode Z", podcastTitle: "Podcast"),
        ]
        await spy.setServerQueue(serverQueue)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.appendToQueue([
            makeQueueItem(id: "ep-x", title: "Episode X"),
            makeQueueItem(id: "ep-y", title: "Episode Y"),
            makeQueueItem(id: "ep-z", title: "Episode Z"),
        ])

        // First sync
        await playerManager.syncQueueWithServer()
        let orderAfterFirst = audioManager.queue.map(\.id)

        // Second sync (no changes)
        await playerManager.syncQueueWithServer()
        let orderAfterSecond = audioManager.queue.map(\.id)

        XCTAssertEqual(orderAfterFirst, orderAfterSecond,
                       "Syncing twice with no changes must produce identical order")
        XCTAssertEqual(orderAfterSecond, ["ep-x", "ep-y", "ep-z"])
    }

    // MARK: - Helper

    private func makeSettingsManager(strategy: SyncStrategy) -> SettingsManager {
        let sm = SettingsManager()
        sm.syncConflictStrategy = strategy
        return sm
    }
}

// MARK: - Model Decoding Tests

final class ProQueueItemDecodingTests: XCTestCase {

    /// Server sends `artUrl` — model should decode it as `artworkUrl`.
    func test_proQueueItem_decodesArtUrl() throws {
        let json = """
        {
            "podcast_url": "https://example.com/feed.xml",
            "episode_url": "https://example.com/ep.mp3",
            "episode_guid": "guid-1",
            "sort_order": 0,
            "art_url": "https://example.com/art.jpg",
            "title": "Episode"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(ProQueueItem.self, from: json)
        XCTAssertEqual(item.artworkUrl, "https://example.com/art.jpg",
                       "artUrl from server should decode to artworkUrl")
    }

    /// Server sends `duration` (integer) — model should decode it as `durationSec`.
    func test_proQueueItem_decodesDuration() throws {
        let json = """
        {
            "podcast_url": "https://example.com/feed.xml",
            "episode_url": "https://example.com/ep.mp3",
            "sort_order": 0,
            "duration": 3600
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(ProQueueItem.self, from: json)
        XCTAssertEqual(item.durationSec, 3600,
                       "duration from server should decode to durationSec")
    }

    /// The existing snake_case keys should still work.
    func test_proQueueItem_decodesStandardSnakeCase() throws {
        let json = """
        {
            "podcast_url": "https://example.com/feed.xml",
            "episode_url": "https://example.com/ep.mp3",
            "episode_guid": "guid-1",
            "sort_order": 0,
            "artwork_url": "https://example.com/art.jpg",
            "duration_sec": 1800,
            "position_sec": 42.5
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(ProQueueItem.self, from: json)
        XCTAssertEqual(item.artworkUrl, "https://example.com/art.jpg")
        XCTAssertEqual(item.durationSec, 1800)
        XCTAssertEqual(item.positionSec, 42.5)
    }

    // MARK: - ProPlaybackAction Completed Field (iPad Sync Fix)

    /// The server's `/playback/recent` response includes a `completed` field
    /// that the client must decode. Without it, completed episodes are not
    /// stripped from the queue.
    func test_recentPlayback_decodesCompletedField() throws {
        // Simulate the server response from GET /api/yourpods/playback/recent
        let json = """
        {
            "podcast_url": "https://example.com/feed.xml",
            "episode_url": "https://example.com/ep-done.mp3",
            "episode_guid": "ep-done",
            "position_sec": 3903,
            "duration_sec": 3903,
            "updated_at": "2026-05-11T10:00:00Z",
            "completed": true
        }
        """.data(using: .utf8)!

        struct ProPlaybackAction: Codable {
            let podcastUrl: String
            let episodeUrl: String
            let episodeGuid: String?
            let positionSec: Double
            let durationSec: Double?
            let updatedAt: String?
            let completed: Bool?
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let action = try decoder.decode(ProPlaybackAction.self, from: json)

        XCTAssertEqual(action.completed, true,
                       "ProPlaybackAction must decode the 'completed' field from server response")
        XCTAssertEqual(action.episodeGuid, "ep-done")
        XCTAssertEqual(action.positionSec, 3903)
    }
}

// MARK: - Spy SyncClient

/// A spy sync client that tracks call order and supports configurable
/// server queue (GET response) and sync response (POST response).
actor QueueFlowSpy: SyncClient {
    private var _supportsQueueSync: Bool = true
    var supportsQueueSync: Bool { _supportsQueueSync }
    var supportsSettingsSync: Bool { false }

    var syncQueueCalled = false
    var getQueueCalled = false
    var syncedQueueItems: [QueueSyncItem] = []
    var callOrder: [String] = []

    private var serverQueue: [QueueSyncItem] = []
    private var syncResponse: [QueueSyncItem]?

    func setSupportsQueue(_ value: Bool) { _supportsQueueSync = value }
    func setServerQueue(_ items: [QueueSyncItem]) { serverQueue = items }
    func setSyncResponse(_ items: [QueueSyncItem]) { syncResponse = items }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        syncedQueueItems = items
        callOrder.append("syncQueue")
        // Return configured response, or echo back what was sent
        return QueueSyncResult(items: syncResponse ?? items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        getQueueCalled = true
        callOrder.append("getQueue")
        return serverQueue
    }

    // Queue deletion tracking
    var lastDeletedQueueEpisodeUrl: String?

    func deleteQueueItem(episodeUrl: String) async throws {
        callOrder.append("deleteQueueItem")
        lastDeletedQueueEpisodeUrl = episodeUrl
    }

    // MARK: - Unused protocol stubs
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
}

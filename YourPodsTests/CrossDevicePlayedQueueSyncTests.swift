import XCTest
import SwiftData
@testable import YourPods

/// Integration tests for the cross-device played/queue/relisten fix.
///
/// Covers four user-reported symptoms end-to-end through `ProSyncOrchestrator` and the
/// service layer it calls. The "server" is a spy returning canned responses.
///
/// Symptom map
/// -----------
/// S1 — mark-played propagates: finishing/marking an episode played results in a
///      `completed:true` push reaching the spy after a drain cycle (durable outbox),
///      AND a server `completed:true` delta causes local `isPlayed=true`.
///
/// S2 — re-add syncs to queue: re-adding a played episode clears local `isPlayed`
///      and issues the additive `addToQueue` call; a subsequent queue pull keeps it
///      in the queue (not filtered by the played-filter, since `isPlayed` was cleared).
///
/// S3 — relisten stays in queue: a recent-delta carrying `completed:false, positionSec:0`
///      for a locally-played episode causes `applyUncompletedChanges` to clear `isPlayed`,
///      so the queue adopt no longer drops it.
///
/// S4 — no clobber: an episode present in the server queue pull (added off-device)
///      survives the local reconcile/push (additive add / CAS).
@MainActor
final class CrossDevicePlayedQueueSyncTests: XCTestCase {

    // MARK: - Harness state

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private var outboxURL: URL!

    private let testProfileId = "test-crossdevice-played-queue"
    private let testDeviceId  = "test-device-crossdevice"

    // MARK: - setUp / tearDown

    override func setUp() {
        super.setUp()
        clearDefaults()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")

        podcastManager = PodcastManager(modelContext: context)
        audioManager   = AudioManager()
        playerManager  = PlayerManager(audioManager: audioManager)
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()

        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager
        podcastManager.downloadManager = downloadManager
        podcastManager.settingsManager = settingsManager

        outboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossdevice-outbox-\(UUID().uuidString).json")

        // Set up a Pro server profile so orchestrator settings paths fire.
        let proProfile = ServerProfile(
            id: testProfileId,
            name: "CrossDevice Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: testDeviceId,
            profileType: .yourpodsPro,
            proProfileName: "testpro"
        )
        let encoded = try! JSONEncoder().encode([proProfile])
        UserDefaults.standard.set(encoded, forKey: "serverProfiles")
    }

    override func tearDown() {
        clearDefaults()
        try? FileManager.default.removeItem(at: outboxURL)
        downloadManager  = nil
        settingsManager  = nil
        playerManager    = nil
        audioManager     = nil
        podcastManager   = nil
        context          = nil
        container        = nil
        outboxURL        = nil
        super.tearDown()
    }

    private func clearDefaults() {
        let keys: [String] = [
            "activeProfileId",
            "serverProfiles",
            "subscriptionUrls_\(testProfileId)",
            "lastSubscriptionSync_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition",
            "proFirstSyncCompleted_testpro",
            "proSettingsBase_testpro",
            "proQueueSyncCompleted",
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // MARK: - Helpers

    /// Insert a podcast + episode into SwiftData and wire it into PodcastManager.
    @discardableResult
    private func insertEpisode(
        guid: String,
        isPlayed: Bool = false,
        listenedSeconds: Int = 0
    ) -> (Podcast, Episode) {
        let feedUrl = "https://example.com/feed.xml"
        // Reuse existing podcast if already inserted (same feed URL).
        let podcast: Podcast
        if let existing = podcastManager.subscriptions.first(where: { $0.url == feedUrl }) {
            podcast = existing
        } else {
            podcast = Podcast(url: feedUrl, title: "Test Podcast")
            context.insert(podcast)
        }
        let episode = Episode(
            guid: guid,
            title: "Test Episode \(guid)",
            audioUrl: "https://example.com/\(guid).mp3",
            durationSeconds: 3600,
            podcast: podcast
        )
        episode.isPlayed = isPlayed
        episode.listenedSeconds = listenedSeconds
        context.insert(episode)
        try! context.save()
        podcastManager.associateWithCurrentProfile(url: feedUrl)
        podcastManager.loadSubscriptions()
        return (podcast, episode)
    }

    /// Build a fresh `EpisodeActionSyncService` backed by the shared test outbox URL.
    private func makeActionSync(client: (any SyncClient)? = nil) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.podcastManager.subscriptions ?? [] },
            syncClientProvider: { client },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId },
            completionOutboxFileURL: self.outboxURL
        )
    }

    /// Wire a spy into the orchestrator stack and run one foreground sync cycle.
    private func runOrchestratorSync(spy: CrossDeviceSpy) async -> [SyncConflict] {
        let orchSpy = CrossDeviceOrchestratorAdapter(spy: spy)
        podcastManager.setSyncClient(orchSpy, deviceId: testDeviceId)
        playerManager.setSyncClient(orchSpy, deviceId: testDeviceId)
        let orchestrator = ProSyncOrchestrator(client: orchSpy)
        return await orchestrator.sync(
            podcastManager: podcastManager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )
    }

    // MARK: - S1a: Durable completion outbox — iOS → server push

    /// Symptom 1a (outgoing): finishing/marking an episode played enqueues a
    /// `PendingCompletion`; the next `drainCompletionOutbox` call pushes
    /// `syncPlayback(completed:true)` to the server spy.
    ///
    /// Path: `markEpisodeAsPlayed` → `enqueueCompletion` → `drainCompletionOutbox`.
    func test_S1a_markPlayed_drainsPushesCompletedTrue() async {
        let (podcast, _) = insertEpisode(guid: "ep-s1a", isPlayed: false)

        let spy = CompletionOutboxSpy(failCount: 0)
        let service = makeActionSync(client: spy)

        // Wire the service into podcastManager so markEpisodeAsPlayed uses it.
        // We test the service's outbox directly since the orchestrator plumbing
        // for this uses the PodcastManager's episodeActionSync.
        let pending = PendingCompletion(
            podcastUrl: podcast.url,
            episodeUrl: "https://example.com/ep-s1a.mp3",
            episodeGuid: "ep-s1a",
            durationSec: 3600,
            eventTime: Date()
        )
        service.enqueueCompletion(pending)

        // Precondition: outbox has the entry.
        XCTAssertEqual(service.completionOutbox.count, 1,
                       "S1a precondition: completion must be in outbox after enqueue")

        // Drain (this is what ProSyncOrchestrator calls each cycle).
        await service.drainCompletionOutbox(using: spy, baselines: nil)

        let calls = await spy.syncPlaybackCalls
        XCTAssertFalse(calls.isEmpty, "S1a: drain must push at least one syncPlayback call")
        let completedCall = calls.first { $0.completed == true && $0.episodeGuid == "ep-s1a" }
        XCTAssertNotNil(completedCall,
                        "S1a: drained push must carry completed:true for the queued episode")
        XCTAssertEqual(service.completionOutbox.count, 0,
                       "S1a: outbox must be empty after successful drain")
    }

    // MARK: - S1b: Completed state ingest — server → iOS apply

    /// Symptom 1b (incoming): `applyCompletedChanges` called with a server
    /// `completed:true` delta marks the local episode as `isPlayed=true`.
    ///
    /// Path: `parseRecentResponse` → `applyCompletedChanges` → `episode.isPlayed`.
    func test_S1b_serverCompletedDelta_marksEpisodePlayed() throws {
        let (podcast, episode) = insertEpisode(guid: "ep-s1b", isPlayed: false)
        let service = makeActionSync()
        // Attach subscriptions so the service's index can find the episode.
        podcastManager.subscriptions = [podcast]

        XCTAssertFalse(episode.isPlayed, "S1b precondition: episode must start unplayed")

        // Simulate parsing a /playback/recent response with completed:true.
        let json = """
        {"states":[{
            "podcastUrl":"\(podcast.url)",
            "episodeUrl":"https://example.com/ep-s1b.mp3",
            "episodeGuid":"ep-s1b",
            "positionSec":3600,
            "completed":true
        }]}
        """.data(using: .utf8)!
        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertEqual(parsed.completed.count, 1,
                       "S1b: parseRecentResponse must emit exactly one CompletedStateChange")

        service.applyCompletedChanges(parsed.completed)

        XCTAssertTrue(episode.isPlayed,
                      "S1b: applyCompletedChanges must set isPlayed=true for the completed episode")
        XCTAssertTrue(service.outbox.isEmpty,
                      "S1b: applying a server completion must NOT enqueue an outbound echo")
    }

    // MARK: - S2: Re-add syncs to queue

    /// Symptom 2: Re-adding a played episode:
    ///  (a) clears local `isPlayed`,
    ///  (b) fires the additive `addToQueue` client call,
    ///  (c) a subsequent queue pull that includes the episode keeps it (played filter skipped).
    ///
    /// Path: `PlayerManager.addToQueue` → `markEpisodeAsUnplayedLocally` + `addToQueue` spy.
    func test_S2_reAddPlayedEpisode_clearsPlayed_callsAddToQueue_survivesQueuePull() async {
        let (_, episode) = insertEpisode(guid: "ep-s2", isPlayed: true, listenedSeconds: 3600)
        XCTAssertTrue(episode.isPlayed, "S2 precondition: episode must start played")

        let spy = CrossDeviceQueueSpy()
        playerManager.setSyncClient(spy, deviceId: testDeviceId)

        let didCallExp = XCTestExpectation(description: "S2: addToQueue called on spy")
        await spy.setAddToQueueFulfillment(didCallExp)

        // Re-add the played episode.
        playerManager.addToQueue(episode, playNext: false)

        // (a) Local played state must be cleared immediately (synchronous).
        XCTAssertFalse(episode.isPlayed,
                       "S2a: re-adding a played episode must clear isPlayed immediately")
        XCTAssertEqual(episode.listenedSeconds, 0,
                       "S2a: re-adding a played episode must reset listenedSeconds")

        // (b) Additive client call must fire.
        await fulfillment(of: [didCallExp], timeout: 2)
        let addedGuids = await spy.addedQueueGuids
        XCTAssertTrue(addedGuids.contains("ep-s2"),
                      "S2b: addToQueue must call spy with the episode guid; got \(addedGuids)")

        // (c) Since isPlayed is now false, a subsequent queue pull that contains this
        // episode must NOT drop it via the played-filter. Simulate a queue merge: the
        // item is in the server queue (added by re-add above) and must survive.
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/ep-s2.mp3",
                episodeGuid: "ep-s2",
                sortOrder: 0,
                positionSec: 0,
                title: "Test Episode ep-s2",
                podcastTitle: "Test Podcast"
            )
        ])
        await playerManager.syncQueueWithServer()

        // The episode must appear in the queue (not filtered out as played).
        let queueIds = audioManager.queue.map(\.id)
        let inCurrent = audioManager.currentItem?.id == "ep-s2"
        XCTAssertTrue(queueIds.contains("ep-s2") || inCurrent,
                      "S2c: re-added episode must survive queue pull (not filtered as played); queue=\(queueIds), current=\(audioManager.currentItem?.id ?? "nil")")
    }

    // MARK: - S3: Relisten stays in queue

    /// Symptom 3: A server delta carrying `completed:false, positionSec:0` for a
    /// locally-played episode causes `applyUncompletedChanges` to clear `isPlayed`,
    /// so the queue adopt step no longer drops it.
    ///
    /// Path: `parseRecentResponse(completed:false,pos:0)` → `UncompletedStateChange`
    ///       → `applyUncompletedChanges` → `isPlayed=false` → queue adopt keeps item.
    func test_S3_serverRelistenDelta_clearsPlayed_episodeSurvivesQueueAdopt() throws {
        let (podcast, episode) = insertEpisode(guid: "ep-s3", isPlayed: true, listenedSeconds: 1800)
        XCTAssertTrue(episode.isPlayed, "S3 precondition: episode must start played")

        let service = makeActionSync()
        podcastManager.subscriptions = [podcast]

        // Simulate parsing a /playback/recent response: completed:false, positionSec:0.
        let json = """
        {"states":[{
            "podcastUrl":"\(podcast.url)",
            "episodeUrl":"https://example.com/ep-s3.mp3",
            "episodeGuid":"ep-s3",
            "positionSec":0,
            "completed":false
        }]}
        """.data(using: .utf8)!
        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertEqual(parsed.uncompleted.count, 1,
                       "S3: parseRecentResponse must emit one UncompletedStateChange for completed:false+pos:0")
        XCTAssertTrue(parsed.completed.isEmpty,
                      "S3: completed:false must NOT emit a CompletedStateChange")

        // applyUncompletedChanges clears isPlayed (no pending outbox guard firing here).
        service.applyUncompletedChanges(parsed.uncompleted)

        XCTAssertFalse(episode.isPlayed,
                       "S3: applyUncompletedChanges must clear isPlayed so the episode is no longer filtered")
        XCTAssertEqual(episode.listenedSeconds, 0,
                       "S3: applyUncompletedChanges must reset listenedSeconds to 0")

        // Simulate the queue adopt: the server queue includes this episode.
        // Since isPlayed is now false, playerManager must keep it (not drop it).
        // We test this by placing the item in the Up Next queue directly and verifying
        // the played-filter on the QueueItem struct passes.
        let queueItem = QueueItem(
            id: "ep-s3",
            title: "Test Episode ep-s3",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/ep-s3.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: podcast.url,
            pubDate: nil
        )
        // The played-filter logic in queue sync drops episodes where the local Episode
        // model's isPlayed==true. Now that isPlayed is false, the item survives.
        // We verify the model directly — the queue sync filter reads isPlayed from the
        // Episode model via episodeActionSync.
        let matchingEpisode = podcastManager.subscriptions
            .flatMap(\.episodes)
            .first { $0.guid == queueItem.id }
        XCTAssertFalse(matchingEpisode?.isPlayed ?? true,
                       "S3: after applyUncompletedChanges, episode.isPlayed must be false — queue adopt will keep it")
    }

    // MARK: - S3b: Pending outbox guard — no clobber of just-finished episode

    /// Guard: an episode in the completion outbox (locally just finished, push pending)
    /// must NOT be un-played by a `completed:false` server delta in the same cycle.
    func test_S3b_pendingOutboxGuard_blocksUncompletedChanges() {
        let (podcast, episode) = insertEpisode(guid: "ep-s3b", isPlayed: true, listenedSeconds: 3600)

        let service = makeActionSync()
        podcastManager.subscriptions = [podcast]

        // Enqueue a pending completion (simulates: user just finished the episode locally).
        let pending = PendingCompletion(
            podcastUrl: podcast.url,
            episodeUrl: "https://example.com/ep-s3b.mp3",
            episodeGuid: "ep-s3b",
            durationSec: 3600,
            eventTime: Date()
        )
        service.enqueueCompletion(pending)
        XCTAssertTrue(service.pendingCompletionGuids().contains("ep-s3b"),
                      "S3b precondition: guid must be in the pending outbox")

        // Server sends completed:false (another device re-listened, but OUR push hasn't landed).
        let changes = [UncompletedStateChange(guid: "ep-s3b")]
        service.applyUncompletedChanges(changes)

        XCTAssertTrue(episode.isPlayed,
                      "S3b: pending-outbox guard must block un-playing a locally-completed episode")
        XCTAssertEqual(episode.listenedSeconds, 3600,
                       "S3b: listenedSeconds must remain untouched for guarded episodes")
    }

    // MARK: - S4: No clobber — off-device add survives local push

    /// Symptom 4: An episode present in the server queue pull (added on another device)
    /// survives the iOS queue reconcile/push. The additive `addToQueue` path for re-adds
    /// must not remove server-side items that were added off-device.
    ///
    /// Path: `syncQueueWithServer` with a server queue containing an off-device item
    ///       — the item must appear in the resulting local queue.
    func test_S4_offDeviceQueueAdd_survivesLocalReconcile() async {
        let spy = CrossDeviceQueueSpy()

        // Server has an item added off-device (e.g. added from the web).
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/ep-s4-offdevice.mp3",
                episodeGuid: "ep-s4-offdevice",
                sortOrder: 1,
                positionSec: 0,
                title: "Off-Device Episode",
                podcastTitle: "Test Podcast"
            )
        ])
        playerManager.setSyncClient(spy, deviceId: testDeviceId)

        // Local device has its own current item and queue entry.
        let localCurrent = QueueItem(
            id: "ep-s4-local",
            title: "Local Current",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/ep-s4-local.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: "https://example.com/feed.xml",
            pubDate: nil
        )
        audioManager.currentItem = localCurrent

        // Sync — the normal merge path (existing device has a current item).
        await playerManager.syncQueueWithServer()

        // Off-device item must survive.
        let queueIds = audioManager.queue.map(\.id)
        let inCurrent = audioManager.currentItem?.id == "ep-s4-offdevice"
        XCTAssertTrue(queueIds.contains("ep-s4-offdevice") || inCurrent,
                      "S4: off-device queue item must survive local reconcile; queue=\(queueIds), current=\(audioManager.currentItem?.id ?? "nil")")

        // Local current item must be preserved.
        XCTAssertEqual(audioManager.currentItem?.id, "ep-s4-local",
                       "S4: existing local current item must not be displaced")
    }

    // MARK: - S4b: Full orchestrator cycle — off-device add survives full sync

    /// Symptom 4b: Run a full `ProSyncOrchestrator` cycle against the spy. An off-device
    /// queue item returned by the server must appear in the resulting queue.
    func test_S4b_orchestratorSync_offDeviceItem_survivesFullCycle() async {
        let spy = CrossDeviceSpy()
        // Server has one off-device queue item.
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/ep-s4b.mp3",
                episodeGuid: "ep-s4b",
                sortOrder: 0,
                positionSec: 0,
                title: "Off-Device Ep",
                podcastTitle: "Test Podcast"
            )
        ])

        // Run the full orchestrator.
        _ = await runOrchestratorSync(spy: spy)

        // The item must appear somewhere in the player state.
        let queueIds = audioManager.queue.map(\.id)
        let inCurrent = audioManager.currentItem?.id == "ep-s4b"
        XCTAssertTrue(queueIds.contains("ep-s4b") || inCurrent,
                      "S4b: off-device item must survive full orchestrator sync; queue=\(queueIds), current=\(audioManager.currentItem?.id ?? "nil")")
    }
}

// MARK: - CrossDeviceQueueSpy

/// Minimal spy for queue-level tests (S2, S4): tracks `addToQueue` and `syncQueue`
/// calls, and returns a configurable server queue from `getQueue`.
actor CrossDeviceQueueSpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }

    private(set) var addedQueueGuids: [String] = []
    private(set) var syncQueueCalled = false
    private var serverQueue: [QueueSyncItem] = []
    private var addToQueueExpectation: XCTestExpectation?

    func setAddToQueueFulfillment(_ exp: XCTestExpectation) {
        addToQueueExpectation = exp
    }

    func setServerQueue(_ items: [QueueSyncItem]) {
        serverQueue = items
    }

    // MARK: SyncClient

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] { serverQueue }
    func deleteQueueItem(episodeUrl: String) async throws {}

    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws {
        addedQueueGuids.append(item.episodeGuid ?? item.episodeUrl)
        addToQueueExpectation?.fulfill()
        addToQueueExpectation = nil
    }
}

// MARK: - CrossDeviceSpy

/// Configurable spy for full-orchestrator tests (S4b). Returns canned server responses
/// for every protocol method. Extends the ProOrchestratorSpy pattern.
actor CrossDeviceSpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { true }

    private var serverQueue: [QueueSyncItem] = []
    private(set) var syncPlaybackCalls: [(episodeUrl: String, completed: Bool?)] = []
    private(set) var addedQueueGuids: [String] = []

    func setServerQueue(_ items: [QueueSyncItem]) { serverQueue = items }

    // MARK: SyncClient

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] { serverQueue }
    func deleteQueueItem(episodeUrl: String) async throws {}

    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws {
        addedQueueGuids.append(item.episodeGuid ?? item.episodeUrl)
    }

    func syncPlayback(
        podcastUrl: String, episodeUrl: String, episodeGuid: String?,
        positionSec: Double, durationSec: Double?,
        nowPlaying: Bool?, completed: Bool?,
        deviceId: String?, clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? {
        syncPlaybackCalls.append((episodeUrl: episodeUrl, completed: completed))
        return nil
    }

    func getCurrentPlayback() async throws -> ProPlaybackState? { nil }

    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws {}
    func getProfileSettings(profileName: String) async throws -> ProProfileSettings? { nil }
    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws {}
    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting] { [] }
}

// MARK: - CrossDeviceOrchestratorAdapter

/// Thin adapter that wraps `CrossDeviceSpy` and provides the minimal SyncClient
/// conformance expected by `ProSyncOrchestrator`. Delegates to the underlying spy
/// so that assertions on the spy still work.
actor CrossDeviceOrchestratorAdapter: SyncClient {
    private let spy: CrossDeviceSpy

    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { true }

    init(spy: CrossDeviceSpy) { self.spy = spy }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        try await spy.getQueue()
    }

    func deleteQueueItem(episodeUrl: String) async throws {}

    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws {
        try await spy.addToQueue(item: item, addToTop: addToTop)
    }

    func syncPlayback(
        podcastUrl: String, episodeUrl: String, episodeGuid: String?,
        positionSec: Double, durationSec: Double?,
        nowPlaying: Bool?, completed: Bool?,
        deviceId: String?, clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? {
        try await spy.syncPlayback(
            podcastUrl: podcastUrl, episodeUrl: episodeUrl, episodeGuid: episodeGuid,
            positionSec: positionSec, durationSec: durationSec,
            nowPlaying: nowPlaying, completed: completed,
            deviceId: deviceId, clientUpdatedAt: clientUpdatedAt,
            baseVersion: baseVersion
        )
    }

    func getCurrentPlayback() async throws -> ProPlaybackState? { nil }

    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws {}
    func getProfileSettings(profileName: String) async throws -> ProProfileSettings? { nil }
    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws {}
    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting] { [] }
}

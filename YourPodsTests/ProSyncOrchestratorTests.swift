import XCTest
import SwiftData
@testable import YourPods

/// Tests for `ProSyncOrchestrator` — full sync cycle including Pro-only steps.
///
/// The Pro orchestrator runs all sync steps: settings push/pull, subscriptions,
/// RSS refresh, auto-queue/download, episode actions, stats flush, groups sync,
/// and queue sync. Every step must be called.
@MainActor
final class ProSyncOrchestratorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private var baselineDir: URL!
    private let testProfileId = "test-profile-pro-orch"

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
        
        // Set up a Pro profile for settings sync
        let proProfile = ServerProfile(
            id: testProfileId,
            name: "Pro Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: "test-device",
            profileType: .yourpodsPro,
            proProfileName: "testpro"
        )
        // Store profile in UserDefaults the way the real app does
        let profiles = try! JSONEncoder().encode([proProfile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()
        manager.downloadManager = downloadManager
        manager.settingsManager = settingsManager

        // Step 5d now pushes under CAS, so the sync reads and writes the per-episode
        // baseline store. Left on its default it is a real profile-scoped file in the
        // container, shared with every other run of this class.
        baselineDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pro-orch-baselines-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: baselineDir, withIntermediateDirectories: true)
        playerManager.playbackBaselines = PlaybackBaselineStore(
            fileURL: baselineDir.appendingPathComponent("baselines.json")
        )
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: baselineDir)
        baselineDir = nil
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
            "proSettingsBase_testpro",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Positive: All Pro steps run

    /// Pro sync must sync subscriptions via the Pro client.
    func test_pro_syncsSubscriptions() async {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let wasCalled = await spy.pullSubscriptionsCalled
        XCTAssertTrue(wasCalled,
                      "Pro orchestrator must sync subscriptions")
    }

    /// Pro sync must fetch episode actions.
    func test_pro_syncsEpisodeActions() async {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let wasCalled = await spy.getEpisodeActionsCalled
        XCTAssertTrue(wasCalled,
                      "Pro orchestrator must sync episode actions")
    }

    /// Pro sync must push queue to server.
    func test_pro_syncsQueue() async {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let syncCalled = await spy.syncQueueCalled
        let getCalled = await spy.getQueueCalled
        XCTAssertTrue(syncCalled,
                      "Pro orchestrator must push queue to server")
        XCTAssertTrue(getCalled,
                      "Pro orchestrator must pull queue from server")
    }

    /// Pro sync must return conflicts from episode action sync.
    func test_pro_returnsConflictsFromEpisodeActions() async {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        // Sync with stubs — conflicts come from syncEpisodeActions
        let conflicts = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // With empty server data, conflicts should be empty
        XCTAssertTrue(conflicts.isEmpty,
                      "Empty server data should produce no conflicts")
    }
    /// Pro sync must push profile settings to the server when the device has a
    /// customization (sparse push — a fresh all-defaults device with no server view
    /// pushes nothing, by design).
    func test_pro_pushesProfileSettings() async {
        settingsManager.playbackSpeed = 1.7   // a customization to push

        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let wasCalled = await spy.patchProfileSettingsCalled
        XCTAssertTrue(wasCalled,
                      "Pro orchestrator must push global profile settings to server")
    }

    /// Pro sync must push the 'autopilot' key using server values (not Swift rawValues).
    func test_pro_pushesAutopilotKeyWithServerValue() async {
        // Set global autopilot to "Add Next" (.priority)
        settingsManager.defaultAutoQueueMode = .priority

        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let payload = await spy.lastPatchProfilePayload
        XCTAssertNotNil(payload, "Profile settings payload must not be nil")

        // Key must be "autopilot" (not "autoQueueMode")
        guard case .string(let value) = payload?["autopilot"] else {
            XCTFail("Payload must contain 'autopilot' key with a string value, got: \(String(describing: payload))")
            return
        }
        // Value must be server format "playNext" (not Swift rawValue "priority")
        XCTAssertEqual(value, "playNext",
                       "autopilot value for .priority must be 'playNext' (server format)")
    }

    /// Pro sync must push autopilot "addToQueue" for .normal mode.
    func test_pro_pushesAutopilotAddToQueue() async {
        settingsManager.defaultAutoQueueMode = .normal

        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let payload = await spy.lastPatchProfilePayload
        guard case .string(let value) = payload?["autopilot"] else {
            XCTFail("Payload must contain 'autopilot' key")
            return
        }
        XCTAssertEqual(value, "addToQueue",
                       "autopilot value for .normal must be 'addToQueue'")
    }

    /// Pro sync must pull profile settings from the server.
    func test_pro_pullsProfileSettings() async {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let wasCalled = await spy.getProfileSettingsCalled
        XCTAssertTrue(wasCalled,
                      "Pro orchestrator must pull global profile settings from server")
    }

    /// First sync must apply server autopilot value using server format.
    func test_pro_appliesServerAutopilotOnFirstSync() async {
        // Server returns autopilot: "playNext" — must be parsed via fromServerValue
        let spy = ProOrchestratorSpy()
        await spy.setProfileSettingsResponse(ProProfileSettings(
            profileName: "testpro",
            payload: ["autopilot": .string("playNext")],
            updatedAt: nil
        ))
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        // Ensure first sync flag is NOT set
        UserDefaults.standard.removeObject(forKey: "proFirstSyncCompleted_testpro")

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        XCTAssertEqual(settingsManager.defaultAutoQueueMode, .priority,
                       "Server 'playNext' must be applied as .priority on first sync")
    }

    // MARK: - Step ordering invariants

    /// Helper: run a full sync against a fresh spy and return its call order.
    private func runSyncAndCaptureOrder() async -> [String] {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )
        return await spy.callOrder
    }

    /// Pull-before-push contract for profile settings (ProSyncOrchestrator Step 1).
    /// Pulling first lets the three-way merge detect genuine same-key conflicts before
    /// our own push masks them; the push that follows is SPARSE (only changed keys), so
    /// pulling first no longer risks a stale server value overwriting a local edit.
    func test_pro_pullsProfileSettingsBeforePush() async {
        let order = await runSyncAndCaptureOrder()
        guard let pullIdx = order.firstIndex(of: "getProfileSettings"),
              let pushIdx = order.firstIndex(of: "patchProfileSettings") else {
            XCTFail("Expected both getProfileSettings and patchProfileSettings, got: \(order)")
            return
        }
        XCTAssertLessThan(pullIdx, pushIdx,
                          "Profile settings pull must precede push (merge detects conflicts; push is sparse)")
    }

    /// Pre-fetch-before-queue contract: server playback state is captured
    /// (Step 5b-read) before queue sync (Step 7) adopts merged queue state.
    func test_pro_prefetchesPlaybackBeforeQueueSync() async {
        let order = await runSyncAndCaptureOrder()
        guard let playbackIdx = order.firstIndex(of: "getCurrentPlayback"),
              let queueIdx = order.firstIndex(of: "getQueue") else {
            XCTFail("Expected both getCurrentPlayback and getQueue, got: \(order)")
            return
        }
        XCTAssertLessThan(playbackIdx, queueIdx,
                          "Playback pre-fetch must precede queue sync")
    }

    /// Episode actions (Step 5) must precede the playback chain (Step 5b)
    /// so reconciliation sees applied positions.
    func test_pro_syncsEpisodeActionsBeforePlaybackChain() async {
        let order = await runSyncAndCaptureOrder()
        guard let actionsIdx = order.firstIndex(of: "getEpisodeActions"),
              let playbackIdx = order.firstIndex(of: "getCurrentPlayback") else {
            XCTFail("Expected both getEpisodeActions and getCurrentPlayback, got: \(order)")
            return
        }
        XCTAssertLessThan(actionsIdx, playbackIdx,
                          "Episode action sync must precede playback reconciliation")
    }

    // MARK: - Fix C: stop the resurrection push

    private func runSync(spy: ProOrchestratorSpy) async {
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )
    }

    private func setupCurrentItem(guid: String, isPlayed: Bool) {
        let podcast = Podcast(url: "https://example.com/pod", title: "Pod")
        context.insert(podcast)
        let ep = Episode(
            guid: guid,
            title: "Ep \(guid)",
            audioUrl: "https://example.com/\(guid).mp3",
            pubDate: Date(),
            durationSeconds: 3600
        )
        ep.podcast = podcast
        ep.isPlayed = isPlayed
        context.insert(ep)
        podcast.episodes = [ep]
        manager.subscriptions = [podcast]
        audioManager.currentItem = QueueItem(
            id: guid,
            title: "Ep \(guid)",
            podcastTitle: "Pod",
            audioUrl: "https://example.com/\(guid).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: "https://example.com/pod",
            pubDate: nil
        )
    }

    /// A finished current item (server already says completed → Episode.isPlayed)
    /// must NOT be re-pushed as nowPlaying:true, and must be cleared from the player.
    func test_pro_finishedCurrentItem_doesNotResurrectAsNowPlaying() async {
        setupCurrentItem(guid: "fin-1", isPlayed: true)
        let spy = ProOrchestratorSpy()
        await runSync(spy: spy)

        let calls = await spy.syncPlaybackCalls
        XCTAssertFalse(
            calls.contains { $0.episodeUrl == "https://example.com/fin-1.mp3" && $0.nowPlaying == true },
            "A finished current item must NOT be pushed as nowPlaying:true (resurrection)"
        )
        XCTAssertNil(audioManager.currentItem, "Finished current item should be cleared from the now-playing player")
    }

    /// Guard regression: an unplayed current item must STILL push nowPlaying:true
    /// (gate is on isPlayed, not isPlaying) so cross-device handoff keeps working.
    func test_pro_unplayedCurrentItem_stillPushesNowPlaying() async {
        setupCurrentItem(guid: "live-1", isPlayed: false)
        let spy = ProOrchestratorSpy()
        await runSync(spy: spy)

        let calls = await spy.syncPlaybackCalls
        XCTAssertTrue(
            calls.contains { $0.episodeUrl == "https://example.com/live-1.mp3" && $0.nowPlaying == true },
            "An unplayed current item must still push nowPlaying:true for handoff"
        )
    }

    // MARK: - Step 5d carries the CAS baseline

    /// The periodic playback push is the one the reconciler's conflicts come back to, and
    /// it was the last high-frequency site still sending `baseVersion: nil`. A versionless
    /// push merges server-side, so it is not destructive — but it can never be *refused*,
    /// and only a refusal produces the `conflicts[]` entry that becomes a `sync_conflicts`
    /// row and reaches the sheet. Divergence arriving on this path was therefore invisible
    /// to the whole conflict feature, no matter how correct the reconciler was.
    ///
    /// `0` is the right value with no stored baseline — "I believe no row exists" — and is
    /// a positive claim. `nil` is the legacy opt-out, which is what this asserts against.
    func test_pro_playbackPush_carriesACASBaseline() async {
        setupCurrentItem(guid: "cas-1", isPlayed: false)
        let spy = ProOrchestratorSpy()
        await runSync(spy: spy)

        let calls = await spy.syncPlaybackCalls
        let push = calls.first { $0.episodeUrl == "https://example.com/cas-1.mp3" }
        XCTAssertNotNil(push, "the current item must be pushed")
        XCTAssertNotNil(
            push?.baseVersion,
            "an omitted baseVersion is legacy last-write-wins — the server cannot refuse it, "
            + "so a divergence on this path never becomes a conflict row and never reaches the sheet"
        )
    }

    /// Once the push is versioned the server stops merging and writes the value columns
    /// verbatim, so `completed: nil` — which Go reads as `false` — silently un-completes the
    /// episode. Step 5d sent exactly that for every unplayed item (`isPlayed ? true : nil`).
    func test_pro_playbackPush_sendsExplicitCompleted() async {
        setupCurrentItem(guid: "flag-1", isPlayed: false)
        let spy = ProOrchestratorSpy()
        await runSync(spy: spy)

        let calls = await spy.syncPlaybackCalls
        let push = calls.first { $0.episodeUrl == "https://example.com/flag-1.mp3" }
        XCTAssertEqual(push?.completed, false,
                       "a versioned push must state the flag it is asserting, not leave it to the decoder's zero value")
    }

    /// Per-podcast settings push-then-pull contract (Step 1b).
    /// When dirty settings exist, push MUST precede pull to prevent stale
    /// server values from overwriting local edits.
    /// When no dirty settings exist, push is skipped but pull still runs.
    func test_pro_pushesPerPodcastSettingsBeforePull() async {
        let order = await runSyncAndCaptureOrder()
        let pushIdx = order.firstIndex(of: "pushPodcastSettingsBatch")
        let pullIdx = order.firstIndex(of: "pullPodcastSettings")
        
        // Pull must always be called
        XCTAssertNotNil(pullIdx, "pullPodcastSettings must be called during sync, got: \(order)")
        
        // When push happens, it must be before pull
        if let pushIdx, let pullIdx {
            XCTAssertLessThan(pushIdx, pullIdx,
                              "Per-podcast settings push must precede pull")
        }
    }

    // MARK: - Incremental episode-action pull (anti-thrash)

    /// Regression: a routine Pro sync must pull episode actions INCREMENTALLY from
    /// the persisted cursor — not re-pull the entire history (`since=0`) every time.
    ///
    /// The Pro orchestrator was calling `syncEpisodeActions(strategy:)` without
    /// `force:`, which defaults to `force: true` → `since=0`. On a large library that
    /// re-fetches + re-applies the full action history every sync, blowing the iOS
    /// disk-write budget and stranding the sync in a never-completes loop (the
    /// "feeds not updating" root cause). gPodder already passes `force: false`.
    func test_pro_routineSync_pullsEpisodeActionsIncrementally_fromCursor() async {
        // Simulate a prior completed sync that advanced the cursor.
        let priorCursor = 1_750_000_000
        UserDefaults.standard.set(priorCursor, forKey: "lastEpisodeActionSync_\(testProfileId)")

        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let since = await spy.lastGetEpisodeActionsSince
        XCTAssertEqual(since, priorCursor,
                       "Pro routine sync must pull episode actions incrementally from the persisted cursor, not re-pull all history (since=0) every sync")
    }

    // MARK: - Cancellation

    /// A sync task that is already cancelled at the point it checks
    /// should not perform the full pipeline.
    func test_pro_cancelledBeforeStart_doesNotCompleteFullPipeline() async {
        let spy = ProOrchestratorSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let orchestrator = ProSyncOrchestrator(client: spy)

        let syncTask = Task {
            await orchestrator.sync(
                podcastManager: manager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: .serverWins
            )
        }
        syncTask.cancel()
        _ = await syncTask.value

        let order = await spy.callOrder
        // Cancelled task should NOT reach the end of the pipeline
        // (getQueue = last step). Some early steps may have started
        // before the cancellation check on @MainActor.
        XCTAssertFalse(order.contains("getQueue"),
                       "Cancelled sync must not reach queue sync, but called: \(order)")
    }
}

// MARK: - Spy SyncClient for Pro Orchestrator Tests

/// This spy conforms to `SyncClient` and implements the protocol methods
/// including `patchProfileSettings` and `getProfileSettings`, so the
/// ProSyncOrchestrator's settings push/pull path is properly exercised.
actor ProOrchestratorSpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { true }

    var syncQueueCalled = false
    var getQueueCalled = false
    var getEpisodeActionsCalled = false
    var lastGetEpisodeActionsSince: Int?
    var uploadEpisodeActionsCalled = false
    var pushSubscriptionsCalled = false
    var pullSubscriptionsCalled = false
    var patchProfileSettingsCalled = false
    var getProfileSettingsCalled = false
    var pushStatsEventsCalled = false
    var lastPatchProfilePayload: [String: AnyCodableValue]?
    private var profileSettingsResponse: ProProfileSettings?

    /// Ordered names of every client call, for step-ordering assertions.
    var callOrder: [String] = []

    func setProfileSettingsResponse(_ response: ProProfileSettings) {
        profileSettingsResponse = response
    }

    // MARK: - Global Profile Settings

    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws {
        callOrder.append("patchProfileSettings")
        patchProfileSettingsCalled = true
        lastPatchProfilePayload = payload
    }

    func getProfileSettings(profileName: String) async throws -> ProProfileSettings? {
        callOrder.append("getProfileSettings")
        getProfileSettingsCalled = true
        return profileSettingsResponse
    }

    // MARK: - Per-Podcast Settings

    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws {
        callOrder.append("pushPodcastSettingsBatch")
    }

    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting] {
        callOrder.append("pullPodcastSettings")
        return []
    }

    // MARK: - Playback

    func getCurrentPlayback() async throws -> ProPlaybackState? {
        callOrder.append("getCurrentPlayback")
        return nil
    }

    // MARK: - Queue

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        callOrder.append("syncQueue")
        syncQueueCalled = true
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        callOrder.append("getQueue")
        getQueueCalled = true
        return []
    }

    // MARK: - Subscriptions

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        callOrder.append("pushSubscriptions")
        pushSubscriptionsCalled = true
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        callOrder.append("pullSubscriptionChanges")
        pullSubscriptionsCalled = true
        return SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    // MARK: - Episode Actions

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        callOrder.append("uploadEpisodeActions")
        uploadEpisodeActionsCalled = true
        return []
    }

    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        callOrder.append("getEpisodeActions")
        getEpisodeActionsCalled = true
        lastGetEpisodeActionsSince = since
        return []
    }

    // MARK: - Playback push (Fix C observability)

    /// Records every now-playing/completed push so tests can assert a finished
    /// current item is NOT re-asserted as nowPlaying:true (resurrection).
    var syncPlaybackCalls: [(episodeUrl: String, nowPlaying: Bool?, completed: Bool?, baseVersion: Int64?)] = []

    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?,
        clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? {
        callOrder.append("syncPlayback")
        syncPlaybackCalls.append((episodeUrl: episodeUrl, nowPlaying: nowPlaying,
                                  completed: completed, baseVersion: baseVersion))
        return nil
    }
}

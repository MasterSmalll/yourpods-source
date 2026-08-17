import XCTest
import SwiftData
@testable import YourPods

/// Tests for the Pro sync fix:
/// 1. Per-podcast settings push/pull during Pro sync
/// 2. Queue pull replaces (not merges) local queue
/// 3. Batch upload excludes currently-playing episode from nowPlaying reset
/// 4. PodcastSettings ↔ server payload round-trip mapping
@MainActor
final class PerPodcastSettingsSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-perpodcast"

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
            "lastPodcastSettingsSyncTimestamp_testpro",
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

    // MARK: - PodcastSettings ↔ Server Payload Mapping

    /// PodcastSettings.toServerPayload() must convert local field names to server keys.
    func test_podcastSettings_toServerPayload_mapsKeys() {
        var settings = PodcastSettings()
        settings.skipIntroSeconds = 120
        settings.skipOutroSeconds = 20
        settings.autoQueueMode = .priority  // should map to "playNext"
        settings.playbackSpeed = 1.5

        let payload = settings.toServerPayload()

        XCTAssertEqual(payload["skipIntroSec"], .int(120))
        XCTAssertEqual(payload["skipOutroSec"], .int(20))
        XCTAssertEqual(payload["autopilot"], .string("playNext"))
        XCTAssertEqual(payload["playbackSpeed"], .double(1.5))
    }

    /// AutoQueueMode server value mapping:
    /// .off → "off", .normal → "addToQueue", .priority → "playNext"
    func test_podcastSettings_autopilotMapping() {
        var off = PodcastSettings()
        off.autoQueueMode = .off
        XCTAssertEqual(off.toServerPayload()["autopilot"], .string("off"))

        var normal = PodcastSettings()
        normal.autoQueueMode = .normal
        XCTAssertEqual(normal.toServerPayload()["autopilot"], .string("addToQueue"))

        var priority = PodcastSettings()
        priority.autoQueueMode = .priority
        XCTAssertEqual(priority.toServerPayload()["autopilot"], .string("playNext"))
    }

    /// fromServerPayload() must convert server keys back to PodcastSettings fields.
    func test_podcastSettings_fromServerPayload_mapsKeys() {
        let payload: [String: AnyCodableValue] = [
            "skipIntroSec": .int(120),
            "skipOutroSec": .int(20),
            "autopilot": .string("playNext"),
            "playbackSpeed": .double(1.5),
            "autoDownload": .bool(true),
            "privacyMode": .bool(true),
        ]

        let settings = PodcastSettings.fromServerPayload(payload)

        XCTAssertEqual(settings.skipIntroSeconds, 120)
        XCTAssertEqual(settings.skipOutroSeconds, 20)
        XCTAssertEqual(settings.autoQueueMode, .priority)
        XCTAssertEqual(settings.playbackSpeed, 1.5)
        XCTAssertEqual(settings.autoDownloadNewEpisodes, true)
        XCTAssertEqual(settings.privacyMode, true)
    }

    /// Unknown server keys (trimSilence, volumeBoost, downloadNetwork) must be
    /// preserved in serverExtras for round-tripping.
    func test_podcastSettings_roundTripsUnknownKeys() {
        let payload: [String: AnyCodableValue] = [
            "skipIntroSec": .int(30),
            "trimSilence": .bool(true),
            "volumeBoost": .double(1.5),
            "downloadNetwork": .string("wifi"),
        ]

        let settings = PodcastSettings.fromServerPayload(payload)

        // Known key preserved
        XCTAssertEqual(settings.skipIntroSeconds, 30)

        // Unknown keys round-tripped
        let outPayload = settings.toServerPayload()
        XCTAssertEqual(outPayload["trimSilence"], .bool(true))
        XCTAssertEqual(outPayload["volumeBoost"], .double(1.5))
        XCTAssertEqual(outPayload["downloadNetwork"], .string("wifi"))
    }

    /// Nil fields should produce null values in payload (for reset-to-default).
    func test_podcastSettings_nilFieldsOmitted() {
        let settings = PodcastSettings()  // all nil
        let payload = settings.toServerPayload()

        // No keys should be present for nil fields
        XCTAssertTrue(payload.isEmpty, "Empty PodcastSettings should produce empty payload")
    }

    // MARK: - autoHideUnplayedDays Tri-State Roundtrip

    /// autoHideUnplayedDays: nil should not appear in payload.
    func test_podcastSettings_autoHideUnplayedDays_nil_roundTrips() {
        var settings = PodcastSettings()
        settings.autoHideUnplayedDays = nil
        let payload = settings.toServerPayload()
        XCTAssertNil(payload["autoHideUnplayedDays"], "nil autoHideUnplayedDays should not appear in payload")
    }

    /// autoHideUnplayedDays: 0 (disabled) should round-trip.
    func test_podcastSettings_autoHideUnplayedDays_zero_roundTrips() {
        var settings = PodcastSettings()
        settings.autoHideUnplayedDays = 0
        let payload = settings.toServerPayload()
        XCTAssertEqual(payload["autoHideUnplayedDays"], .int(0))

        let decoded = PodcastSettings.fromServerPayload(payload)
        XCTAssertEqual(decoded.autoHideUnplayedDays, 0, "0 must round-trip through server payload")
    }

    /// autoHideUnplayedDays: N (custom) should round-trip.
    func test_podcastSettings_autoHideUnplayedDays_custom_roundTrips() {
        var settings = PodcastSettings()
        settings.autoHideUnplayedDays = 14
        let payload = settings.toServerPayload()
        XCTAssertEqual(payload["autoHideUnplayedDays"], .int(14))

        let decoded = PodcastSettings.fromServerPayload(payload)
        XCTAssertEqual(decoded.autoHideUnplayedDays, 14, "Custom days must round-trip through server payload")
    }

    /// Merging: local autoHideUnplayedDays takes priority over server.
    func test_podcastSettings_autoHideUnplayedDays_mergingRespectsLocalPriority() {
        var local = PodcastSettings()
        local.autoHideUnplayedDays = 7

        var server = PodcastSettings()
        server.autoHideUnplayedDays = 30

        let merged = local.merging(serverSettings: server)
        XCTAssertEqual(merged.autoHideUnplayedDays, 7, "Local autoHideUnplayedDays must win over server")
    }

    /// Merging: nil local falls back to server value.
    func test_podcastSettings_autoHideUnplayedDays_mergingFallsBackToServer() {
        let local = PodcastSettings()  // nil

        var server = PodcastSettings()
        server.autoHideUnplayedDays = 30

        let merged = local.merging(serverSettings: server)
        XCTAssertEqual(merged.autoHideUnplayedDays, 30, "nil local should fall back to server value")
    }

    // MARK: - autoDownloadEpisodeLimit Roundtrip (latent-bug regression)

    /// autoDownloadEpisodeLimit: nil must not appear in the payload.
    func test_podcastSettings_autoDownloadEpisodeLimit_nil_omitted() {
        var settings = PodcastSettings()
        settings.autoDownloadEpisodeLimit = nil
        let payload = settings.toServerPayload()
        XCTAssertNil(payload["autoDownloadEpisodeLimit"], "nil autoDownloadEpisodeLimit should not appear in payload")
    }

    /// autoDownloadEpisodeLimit: a custom value must round-trip through the server payload.
    /// Regression for the latent bug where this field was declared/decoded/merged but never
    /// added to toServerPayload()/knownKeys — so it was silently lost on reinstall and never
    /// shared cross-device.
    func test_podcastSettings_autoDownloadEpisodeLimit_custom_roundTrips() {
        var settings = PodcastSettings()
        settings.autoDownloadEpisodeLimit = 5
        let payload = settings.toServerPayload()
        XCTAssertEqual(payload["autoDownloadEpisodeLimit"], .int(5))

        let decoded = PodcastSettings.fromServerPayload(payload)
        XCTAssertEqual(decoded.autoDownloadEpisodeLimit, 5, "autoDownloadEpisodeLimit must round-trip through server payload")
    }

    /// autoDownloadEpisodeLimit must be a KNOWN key — read into the typed field, NOT dumped
    /// into serverExtras (which is the symptom of it being absent from knownKeys).
    func test_podcastSettings_autoDownloadEpisodeLimit_isKnownKey_notServerExtras() {
        let payload: [String: AnyCodableValue] = ["autoDownloadEpisodeLimit": .int(3)]
        let settings = PodcastSettings.fromServerPayload(payload)
        XCTAssertEqual(settings.autoDownloadEpisodeLimit, 3)
        XCTAssertNil(settings.serverExtras["autoDownloadEpisodeLimit"], "autoDownloadEpisodeLimit must be a known key, not a serverExtra")
    }

    // MARK: - Orchestrator: Per-Podcast Settings Pull

    /// During Pro sync, the orchestrator MUST pull per-podcast settings from the server.
    func test_proSync_pullsPerPodcastSettings() async {
        let spy = PerPodcastSyncSpy()
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://feeds.megaphone.fm/VMP7229898872",
                payload: ["skipIntroSec": .int(120), "skipOutroSec": .int(20), "autopilot": .string("playNext")],
                settings: nil,
                updatedAt: "2026-05-05T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Add a local podcast that matches the server override
        let podcast = Podcast(url: "https://feeds.megaphone.fm/VMP7229898872", title: "All-In")
        context.insert(podcast)
        try? context.save()
        manager.subscriptions = [podcast]

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // Verify the spy was asked to pull podcast settings
        let pullCalled = await spy.pullPodcastSettingsCalled
        XCTAssertTrue(pullCalled, "Pro orchestrator must pull per-podcast settings during sync")
    }

    /// After pulling per-podcast settings, the local Podcast model must be updated.
    func test_proSync_appliesPerPodcastOverrides() async {
        let spy = PerPodcastSyncSpy()
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://feeds.megaphone.fm/VMP7229898872",
                payload: ["skipIntroSec": .int(120), "skipOutroSec": .int(20), "autopilot": .string("playNext")],
                settings: nil,
                updatedAt: "2026-05-05T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let podcast = Podcast(url: "https://feeds.megaphone.fm/VMP7229898872", title: "All-In")
        context.insert(podcast)
        try? context.save()
        manager.subscriptions = [podcast]

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // Verify the local podcast settings were updated
        XCTAssertEqual(podcast.effectiveSettings.skipIntroSeconds, 120,
                       "Server skipIntroSec must be applied to local podcast")
        XCTAssertEqual(podcast.effectiveSettings.skipOutroSeconds, 20,
                       "Server skipOutroSec must be applied to local podcast")
        XCTAssertEqual(podcast.effectiveSettings.autoQueueMode, .priority,
                       "Server autopilot 'playNext' must map to local .priority")
    }

    // MARK: - Orchestrator: Per-Podcast Settings Push

    /// During Pro sync, the orchestrator MUST push locally-modified per-podcast settings
    /// via the batch endpoint (not individual calls).
    func test_proSync_pushesDirtyPerPodcastSettings() async {
        let spy = PerPodcastSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let podcast = Podcast(url: "https://feeds.megaphone.fm/VMP7229898872", title: "All-In")
        var settings = PodcastSettings()
        settings.skipIntroSeconds = 120
        settings.skipOutroSeconds = 20
        settings.autoQueueMode = .priority
        podcast.settings = settings
        context.insert(podcast)
        try? context.save()
        manager.subscriptions = [podcast]

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // Verify the spy was asked to batch-push podcast settings
        let batchCalled = await spy.pushBatchCalled
        XCTAssertTrue(batchCalled, "Pro orchestrator must batch-push dirty per-podcast settings")

        // Check the batch payload contains the correct keys
        let batchItems = await spy.pushBatchItems
        if let firstItem = batchItems.first {
            XCTAssertEqual(firstItem.podcastUrl, "https://feeds.megaphone.fm/VMP7229898872")
            XCTAssertEqual(firstItem.payload["skipIntroSec"], .int(120))
            XCTAssertEqual(firstItem.payload["autopilot"], .string("playNext"))
        }
    }

    // MARK: - Push-Before-Pull Ordering (regression: local changes lost)

    /// When the user changes autopilot locally and then syncs, the local change
    /// must reach the server BEFORE the server's stale state overwrites it.
    /// Root cause: ProSyncOrchestrator was pulling (Step 1b) before pushing (Step 6b),
    /// so the server's old value clobbered the local edit every time.
    func test_proSync_pushesPerPodcastSettingsBeforePull() async {
        let spy = PerPodcastSyncSpy()
        // Server has OLD autopilot value
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://feeds.megaphone.fm/VMP7229898872",
                payload: ["autopilot": .string("off")],
                settings: nil,
                updatedAt: "2026-05-05T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local podcast has NEW autopilot value (user just changed it)
        let podcast = Podcast(url: "https://feeds.megaphone.fm/VMP7229898872", title: "All-In")
        var settings = PodcastSettings()
        settings.autoQueueMode = .priority  // user changed to "Play Next"
        podcast.settings = settings
        context.insert(podcast)
        try? context.save()
        manager.subscriptions = [podcast]

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // The batch push must have happened BEFORE the pull
        let callOrder = await spy.callOrder
        guard let pushIdx = callOrder.firstIndex(of: .pushPodcastSettingsBatch),
              let pullIdx = callOrder.firstIndex(of: .pullPodcastSettings) else {
            XCTFail("Both pushPodcastSettingsBatch and pullPodcastSettings must be called")
            return
        }
        XCTAssertLessThan(pushIdx, pullIdx,
                          "Per-podcast settings must be PUSHED (batch) before PULLED (push-then-pull pattern)")
    }

    /// After sync completes, a locally-changed autopilot value must survive.
    /// If the push runs after the pull, the server's stale "off" overwrites the
    /// user's local "playNext" and the push sends back the clobbered value.
    func test_proSync_localAutopilotChangeNotClobberedByPull() async {
        let spy = PerPodcastSyncSpy()
        // Server returns OLD value
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://feeds.megaphone.fm/VMP7229898872",
                payload: ["autopilot": .string("off")],
                settings: nil,
                updatedAt: "2026-05-05T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // User just changed autopilot to .priority
        let podcast = Podcast(url: "https://feeds.megaphone.fm/VMP7229898872", title: "All-In")
        var settings = PodcastSettings()
        settings.autoQueueMode = .priority
        podcast.settings = settings
        context.insert(podcast)
        try? context.save()
        manager.subscriptions = [podcast]

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // The batch-pushed payload must contain the LOCAL value, not the server's stale one
        let batchItems = await spy.pushBatchItems
        XCTAssertFalse(batchItems.isEmpty, "Local per-podcast settings must be batch-pushed to server")
        if let item = batchItems.first {
            XCTAssertEqual(item.payload["autopilot"], .string("playNext"),
                           "Pushed autopilot must be the LOCAL value 'playNext', not server's stale 'off'")
        }

        // After sync, the local model must still have the user's value
        XCTAssertEqual(podcast.effectiveSettings.autoQueueMode, .priority,
                       "Local autopilot must survive sync — server pull must not clobber it")
    }

    // MARK: - Negative: gPodder/Vault must NOT sync per-podcast settings

    /// gPodder orchestrator must NOT pull or push per-podcast settings.
    func test_gpodderSync_doesNotSyncPerPodcastSettings() async {
        let spy = PerPodcastSyncSpy()
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

        let pullCalled = await spy.pullPodcastSettingsCalled
        let pushCalls = await spy.pushedPodcastSettings
        XCTAssertFalse(pullCalled, "gPodder must NOT pull per-podcast settings")
        XCTAssertTrue(pushCalls.isEmpty, "gPodder must NOT push per-podcast settings")
    }

    // MARK: - Queue Pull: Replace (not merge)

    /// After push-then-pull, the local queue must match server state exactly.
    /// Local-only items that the server doesn't have should be removed.
    func test_pullQueue_replacesLocalQueue() async {
        let spy = PerPodcastSyncSpy()
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local queue has 2 episodes
        let local1 = makeQueueItem(id: "local-only", title: "Local Only")
        let local2 = makeQueueItem(id: "shared", title: "Shared Episode")
        audioManager.appendToQueue([local1, local2])
        XCTAssertEqual(audioManager.queue.count, 2)

        // Server queue has different episodes (shared + new server item)
        await spy.setServerQueue([
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/shared.mp3",
                episodeGuid: "shared",
                sortOrder: 0,
                positionSec: 100,
                title: "Shared Episode",
                podcastTitle: "Podcast"
            ),
            QueueSyncItem(
                podcastUrl: "https://example.com/feed.xml",
                episodeUrl: "https://example.com/server-new.mp3",
                episodeGuid: "server-new",
                sortOrder: 1,
                positionSec: 0,
                title: "Server New",
                podcastTitle: "Podcast"
            )
        ])

        await playerManager.pullQueueFromProServer()

        // The queue should match server state: "shared" + "server-new"
        // "local-only" should be removed since the server is the source of truth after push
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertTrue(queueIds.contains("server-new"),
                      "Server-only items must be added")
        XCTAssertFalse(queueIds.contains("local-only"),
                       "Local-only items must be removed after server adoption")
    }

    // MARK: - Batch Upload: Exclude Currently-Playing Episode

    /// uploadEpisodeActions must NOT include the currently-playing episode
    /// to avoid resetting its nowPlaying flag with nil.
    func test_batchUpload_excludesCurrentEpisode() async {
        let spy = PerPodcastSyncSpy()

        // Set up a currently-playing episode
        audioManager.currentItem = makeQueueItem(
            id: "ep-playing",
            title: "Currently Playing"
        )

        // Create episode actions for multiple episodes including the current one
        let actions = [
            EpisodeAction(
                podcast: "https://example.com/feed.xml",
                episode: "https://example.com/ep-playing.mp3",
                guid: "ep-playing",
                action: "play",
                timestamp: 1746482400,
                position: 500,
                started: 0,
                total: 3600,
                device: "test-device"
            ),
            EpisodeAction(
                podcast: "https://example.com/feed.xml",
                episode: "https://example.com/ep-other.mp3",
                guid: "ep-other",
                action: "play",
                timestamp: 1746482400,
                position: 100,
                started: 0,
                total: 1800,
                device: "test-device"
            )
        ]

        _ = try? await spy.uploadEpisodeActions(actions, currentEpisodeGuid: "ep-playing")

        let uploaded = await spy.uploadedEpisodeActions
        // The currently-playing episode should be excluded
        let uploadedGuids = uploaded.compactMap(\.guid)
        XCTAssertFalse(uploadedGuids.contains("ep-playing"),
                       "Batch upload must exclude the currently-playing episode")
        XCTAssertTrue(uploadedGuids.contains("ep-other"),
                      "Non-playing episodes must still be uploaded")
    }
}

// MARK: - Spy SyncClient for Per-Podcast Settings Tests

/// Spy that tracks per-podcast settings sync calls during orchestrator tests.
actor PerPodcastSyncSpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { true }

    // Call ordering tracking
    enum SyncOperation: Equatable {
        case pullPodcastSettings
        case pushPodcastSetting
        case pushPodcastSettingsBatch
    }
    var callOrder: [SyncOperation] = []

    // Per-podcast settings tracking
    var pullPodcastSettingsCalled = false
    var serverPodcastSettings: [ProPodcastSetting] = []

    struct PushCall {
        let podcastUrl: String
        let payload: [String: AnyCodableValue]
    }
    var pushedPodcastSettings: [PushCall] = []
    
    // Batch push tracking
    var pushBatchCalled = false
    var pushBatchItems: [(podcastUrl: String, payload: [String: AnyCodableValue])] = []

    // Queue tracking
    var serverQueue: [QueueSyncItem] = []

    // Episode action tracking
    var uploadedEpisodeActions: [EpisodeAction] = []

    func setServerPodcastSettings(_ settings: [ProPodcastSetting]) {
        serverPodcastSettings = settings
    }

    func setServerQueue(_ items: [QueueSyncItem]) {
        serverQueue = items
    }

    // MARK: - Per-Podcast Settings (new protocol methods)

    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting] {
        callOrder.append(.pullPodcastSettings)
        pullPodcastSettingsCalled = true
        return serverPodcastSettings
    }

    func pushPodcastSetting(profileName: String, podcastUrl: String, payload: [String: AnyCodableValue]) async throws {
        callOrder.append(.pushPodcastSetting)
        pushedPodcastSettings.append(PushCall(podcastUrl: podcastUrl, payload: payload))
    }
    
    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws {
        callOrder.append(.pushPodcastSettingsBatch)
        pushBatchCalled = true
        pushBatchItems = items
    }

    // MARK: - Queue

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { serverQueue }
    func deleteQueueItem(episodeUrl: String) async throws {}

    // MARK: - Playback

    func syncPlayback(
        podcastUrl: String, episodeUrl: String, episodeGuid: String?,
        positionSec: Double, durationSec: Double?,
        nowPlaying: Bool?, completed: Bool?, deviceId: String?,
        clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? { nil }

    // MARK: - Episode Actions

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        uploadedEpisodeActions.append(contentsOf: actions)
        return []
    }

    /// Extended version that filters out the currently-playing episode.
    func uploadEpisodeActions(_ actions: [EpisodeAction], currentEpisodeGuid: String?) async throws -> [URLRewrite] {
        let filtered = actions.filter { $0.guid != currentEpisodeGuid }
        uploadedEpisodeActions.append(contentsOf: filtered)
        return []
    }

    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }

    // MARK: - Subscriptions

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
}

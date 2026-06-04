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
    /// Pro sync must push profile settings to the server.
    func test_pro_pushesProfileSettings() async {
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
    var uploadEpisodeActionsCalled = false
    var pushSubscriptionsCalled = false
    var pullSubscriptionsCalled = false
    var patchProfileSettingsCalled = false
    var getProfileSettingsCalled = false
    var pushStatsEventsCalled = false
    var lastPatchProfilePayload: [String: AnyCodableValue]?
    private var profileSettingsResponse: ProProfileSettings?

    func setProfileSettingsResponse(_ response: ProProfileSettings) {
        profileSettingsResponse = response
    }

    // MARK: - Global Profile Settings

    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws {
        patchProfileSettingsCalled = true
        lastPatchProfilePayload = payload
    }

    func getProfileSettings(profileName: String) async throws -> ProProfileSettings? {
        getProfileSettingsCalled = true
        return profileSettingsResponse
    }

    // MARK: - Queue

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        return QueueSyncResult(items: items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        getQueueCalled = true
        return []
    }

    // MARK: - Subscriptions

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        pushSubscriptionsCalled = true
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        pullSubscriptionsCalled = true
        return SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    // MARK: - Episode Actions

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        uploadEpisodeActionsCalled = true
        return []
    }

    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        getEpisodeActionsCalled = true
        return []
    }
}

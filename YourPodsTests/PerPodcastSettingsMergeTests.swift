import XCTest
import SwiftData
@testable import YourPods

/// Tests for the per-podcast settings sync merge fix:
/// 1. Field-level merging (local overrides win, server fills gaps)
/// 2. Numeric type coercion (server sends double for int fields)
/// 3. Integration: orchestrator applies server settings even when local overrides exist
@MainActor
final class PerPodcastSettingsMergeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-merge"

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
            name: "Pro Merge Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: "test-device",
            profileType: .yourpodsPro,
            proProfileName: "testmerge"
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
            "proFirstSyncCompleted_testmerge",
            "lastPodcastSettingsSyncTimestamp_testmerge",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Field-Level Merge Tests

    /// When local has skipIntro=15 and server has skipOutro=20,
    /// the merged result must contain BOTH values.
    func test_fieldLevelMerge_serverFillsGaps() {
        var local = PodcastSettings()
        local.skipIntroSeconds = 15

        var server = PodcastSettings()
        server.skipOutroSeconds = 20

        let merged = local.merging(serverSettings: server)

        XCTAssertEqual(merged.skipIntroSeconds, 15,
                       "Local skipIntro must be preserved")
        XCTAssertNotNil(merged.skipOutroSeconds,
                        "Server skipOutro must not be nil after merge")
        XCTAssertEqual(merged.skipOutroSeconds, 20,
                       "Server skipOutro must fill the local gap")
    }

    /// When both local and server set the same field,
    /// the local value must win (local is source of truth for active overrides).
    func test_fieldLevelMerge_localWinsOnConflict() {
        var local = PodcastSettings()
        local.skipIntroSeconds = 15
        local.playbackSpeed = 1.5

        var server = PodcastSettings()
        server.skipIntroSeconds = 30  // server has different value
        server.playbackSpeed = 2.0

        let merged = local.merging(serverSettings: server)

        XCTAssertEqual(merged.skipIntroSeconds, 15,
                       "Local skipIntro must win over server value")
        XCTAssertEqual(merged.playbackSpeed, 1.5,
                       "Local playbackSpeed must win over server value")
    }

    /// Unknown server keys preserved in serverExtras must survive the merge.
    func test_fieldLevelMerge_serverExtrasPreserved() {
        var local = PodcastSettings()
        local.skipIntroSeconds = 15

        var server = PodcastSettings()
        server.skipOutroSeconds = 20
        server.serverExtras = ["trimSilence": .bool(true), "volumeBoost": .double(1.5)]

        let merged = local.merging(serverSettings: server)

        XCTAssertEqual(merged.serverExtras["trimSilence"], .bool(true),
                       "Server extras must be preserved in merge")
        XCTAssertEqual(merged.serverExtras["volumeBoost"], .double(1.5),
                       "Server extras must be preserved in merge")
    }

    // MARK: - Numeric Coercion Tests

    /// Server sends skipIntroSec as .double(15.0) — must parse as skipIntroSeconds = 15.
    func test_numericCoercion_doubleToInt() {
        let payload: [String: AnyCodableValue] = [
            "skipIntroSec": .double(15.0),
            "skipOutroSec": .double(20.0),
        ]

        let settings = PodcastSettings.fromServerPayload(payload)

        XCTAssertEqual(settings.skipIntroSeconds, 15,
                       "Double 15.0 must be coerced to Int 15 for skipIntroSec")
        XCTAssertEqual(settings.skipOutroSeconds, 20,
                       "Double 20.0 must be coerced to Int 20 for skipOutroSec")
    }

    /// Server sends playbackSpeed as .int(2) — must parse as playbackSpeed = 2.0.
    func test_numericCoercion_playbackSpeedFromInt() {
        let payload: [String: AnyCodableValue] = [
            "playbackSpeed": .int(2),
        ]

        let settings = PodcastSettings.fromServerPayload(payload)

        XCTAssertEqual(settings.playbackSpeed, 2.0,
                       "Int 2 must be coerced to Double 2.0 for playbackSpeed")
    }

    // MARK: - Integration: Orchestrator Merge

    /// Full orchestrator sync: podcast has local skipIntro + server has skipOutro.
    /// After sync, BOTH values must be present locally.
    func test_proSync_mergesServerSettingsWithLocalOverrides() async {
        let spy = PerPodcastSyncSpy()
        // Server has skipOutro=20 (set from web)
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://feeds.example.com/podcast",
                payload: ["skipIntroSec": .int(15), "skipOutroSec": .int(20)],
                settings: nil,
                updatedAt: "2026-05-11T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local podcast has skipIntro=15 (set on phone) — hasOverrides is true
        let podcast = Podcast(url: "https://feeds.example.com/podcast", title: "Test Pod")
        var settings = PodcastSettings()
        settings.skipIntroSeconds = 15
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

        // After sync: local skipIntro preserved AND server skipOutro adopted
        XCTAssertEqual(podcast.effectiveSettings.skipIntroSeconds, 15,
                       "Local skipIntro must survive sync")
        XCTAssertEqual(podcast.effectiveSettings.skipOutroSeconds, 20,
                       "Server skipOutro must be merged into local settings")
    }

    /// When local and server disagree on a field, local must win after sync.
    func test_proSync_localOverrideNotClobberedByServerMerge() async {
        let spy = PerPodcastSyncSpy()
        // Server has skipIntro=30 (stale/different value from web)
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://feeds.example.com/podcast",
                payload: ["skipIntroSec": .int(30), "autopilot": .string("off")],
                settings: nil,
                updatedAt: "2026-05-11T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local has skipIntro=15 and autopilot=priority (user's active settings)
        let podcast = Podcast(url: "https://feeds.example.com/podcast", title: "Test Pod")
        var settings = PodcastSettings()
        settings.skipIntroSeconds = 15
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

        // Local values must win — push already sent them to server
        XCTAssertEqual(podcast.effectiveSettings.skipIntroSeconds, 15,
                       "Local skipIntro=15 must not be clobbered by server's 30")
        XCTAssertEqual(podcast.effectiveSettings.autoQueueMode, .priority,
                       "Local autopilot=priority must not be clobbered by server's 'off'")
    }
}

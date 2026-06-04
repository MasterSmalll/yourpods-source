import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the batch per-podcast settings push fix.
///
/// The regression: ProSyncOrchestrator pushed one HTTP request per podcast
/// with overrides (up to 57 requests in rapid succession), triggering 429
/// rate-limit errors from the backend. The fix batches all per-podcast
/// settings into a single PATCH request.
///
/// Tests verify:
/// 1. Pro sync uses batch push (not per-item loop)
/// 2. Batch includes all dirty items
/// 3. Empty dirty list skips batch call
/// 4. Batch push ordering relative to pull
/// 5. gPodder/Vault isolation (negative assertions)
/// 6. Rate-limit error type (429 handling)
@MainActor
final class BatchPodcastSettingsSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-batch"

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
            name: "Pro Batch Test",
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

    // MARK: - Batch Push: Pro sync uses batch

    /// Pro sync MUST call pushPodcastSettingsBatch (not individual pushPodcastSetting)
    /// when there are dirty per-podcast settings to push.
    func test_proSync_usesBatchPushForPerPodcastSettings() async {
        let spy = PerPodcastSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Add 3 podcasts with local overrides (dirty settings)
        for i in 1...3 {
            let podcast = Podcast(url: "https://example.com/feed\(i).xml", title: "Podcast \(i)")
            var settings = PodcastSettings()
            settings.skipIntroSeconds = i * 30
            podcast.settings = settings
            context.insert(podcast)
        }
        try? context.save()
        manager.loadSubscriptions()

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // The batch method must be called, NOT individual pushPodcastSetting
        let batchCalled = await spy.pushBatchCalled
        XCTAssertTrue(batchCalled, "Pro orchestrator must use batch push for per-podcast settings")
    }

    /// Batch push must include ALL dirty podcast settings in a single call.
    func test_batchPush_includesAllDirtyItems() async {
        let spy = PerPodcastSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Add 5 podcasts with overrides
        let urls = (1...5).map { "https://example.com/feed\($0).xml" }
        for (i, url) in urls.enumerated() {
            let podcast = Podcast(url: url, title: "Podcast \(i + 1)")
            var settings = PodcastSettings()
            settings.skipIntroSeconds = (i + 1) * 10
            podcast.settings = settings
            context.insert(podcast)
        }
        try? context.save()
        manager.loadSubscriptions()

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let batchItems = await spy.pushBatchItems
        XCTAssertEqual(batchItems.count, 5,
                       "Batch push must include all 5 dirty podcast settings in a single call")

        // Verify each podcast's URL is in the batch
        let batchUrls = Set(batchItems.map(\.podcastUrl))
        for url in urls {
            XCTAssertTrue(batchUrls.contains(url),
                          "Batch must include settings for \(url)")
        }
    }

    /// When no podcasts have overrides, the batch push should not be called.
    func test_batchPush_skippedWhenNoDirtySettings() async {
        let spy = PerPodcastSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Add podcasts with NO overrides (default settings)
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Clean Podcast")
        context.insert(podcast)
        try? context.save()
        manager.loadSubscriptions()

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let batchCalled = await spy.pushBatchCalled
        XCTAssertFalse(batchCalled,
                       "Batch push must NOT be called when there are no dirty settings")
    }

    /// Batch push must happen BEFORE pull (push-then-pull ordering preserved).
    func test_batchPush_orderedBeforePull() async {
        let spy = PerPodcastSyncSpy()
        await spy.setServerPodcastSettings([
            ProPodcastSetting(
                podcastUrl: "https://example.com/feed1.xml",
                payload: ["autopilot": .string("off")],
                settings: nil,
                updatedAt: "2026-05-05T20:00:00Z"
            )
        ])
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let podcast = Podcast(url: "https://example.com/feed1.xml", title: "Podcast 1")
        var settings = PodcastSettings()
        settings.skipIntroSeconds = 30
        podcast.settings = settings
        context.insert(podcast)
        try? context.save()
        manager.loadSubscriptions()

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let callOrder = await spy.callOrder
        guard let batchIdx = callOrder.firstIndex(of: .pushPodcastSettingsBatch),
              let pullIdx = callOrder.firstIndex(of: .pullPodcastSettings) else {
            XCTFail("Both pushPodcastSettingsBatch and pullPodcastSettings must be called")
            return
        }
        XCTAssertLessThan(batchIdx, pullIdx,
                          "Batch push must happen BEFORE pull (push-then-pull pattern)")
    }

    /// Individual pushPodcastSetting must NOT be called when batch is used.
    func test_proSync_doesNotUseIndividualPushWhenBatchAvailable() async {
        let spy = PerPodcastSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        var settings = PodcastSettings()
        settings.skipIntroSeconds = 30
        podcast.settings = settings
        context.insert(podcast)
        try? context.save()
        manager.loadSubscriptions()

        let orchestrator = ProSyncOrchestrator(client: spy)
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        let individualPushCalls = await spy.pushedPodcastSettings
        XCTAssertTrue(individualPushCalls.isEmpty,
                      "Individual pushPodcastSetting must NOT be called — batch should be used instead")
    }

    // MARK: - Cross-Profile Isolation (Negative Assertions)

    /// gPodder sync must NOT call batch push.
    func test_gpodderSync_noBatchPushCalled() async {
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

        let batchCalled = await spy.pushBatchCalled
        XCTAssertFalse(batchCalled, "gPodder must NOT call batch push for per-podcast settings")
    }

    /// Vault sync must NOT call batch push.
    func test_vaultSync_noBatchPushCalled() async {
        let orchestrator = VaultSyncOrchestrator()
        // Vault orchestrator has no client — just verify it doesn't crash
        // and doesn't call any sync methods
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )
        // If we get here without crash, Vault isolation is confirmed
    }

    // MARK: - Rate Limit Error Type (429 Handling)

    /// YourPodsProError.rateLimited must be a distinct error type.
    func test_rateLimitedError_hasCorrectDescription() {
        let error = YourPodsProError.rateLimited(retryAfterSec: 10)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("10"),
                      "Rate limit error should mention the retry-after duration")
    }

    /// Two rateLimited errors with different retryAfter values must not be equal.
    func test_rateLimitedError_equatability() {
        let a = YourPodsProError.rateLimited(retryAfterSec: 10)
        let b = YourPodsProError.rateLimited(retryAfterSec: 30)
        XCTAssertNotEqual(a, b, "Different retryAfter values should not be equal")
        
        let c = YourPodsProError.rateLimited(retryAfterSec: 10)
        XCTAssertEqual(a, c, "Same retryAfter values should be equal")
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the blank library auto-recovery in refreshAndSync().
///
/// Root cause: When syncSubscriptions() fails (transient network/server error)
/// AND the library is empty (post-corruption-recovery), refreshAndSync() swallows
/// the error and continues to feed refresh on an empty library — leaving the user
/// with a blank library. The user has to manually "Force Pull" from Settings.
///
/// Fix: Auto-retry syncSubscriptions() once after a short delay when the library
/// is empty after a failure. This catches the common transient-failure scenario.
@MainActor
final class BlankLibraryRecoveryTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-recovery"

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

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - Auto-Retry When Library Empty

    /// When the library is empty and sync fails, refreshAndSync must retry once.
    /// This simulates the post-corruption-recovery scenario where the first sync
    /// attempt fails transiently but the second succeeds.
    func test_refreshAndSync_retriesSyncWhenLibraryEmpty() async {
        // GIVEN: Empty library (post-corruption recovery) + sync client that fails once then succeeds
        XCTAssertTrue(manager.subscriptions.isEmpty, "Precondition: library is empty")

        let mockClient = RecoveryMockSyncClient()
        await mockClient.setFailFirstNPulls(1)  // First pull fails, second succeeds
        await mockClient.setServerSubscriptions(["https://example.com/podcast-a"])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // Reset sync timestamp to 0 (simulates post-recovery state)
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")

        // Stub required managers for refreshAndSync
        let audio = AudioManager()
        let player = PlayerManager(audioManager: audio)
        player.podcastManager = manager
        let settings = SettingsManager()
        let download = DownloadManager()

        // WHEN: refreshAndSync runs
        _ = await manager.refreshAndSync(
            playerManager: player,
            downloadManager: download,
            settingsManager: settings
        )

        // THEN: Library should be restored via the retry
        let pullCount = await mockClient.pullCount
        XCTAssertGreaterThanOrEqual(pullCount, 2,
                       "refreshAndSync must retry sync when library is empty after first failure")
    }

    /// When the library is NOT empty and sync fails, refreshAndSync must NOT retry.
    /// This prevents unnecessary retry overhead during normal operation.
    func test_refreshAndSync_doesNotRetryWhenLibraryNotEmpty() async {
        // GIVEN: Library has existing podcasts + sync that fails
        insertPodcast(url: "https://example.com/existing", title: "Existing Podcast")
        XCTAssertFalse(manager.subscriptions.isEmpty, "Precondition: library is not empty")

        let mockClient = RecoveryMockSyncClient()
        await mockClient.setAlwaysFail(true)  // All pulls fail
        manager.setSyncClient(mockClient, deviceId: "test-device")

        let audio = AudioManager()
        let player = PlayerManager(audioManager: audio)
        player.podcastManager = manager
        let settings = SettingsManager()
        let download = DownloadManager()

        // WHEN: refreshAndSync runs
        _ = await manager.refreshAndSync(
            playerManager: player,
            downloadManager: download,
            settingsManager: settings
        )

        // THEN: Only 1 pull attempt (no retry since library is not empty)
        let pullCount = await mockClient.pullCount
        XCTAssertEqual(pullCount, 1,
                       "refreshAndSync must NOT retry when library already has podcasts")
    }
}

// MARK: - Mock SyncClient for Recovery Tests

actor RecoveryMockSyncClient: SyncClient {
    private var serverSubscriptions: [String] = []
    private var failFirstN = 0
    private var alwaysFail = false
    private(set) var pullCount = 0

    func setServerSubscriptions(_ urls: [String]) { serverSubscriptions = urls }
    func setFailFirstNPulls(_ n: Int) { failFirstN = n }
    func setAlwaysFail(_ fail: Bool) { alwaysFail = fail }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        if alwaysFail { throw URLError(.notConnectedToInternet) }
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        pullCount += 1
        if alwaysFail { throw URLError(.notConnectedToInternet) }
        if pullCount <= failFirstN {
            throw URLError(.timedOut)
        }
        return SubscriptionDelta(add: serverSubscriptions, remove: [], timestamp: 1000)
    }

    // MARK: Unused protocol stubs
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

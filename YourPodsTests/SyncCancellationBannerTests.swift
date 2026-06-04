import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for suppressing the "Sync Error" banner when sync is cancelled
/// due to an expected app lifecycle transition (foreground → background).
///
/// Root cause: `foregroundSyncTask?.cancel()` in `scenePhase == .background`
/// propagates to in-flight URLSession calls, which throw `URLError(.cancelled)`.
/// The error flows through `translateNetworkError` → `connectionFailed` →
/// `lastSyncError` → red banner visible to the user. The cancellation is an
/// expected lifecycle event, not a real connectivity failure.
///
/// Fix: Detect task cancellation and suppress the error banner.
@MainActor
final class SyncCancellationBannerTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-cancel-banner"

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
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - translateNetworkError must classify URLError.cancelled

    /// When a URLSession task is cancelled (code -999), translateNetworkError must
    /// produce a `.requestCancelled` error, NOT a `.connectionFailed` error.
    /// The cancelled error code means the Task was cancelled by the app — not that
    /// the network is unreachable.
    func test_translateNetworkError_classifiesCancelledAsRequestCancelled() async {
        let client = YourPodsProClient(
            baseUrl: "https://sync.yourpods.app",
            authProvider: StubAuthProvider()
        )
        let cancelledError = URLError(.cancelled)

        let translated = await client.testTranslateNetworkError(cancelledError, path: "/test")

        // The error should be .requestCancelled, not .connectionFailed
        switch translated {
        case .requestCancelled:
            break  // ✅ Expected
        default:
            XCTFail("Expected .requestCancelled, got: \(translated)")
        }
    }

    /// URLError.cancelled's errorDescription should NOT contain "Could not connect"
    /// since it's not a connectivity issue.
    func test_requestCancelled_errorDescription_doesNotMentionConnectivity() {
        let error = YourPodsProError.requestCancelled
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.contains("Could not connect"),
                       "Cancelled errors must not claim connectivity failure — got: \(description)")
    }

    // MARK: - syncSubscriptionsWithRecovery suppresses cancellation

    /// When subscription sync throws URLError.cancelled (because the foreground task
    /// was cancelled on backgrounding), lastSyncError must NOT be set.
    /// The user should not see a red "Sync Error" banner for an expected lifecycle event.
    func test_syncSubscriptionsWithRecovery_doesNotSetLastSyncError_onCancellation() async {
        let spy = CancellingSubscriptionSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        _ = await manager.syncSubscriptionsWithRecovery()

        XCTAssertNil(manager.lastSyncError,
                     "lastSyncError must be nil when sync was cancelled — the banner should not appear")
    }

    /// When subscription sync throws a REAL error (e.g. .connectionFailed),
    /// lastSyncError MUST still be set — we don't want to suppress real errors.
    func test_syncSubscriptionsWithRecovery_setsLastSyncError_onRealError() async {
        let spy = FailingSubscriptionSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        _ = await manager.syncSubscriptionsWithRecovery()

        XCTAssertNotNil(manager.lastSyncError,
                        "lastSyncError must be set for real errors — only cancellations are suppressed")
    }

    // MARK: - GPodderSyncOrchestrator suppresses cancellation in episode action catch

    /// When episode action sync throws due to cancellation in the gPodder orchestrator,
    /// lastSyncError must NOT be set.
    func test_gPodderOrchestrator_doesNotSetLastSyncError_onCancelledEpisodeActions() async {
        let spy = CancellingEpisodeActionSpy()
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

        XCTAssertNil(manager.lastSyncError,
                     "gPodder orchestrator must not surface cancelled errors in the banner")
    }

    // MARK: - ProSyncOrchestrator suppresses cancellation in episode action catch

    /// When episode action sync throws due to cancellation in the Pro orchestrator,
    /// lastSyncError must NOT be set.
    func test_proOrchestrator_doesNotSetLastSyncError_onCancelledEpisodeActions() async {
        let spy = CancellingEpisodeActionSpy()
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

        XCTAssertNil(manager.lastSyncError,
                     "Pro orchestrator must not surface cancelled errors in the banner")
    }

    // MARK: - End-to-end: foreground task cancellation does not produce banner

    /// Simulates the real scenario: a foreground sync task is cancelled mid-flight.
    /// The subscription sync throws URLError.cancelled. The banner must not appear.
    func test_refreshAndSync_inCancelledTask_doesNotSetLastSyncError() async {
        let spy = CancellingSubscriptionSpy()
        manager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Simulate: start sync in a task and cancel it (like foregroundSyncTask?.cancel())
        let task = Task {
            _ = await manager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager
            )
        }
        // Give the task a moment to start, then cancel
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        _ = await task.value

        XCTAssertNil(manager.lastSyncError,
                     "Cancelling the foreground sync task must not produce a user-visible error banner")
    }
}

// MARK: - Stub AuthProvider for tests

private actor StubAuthProvider: AuthProvider {
    func signIn(email: String, password: String) async throws -> String { "test-token" }
    func createUser(email: String, password: String) async throws -> String { "test-token" }
    func getValidToken() async throws -> String { "test-token" }
    func signOut() async {}
    var isAuthenticated: Bool { true }
    var currentUserEmail: String? { "test@test.com" }
}

// MARK: - Spy: Subscription sync throws URLError.cancelled

/// Simulates a sync client whose subscription pull throws URLError.cancelled,
/// as happens when the foreground task is cancelled on backgrounding.
private actor CancellingSubscriptionSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        throw URLError(.cancelled)
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

// MARK: - Spy: Subscription sync throws a real connection error

/// Simulates a sync client whose subscription pull throws a real connection error.
/// Used to verify that genuine errors ARE still surfaced in the banner.
private actor FailingSubscriptionSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        throw URLError(.notConnectedToInternet)
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

// MARK: - Spy: Episode action sync throws URLError.cancelled

/// Simulates a sync client where episode action upload/get throws cancelled.
/// Subscription sync succeeds, but episode action sync fails with cancellation.
private actor CancellingEpisodeActionSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        throw URLError(.cancelled)
    }

    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        throw URLError(.cancelled)
    }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

import XCTest
import SwiftData
@testable import YourPods

/// Tests for cancellation gates on the sync write pipeline.
///
/// Root cause (0xDEAD10CC crash class): lifecycle handlers (BGTask expiration,
/// scenePhase .background, foreground-sync assertion expiration) cancel their
/// Tasks, but cancellation never reached the sync pipeline — and even where it
/// did, write transactions (rawWriteProbe, safeSave) ran BEFORE the first
/// Task.isCancelled check. The app kept opening SQLite write transactions
/// after its background-execution assertion ended, and iOS killed it mid-write.
///
/// Contracts:
/// 1. applyEpisodeActionsCore checks cancellation BEFORE the write probe.
/// 2. applyHiddenChanges skips probe + save when cancelled.
/// 3. refreshAndSync propagates caller cancellation into its inner sync task.
/// 4. Orchestrators stop at step boundaries once cancelled (no further
///    client calls / write-bearing steps).
@MainActor
final class SyncWriteCancellationGateTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var savedGuard: SuspensionGuard!

    override func setUp() {
        super.setUp()
        savedGuard = SuspensionGuard.shared
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        SuspensionGuard.shared = savedGuard
        savedGuard = nil
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    /// Install a recorder as the shared SuspensionGuard and return its event log.
    /// Any probe or save that runs afterwards appends begin:/end: events.
    private func installWriteRecorder() -> () -> [String] {
        let box = EventBox()
        SuspensionGuard.shared = SuspensionGuard(acquire: { name in
            box.events.append("begin:\(name)")
            return { box.events.append("end:\(name)") }
        })
        return { box.events }
    }

    private func makePlayerManager() -> PlayerManager {
        let playerManager = PlayerManager(audioManager: AudioManager())
        playerManager.podcastManager = manager
        return playerManager
    }

    // MARK: - Contract 1: probe runs only after the cancellation check

    /// A cancelled task must NOT open the raw write probe (4 SQLite write
    /// transactions) on its way out. This was the exact shape of the production
    /// crash: post-expiration sync reached the probe before any isCancelled check.
    func test_applyEpisodeActionsCore_skipsProbe_whenCancelled() async {
        var probeCount = 0
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: {
                probeCount += 1
                return true
            }
        )

        let task = Task {
            await svc.applyEpisodeActionsWithStatsAsync()
        }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(probeCount, 0,
                       "A cancelled apply must not run the write probe — cancellation check must precede storeHealthCheck")
    }

    // MARK: - Contract 2: applyHiddenChanges gates on cancellation

    /// When cancelled, applyHiddenChanges must still record the in-memory
    /// hidden state (cheap, no SQLite locks) but skip the probe and the save.
    func test_applyHiddenChanges_skipsProbeAndSave_whenCancelled() async {
        var probeCount = 0
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: {
                probeCount += 1
                return true
            }
        )

        let task = Task {
            svc.applyHiddenChanges([HiddenStateChange(guid: "ep-1", hidden: true)])
        }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(probeCount, 0,
                       "A cancelled applyHiddenChanges must not run the write probe or save")
        XCTAssertTrue(svc.isHidden(guid: "ep-1"),
                      "In-memory hidden state must still be recorded — it is re-saved on the next sync")
    }

    // MARK: - Contract 3: refreshAndSync propagates cancellation

    /// Cancelling the task that awaits refreshAndSync must cancel the inner
    /// single-flight sync task. Without propagation, BGTask expiration and
    /// scenePhase cancellation are no-ops: the pipeline keeps writing after
    /// the background-execution assertion has ended.
    func test_refreshAndSync_propagatesCancellationToInnerSyncTask() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        manager.setSyncClient(client, deviceId: "test-device")

        let playerManager = makePlayerManager()
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let start = Date()
        let outer = Task {
            _ = await manager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager
            )
        }
        // Let the sync start and block inside the client, then cancel the caller.
        try? await Task.sleep(nanoseconds: 200_000_000)
        outer.cancel()
        _ = await outer.value

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0,
                          "refreshAndSync must return promptly after caller cancellation — cancellation must propagate into the inner sync task (took \(elapsed)s)")
    }

    // MARK: - Contract 4: orchestrators stop at step boundaries

    /// Once cancelled, the Pro orchestrator must not proceed to episode action
    /// sync (a write-bearing step) — no further client calls after cancellation.
    func test_proSync_stopsBeforeEpisodeActions_afterCancellation() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        manager.setSyncClient(client, deviceId: "test-device")

        let orchestrator = ProSyncOrchestrator(client: client)
        let playerManager = makePlayerManager()
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let task = Task {
            _ = await orchestrator.sync(
                podcastManager: manager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: .serverWins
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value

        let calls = await client.recordedCalls
        XCTAssertFalse(calls.contains("getEpisodeActions"),
                       "Pro sync must stop at the next step boundary after cancellation — episode action sync still ran (calls: \(calls))")
        XCTAssertFalse(calls.contains("uploadEpisodeActions"),
                       "Pro sync must not upload episode actions after cancellation")
    }

    // MARK: - Contract 5: lifecycle can cancel the shared pipeline

    /// View-initiated refreshAndSync (pull-to-refresh, Home buttons) is not
    /// reachable by any existing lifecycle cancel — the .background handler
    /// must be able to stop the shared pipeline via cancelActiveSync().
    func test_cancelActiveSync_stopsInFlightPipeline() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        manager.setSyncClient(client, deviceId: "test-device")

        let playerManager = makePlayerManager()
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let start = Date()
        let outer = Task {
            _ = await manager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        manager.cancelActiveSync()
        _ = await outer.value

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0,
                          "cancelActiveSync must stop the in-flight shared sync pipeline (took \(elapsed)s)")
    }

    // MARK: - Contract 6: step bodies gate writes on cancellation at entry

    /// A cancelled refreshAllFeeds must not fetch, apply, or save — the
    /// orchestrator gates run BETWEEN steps; the step body must protect itself
    /// when cancellation lands during the preceding await.
    func test_refreshAllFeeds_performsNoWrites_whenCancelled() async {
        UserDefaults.standard.set("test-profile-gate", forKey: "activeProfileId")
        defer {
            UserDefaults.standard.removeObject(forKey: "activeProfileId")
            UserDefaults.standard.removeObject(forKey: "subscriptionUrls_test-profile-gate")
        }

        let podcast = Podcast(url: "https://invalid.invalid/feed", title: "Test Pod")
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: podcast.url)
        manager.loadSubscriptions()
        XCTAssertFalse(manager.subscriptions.isEmpty, "Precondition: refreshAllFeeds must have a feed to refresh")

        let events = installWriteRecorder()

        let task = Task {
            await manager.refreshAllFeeds()
        }
        task.cancel()
        let newEpisodes = await task.value

        XCTAssertTrue(newEpisodes.isEmpty, "Cancelled refresh must return no episodes")
        XCTAssertTrue(events().isEmpty,
                      "Cancelled refreshAllFeeds must not run the probe or save (events: \(events()))")
    }

    /// A syncSubscriptions whose task is cancelled right after the server pull
    /// must not delete podcasts or save on its way out.
    func test_syncSubscriptions_performsNoWrites_whenCancelledAfterPull() async {
        let cancelBox = CancelBox()
        let client = CancelOnPullSyncClient {
            cancelBox.task?.cancel()
        }
        manager.setSyncClient(client, deviceId: "test-device")

        let events = installWriteRecorder()

        cancelBox.task = Task {
            _ = try? await manager.syncSubscriptions()
        }
        _ = await cancelBox.task?.value

        XCTAssertTrue(events().isEmpty,
                      "syncSubscriptions must not probe/save after cancellation lands mid-step (events: \(events()))")
    }

    // MARK: - Contract 7: login sync is cancellable

    /// setSyncClient fires an initial playback-state sync on every wire-up —
    /// including cold launches from BGAppRefreshTask. It must be tracked and
    /// cancellable so lifecycle handlers can stop it.
    func test_setSyncClient_loginSync_isCancellable() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        let playerManager = makePlayerManager()
        manager.playerManager = playerManager

        let start = Date()
        manager.setSyncClient(client, deviceId: "test-device")
        try? await Task.sleep(nanoseconds: 200_000_000)

        playerManager.cancelInFlightPlaybackSync()
        await playerManager.playbackSyncTask?.value

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0,
                          "The login-sync task must be cancellable — it fires on every cold launch including BGTask background launches (took \(elapsed)s)")
    }

    // MARK: - Contract 8: direct sync calls are lifecycle-cancellable

    /// Views call syncEpisodeActions directly from fire-and-forget Tasks
    /// (force pull, onboarding, profile activation, activity refresh) that no
    /// lifecycle hook holds a handle to. The manager must track these so
    /// cancelActiveSync() (scenePhase .background) reaches them.
    func test_cancelActiveSync_stopsDirectSyncEpisodeActions() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        manager.setSyncClient(client, deviceId: "test-device")

        let start = Date()
        let viewTask = Task {
            _ = try? await manager.syncEpisodeActions()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        manager.cancelActiveSync()
        _ = await viewTask.value

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0,
                          "cancelActiveSync must stop a direct syncEpisodeActions call (took \(elapsed)s)")
    }

    /// Same contract for direct syncSubscriptions calls.
    func test_cancelActiveSync_stopsDirectSyncSubscriptions() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        manager.setSyncClient(client, deviceId: "test-device")

        let start = Date()
        let viewTask = Task {
            _ = try? await manager.syncSubscriptions()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        manager.cancelActiveSync()
        _ = await viewTask.value

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4.0,
                          "cancelActiveSync must stop a direct syncSubscriptions call (took \(elapsed)s)")
    }

    /// Parity: the gPodder orchestrator must honor the same step-boundary gates.
    func test_gpodderSync_stopsBeforeEpisodeActions_afterCancellation() async {
        let client = RecordingBlockingSyncClient(blockSeconds: 8)
        manager.setSyncClient(client, deviceId: "test-device")

        let orchestrator = GPodderSyncOrchestrator(client: client)
        let playerManager = makePlayerManager()
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let task = Task {
            _ = await orchestrator.sync(
                podcastManager: manager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: .serverWins
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value

        let calls = await client.recordedCalls
        XCTAssertFalse(calls.contains("getEpisodeActions"),
                       "gPodder sync must stop at the next step boundary after cancellation (calls: \(calls))")
        XCTAssertFalse(calls.contains("uploadEpisodeActions"),
                       "gPodder sync must not upload episode actions after cancellation")
    }
}

// MARK: - Test Support

/// Reference box for event recording across @Sendable closure boundaries.
private final class EventBox: @unchecked Sendable {
    var events: [String] = []
}

/// Reference box so a mock client can cancel the task that is calling it.
final class CancelBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

/// Mock client whose pullSubscriptionChanges invokes a callback (used to
/// cancel the calling task mid-step) and then returns an empty delta.
actor CancelOnPullSyncClient: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    private let onPull: @Sendable () -> Void

    init(onPull: @escaping @Sendable () -> Void) {
        self.onPull = onPull
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        onPull()
        return SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

// MARK: - Recording + Blocking SyncClient

/// Spy client that records every call and blocks inside subscription sync
/// until cancelled (Task.sleep throws CancellationError on cancellation).
actor RecordingBlockingSyncClient: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    private(set) var recordedCalls: [String] = []
    private let blockNanoseconds: UInt64

    init(blockSeconds: UInt64) {
        self.blockNanoseconds = blockSeconds * 1_000_000_000
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        recordedCalls.append("pushSubscriptions")
        try await Task.sleep(nanoseconds: blockNanoseconds)
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        recordedCalls.append("pullSubscriptionChanges")
        try await Task.sleep(nanoseconds: blockNanoseconds)
        return SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        recordedCalls.append("uploadEpisodeActions")
        return []
    }

    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        recordedCalls.append("getEpisodeActions")
        try await Task.sleep(nanoseconds: blockNanoseconds)
        return []
    }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        recordedCalls.append("syncQueue")
        return QueueSyncResult(items: [], droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        recordedCalls.append("getQueue")
        return []
    }
}

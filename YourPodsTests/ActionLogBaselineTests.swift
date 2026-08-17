import XCTest
import SwiftData
@testable import YourPods

/// The episode-action log must record the CAS versions its own pushes earn, per the sync contract.
///
/// `uploadEpisodeActions` posts `ProPlaybackSyncRequest` items to `POST /playback/sync`, the
/// same endpoint every other playback push uses. It is also the highest-frequency writer in
/// the app: `syncProgress` fires on the user's sync interval (10–60s) throughout playback and
/// `sendEpisodeAction` flushes the outbox immediately, outside any sync cycle. Every one of
/// those accepted writes bumps the row's `version`.
///
/// The response was discarded (`performPOST` called for effect, `return []`). So within one
/// sync interval of starting playback, this device's stored baseline for the episode it is
/// playing is stale — invalidated by its own progress reporting. The next versioned push
/// carries that stale baseline, the server refuses it, and current server releases persist
/// a refusal as a `sync_conflicts` row. The device raises the conflict sheet against itself,
/// once per sync, for as long as it keeps playing.
///
/// That is the same defect `CompletionOutboxBaselineTests` covers for mark-as-played, on the
/// path that actually causes it. It only became reachable when the periodic playback push
/// (`ProSyncOrchestrator` step 5d) started carrying a baseline at all.
@MainActor
final class ActionLogBaselineTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tempDir: URL!
    private var baselines: PlaybackBaselineStore!

    private let profileId = "test-action-log-baseline"
    private let epUrl = "https://cdn.example.com/action-ep.mp3"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(profileId, forKey: "activeProfileId")

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("action-log-baseline-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        baselines = PlaybackBaselineStore(fileURL: tempDir.appendingPathComponent("baselines.json"))
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: tempDir)
        baselines = nil
        tempDir = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "episodeActionMap", "syncConflictStrategy"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private func makeService(client: any SyncClient) -> EpisodeActionSyncService {
        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { client },
            profileIdProvider: { self.profileId },
            deviceIdProvider: { "test-device-action-log" }
        )
        service.playbackBaselinesProvider = { [weak self] in self?.baselines }
        return service
    }

    private func playAction() -> EpisodeAction {
        EpisodeAction(
            podcast: "https://example.com/feed.xml",
            episode: epUrl,
            guid: "guid-action-1",
            action: "play",
            timestamp: 1_700_000_000,
            position: 828,
            started: 0,
            total: 3600,
            device: "test-device-action-log"
        )
    }

    // MARK: - The invariant

    /// The whole bug in one assertion. The push moved the server to 9; a device that keeps
    /// believing 5 has already lost, and every versioned push it makes from here is refused.
    func test_actionUpload_advancesTheBaselineToTheVersionItEarned() async {
        baselines.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)
        let client = ActionLogAckSpy(acks: [.init(episodeUrl: epUrl, version: 9)])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        XCTAssertEqual(
            baselines.baseline(for: epUrl)?.syncedVersion, 9,
            "the progress push bumped the server to 9 and this device kept 5 — its next "
            + "versioned push is refused, and a refusal is persisted as a conflict row"
        )
    }

    /// `syncedCompleted` is the only thing that can attribute a completion divergence to the
    /// side that caused it. An action push asserts nothing about completion — it sends the
    /// flag absent — and the server's merge lands on `GREATEST(stored, false)`, so the stored
    /// flag is unchanged. Recording `false` here would claim the server dropped a completion
    /// it still holds, and resolve the next divergence the wrong way.
    func test_actionUpload_preservesTheCompletionFlagItSaidNothingAbout() async {
        baselines.recordAgreement(episodeUrl: epUrl, version: 5, completed: true)
        let client = ActionLogAckSpy(acks: [.init(episodeUrl: epUrl, version: 9)])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedCompleted, true,
                       "an action push says nothing about completion, so it cannot revise the flag")
        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedVersion, 9)
    }

    /// With no prior agreement there is no `syncedCompleted` to carry forward, and inventing
    /// one is the same misattribution. The episode keeps sending the `0` sentinel until an ack
    /// that carries a flag; step (0) settles that first conflict without ever prompting.
    func test_actionUpload_doesNotInventABaselineForAnEpisodeNeverAgreedOn() async {
        let client = ActionLogAckSpy(acks: [.init(episodeUrl: epUrl, version: 9)])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        XCTAssertNil(baselines.baseline(for: epUrl),
                     "a version without a completion flag is half a baseline — step (0) handles this case")
    }

    /// The ack maps to an episode by `episodeUrl` **verbatim** (the sync contract, server
    /// rule 5). An ack that does not match what this batch pushed did not round-trip, and
    /// there is no agreement to record — the same guard `PlaybackSyncCoordinator.apply` applies.
    func test_actionUpload_ignoresAnAckForADifferentEpisode() async {
        baselines.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)
        let client = ActionLogAckSpy(acks: [
            .init(episodeUrl: "https://cdn.example.com/SOMETHING-ELSE.mp3", version: 99)
        ])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedVersion, 5)
    }

    /// A version only ever moves forward. Chunked uploads and retried outbox entries can
    /// deliver acks out of order, and walking a baseline backwards re-opens the exact window
    /// this fix closes.
    func test_actionUpload_neverWalksAVersionBackwards() async {
        baselines.recordAgreement(episodeUrl: epUrl, version: 12, completed: false)
        let client = ActionLogAckSpy(acks: [.init(episodeUrl: epUrl, version: 9)])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedVersion, 12)
    }

    /// A baseline that only lives in memory is worse than none: the next cold start pushes
    /// the pre-ping version and re-opens the window, while looking correct for one session.
    func test_actionUpload_persistsTheAdvancedBaseline() async {
        baselines.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)
        baselines.persist()
        let client = ActionLogAckSpy(acks: [.init(episodeUrl: epUrl, version: 9)])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        let reloaded = PlaybackBaselineStore(fileURL: tempDir.appendingPathComponent("baselines.json"))
        XCTAssertEqual(reloaded.baseline(for: epUrl)?.syncedVersion, 9)
    }

    /// gPodder has no versions to report, and the default protocol implementation answers
    /// with none. That must leave the store untouched rather than clearing anything.
    func test_actionUpload_clientWithNoVersionsToReport_leavesTheBaselineAlone() async {
        baselines.recordAgreement(episodeUrl: epUrl, version: 5, completed: true)
        let client = ActionLogAckSpy(acks: [])
        let service = makeService(client: client)

        await service.sendEpisodeAction(playAction())

        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedVersion, 5)
        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedCompleted, true)
    }
}

// MARK: - Mock

/// Answers the batch upload with a scripted set of acks.
private actor ActionLogAckSpy: SyncClient {

    private let acks: [ProPlaybackSyncResponse.Accepted]
    private(set) var uploadCallCount = 0

    init(acks: [ProPlaybackSyncResponse.Accepted]) {
        self.acks = acks
    }

    func uploadEpisodeActionsRecordingVersions(
        _ actions: [EpisodeAction]
    ) async throws -> [ProPlaybackSyncResponse.Accepted] {
        uploadCallCount += 1
        return acks
    }

    // MARK: - Stubs

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: items, droppedItems: [])
    }
    var supportsSettingsSync: Bool { false }
}

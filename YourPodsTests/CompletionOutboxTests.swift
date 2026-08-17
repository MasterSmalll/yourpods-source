import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the durable completion outbox (Task B4).
///
/// Root cause: `syncCompletedEpisodeToProServer` and `markEpisodeAsPlayed` used
/// fire-and-forget `Task { try? ... }` — an App Check 403, network failure, or
/// background cancellation silently dropped the completion push. The outbox ensures
/// every `completed: true` eventually reaches the server (retried each sync cycle).
@MainActor
final class CompletionOutboxTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var testCompletionOutboxURL: URL!
    private let testProfileId = "test-completion-outbox"
    private let testDeviceId = "test-device-completion"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)

        testCompletionOutboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-completion-outbox-\(UUID().uuidString).json")
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: testCompletionOutboxURL)
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Helpers

    private func makeService(client: (any SyncClient)? = nil) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { client },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId },
            completionOutboxFileURL: self.testCompletionOutboxURL
        )
    }

    private func makePending(
        guid: String = "test-guid-1",
        eventTime: Date = Date()
    ) -> PendingCompletion {
        PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-\(guid).mp3",
            episodeGuid: guid,
            durationSec: 3600,
            eventTime: eventTime
        )
    }

    // MARK: - 1. Enqueue persists to outbox

    /// enqueueCompletion must add the entry to the in-memory outbox.
    func test_enqueueCompletion_addsToOutbox() {
        let service = makeService()
        let pending = makePending(guid: "ep-enqueue")

        service.enqueueCompletion(pending)

        XCTAssertEqual(service.completionOutbox.count, 1,
                       "Completion outbox must contain 1 entry after enqueue")
        XCTAssertNotNil(service.completionOutbox["ep-enqueue"],
                        "Outbox must be keyed by episodeGuid")
    }

    /// enqueueCompletion without a guid must fall back to episodeUrl as the key.
    func test_enqueueCompletion_usesEpisodeUrlWhenGuidNil() {
        let service = makeService()
        let pending = PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/no-guid.mp3",
            episodeGuid: nil,
            durationSec: nil,
            eventTime: Date()
        )

        service.enqueueCompletion(pending)

        XCTAssertEqual(service.completionOutbox.count, 1)
        XCTAssertNotNil(service.completionOutbox["https://example.com/no-guid.mp3"],
                        "When guid is nil the key must be episodeUrl")
    }

    // MARK: - 2. pendingCompletionGuids

    /// pendingCompletionGuids returns GUIDs of pending completions.
    func test_pendingCompletionGuids_returnsEnqueuedGuids() {
        let service = makeService()
        service.enqueueCompletion(makePending(guid: "g1"))
        service.enqueueCompletion(makePending(guid: "g2"))

        let guids = service.pendingCompletionGuids()

        XCTAssertTrue(guids.contains("g1"), "g1 must be in pendingCompletionGuids")
        XCTAssertTrue(guids.contains("g2"), "g2 must be in pendingCompletionGuids")
    }

    // MARK: - 3. Drain: retry on failure, remove on success

    /// Drain retains the entry when syncPlayback throws, then removes it on success.
    func test_drainCompletionOutbox_retainsOnFailureThenRemovesOnSuccess() async {
        let spy = CompletionOutboxSpy(failCount: 1)
        let service = makeService(client: spy)

        let eventTime = Date(timeIntervalSince1970: 1_000_000)
        let pending = PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-retry.mp3",
            episodeGuid: "guid-retry",
            durationSec: 1800,
            eventTime: eventTime
        )
        service.enqueueCompletion(pending)

        // First drain — spy throws once
        await service.drainCompletionOutbox(using: spy, baselines: nil)
        XCTAssertEqual(service.completionOutbox.count, 1,
                       "Entry must remain in outbox after first failed drain")

        // Second drain — spy succeeds
        await service.drainCompletionOutbox(using: spy, baselines: nil)
        XCTAssertEqual(service.completionOutbox.count, 0,
                       "Entry must be removed from outbox after successful drain")
    }

    /// Drain calls syncPlayback with completed:true and the original eventTime.
    func test_drainCompletionOutbox_callsSyncPlaybackWithCompletedTrueAndOriginalEventTime() async {
        let spy = CompletionOutboxSpy(failCount: 0)
        let service = makeService(client: spy)

        let fixedEventTime = Date(timeIntervalSince1970: 1_700_000_000)
        let pending = PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-event.mp3",
            episodeGuid: "guid-event",
            durationSec: 2700,
            eventTime: fixedEventTime
        )
        service.enqueueCompletion(pending)

        await service.drainCompletionOutbox(using: spy, baselines: nil)

        let calls = await spy.syncPlaybackCalls
        XCTAssertEqual(calls.count, 1, "syncPlayback must be called once")
        let call = calls[0]
        XCTAssertEqual(call.completed, true, "completed must be true")
        XCTAssertEqual(call.clientUpdatedAt, fixedEventTime,
                       "clientUpdatedAt must match the original eventTime")
        XCTAssertEqual(call.episodeUrl, "https://example.com/ep-event.mp3")
        XCTAssertEqual(call.episodeGuid, "guid-event")
    }

    // MARK: - 3b. Drain pushes an observed position, never a fabricated one

    /// `PendingCompletion` carried no position, so the drain sent `durationSec ?? 0` — a
    /// number nobody measured. When the duration is unknown that is a literal `positionSec:
    /// 0`, and the versionless merge writes it: the event-time predicate passes (this push
    /// is newest) and `(EXCLUDED.now_playing OR NOT playback_states.now_playing)` is true
    /// for a paused row, so the `THEN EXCLUDED.position_sec` branch takes it and the stored
    /// playhead becomes 0. Marking a duration-less episode played erased where you were in
    /// it, which surfaces on relisten and in the conflict sheet's "this device / other
    /// device" copy.
    func test_drainCompletionOutbox_pushesTheRecordedPosition_notAFabricatedOne() async {
        let spy = CompletionOutboxSpy(failCount: 0)
        let service = makeService(client: spy)

        service.enqueueCompletion(PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-pos.mp3",
            episodeGuid: "guid-pos",
            durationSec: nil,           // feed never declared one
            eventTime: Date(timeIntervalSince1970: 1_700_000_000),
            positionSec: 2167           // where the user actually was
        ))

        await service.drainCompletionOutbox(using: spy, baselines: nil)

        let calls = await spy.syncPlaybackCalls
        XCTAssertEqual(calls.first?.positionSec ?? -1, 2167, accuracy: 0.001,
                       "a duration-less completion pushed positionSec 0 and the merge wrote it over the real playhead")
    }

    /// Entries written by an earlier build have no `positionSec` on disk. Decoding one must
    /// keep working and must keep its old behaviour — position at the duration — rather than
    /// collapsing to 0 because the new key is missing.
    func test_drainCompletionOutbox_entryWithNoRecordedPosition_fallsBackToDuration() async {
        let spy = CompletionOutboxSpy(failCount: 0)
        let service = makeService(client: spy)

        service.enqueueCompletion(PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-legacy.mp3",
            episodeGuid: "guid-legacy",
            durationSec: 1800,
            eventTime: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        await service.drainCompletionOutbox(using: spy, baselines: nil)

        let calls = await spy.syncPlaybackCalls
        XCTAssertEqual(calls.first?.positionSec ?? -1, 1800, accuracy: 0.001)
    }

    /// The new field has to survive the disk round-trip, or the fix works exactly until the
    /// app is killed before the next sync — which is the case the outbox exists for.
    func test_pendingCompletion_positionSurvivesPersistence() {
        let service = makeService(client: CompletionOutboxSpy(failCount: 0))
        service.enqueueCompletion(PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-persist.mp3",
            episodeGuid: "guid-persist",
            durationSec: nil,
            eventTime: Date(timeIntervalSince1970: 1_700_000_000),
            positionSec: 934
        ))

        let restored = makeService(client: CompletionOutboxSpy(failCount: 0))
        restored.loadCompletionOutbox()

        XCTAssertEqual(restored.completionOutbox["guid-persist"]?.positionSec, 934)
    }

    // MARK: - 4. Cancellation: cancelled drain must not clear entries

    /// A drain that starts with Task.isCancelled must leave all entries intact.
    func test_drainCompletionOutbox_cancelledDrainDoesNotClearEntries() async {
        let spy = CompletionOutboxSpy(failCount: 0)
        let service = makeService(client: spy)
        service.enqueueCompletion(makePending(guid: "guid-cancel"))

        // Cancel the task before it runs the drain
        let task = Task {
            await service.drainCompletionOutbox(using: spy, baselines: nil)
        }
        task.cancel()
        await task.value

        // After cancellation the outbox must still have the entry
        XCTAssertEqual(service.completionOutbox.count, 1,
                       "Cancelled drain must not remove outbox entries")
        let calls = await spy.syncPlaybackCalls
        XCTAssertEqual(calls.count, 0, "syncPlayback must not be called when drain is cancelled")
    }

    // MARK: - 4b. Mid-drain cancellation: second entry must survive

    /// When a drain is cancelled after the first entry succeeds, the second entry
    /// must remain in the outbox. Exercises the `guard !Task.isCancelled` inside the loop.
    func test_drainCompletionOutbox_midDrainCancelLeavesSecondEntryIntact() async {
        // CancelBox (shared test helper) lets the spy cancel the outer Task without
        // a data-race: Task.cancel() is safe from any thread; we assign the task
        // before the Task body can run far enough to invoke afterEachCall.
        let cancelBox = CancelBox()
        let spy = CompletionOutboxSpy(failCount: 0, afterEachCall: {
            cancelBox.task?.cancel()
        })
        let service = makeService(client: spy)

        // Enqueue two distinct completions.
        service.enqueueCompletion(makePending(guid: "mid-drain-1"))
        service.enqueueCompletion(makePending(guid: "mid-drain-2"))
        XCTAssertEqual(service.completionOutbox.count, 2, "Precondition: two entries in outbox")

        let task = Task {
            await service.drainCompletionOutbox(using: spy, baselines: nil)
        }
        cancelBox.task = task   // set before the loop can call afterEachCall
        await task.value

        // Exactly one call must have been made and one entry must remain.
        let calls = await spy.syncPlaybackCalls
        XCTAssertEqual(calls.count, 1, "Only the first entry must be processed before cancel")
        XCTAssertEqual(service.completionOutbox.count, 1,
                       "Second entry must remain in outbox after mid-drain cancel")
    }

    // MARK: - 5. Persistence: load from disk restores entries

    /// Entries written to disk by enqueueCompletion must be readable on a new instance.
    func test_enqueueCompletion_persistsToFile_restoredOnNewInstance() {
        let service1 = makeService()
        let pending = makePending(guid: "persisted-guid")
        service1.enqueueCompletion(pending)

        // Create a new instance pointing to the same file — simulates app restart
        let service2 = makeService()
        service2.loadCompletionOutbox()

        XCTAssertEqual(service2.completionOutbox.count, 1,
                       "Outbox must be restored from disk after app restart")
        XCTAssertNotNil(service2.completionOutbox["persisted-guid"])
    }
}

// MARK: - Test Spy

/// Spy that fails the first N syncPlayback calls then succeeds.
///
/// `afterEachCall`: optional hook invoked (on the actor) after each *successful* syncPlayback call.
/// Used by the mid-drain-cancel test to cancel the enclosing Task after the first push.
actor CompletionOutboxSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    private let failCount: Int
    private var callsMade = 0
    private let afterEachCall: (@Sendable () -> Void)?

    struct SyncPlaybackCall {
        let episodeUrl: String
        let episodeGuid: String?
        let positionSec: Double
        let completed: Bool?
        let clientUpdatedAt: Date?
    }

    private(set) var syncPlaybackCalls: [SyncPlaybackCall] = []

    init(failCount: Int, afterEachCall: (@Sendable () -> Void)? = nil) {
        self.failCount = failCount
        self.afterEachCall = afterEachCall
    }

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
        callsMade += 1
        if callsMade <= failCount {
            throw NSError(domain: "test", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Simulated syncPlayback failure"])
        }
        syncPlaybackCalls.append(SyncPlaybackCall(
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid,
            positionSec: positionSec,
            completed: completed,
            clientUpdatedAt: clientUpdatedAt
        ))
        afterEachCall?()
        return nil
    }

    // Minimal SyncClient conformance
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: [], droppedItems: [])
    }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

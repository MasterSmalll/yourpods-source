import XCTest
import SwiftData
@testable import YourPods

/// The completion outbox must record the CAS baseline its own push earns, per the sync contract.
///
/// `drainCompletionOutbox` pushed `completed: true` and threw the response away. Every
/// mark-as-played therefore bumped the server's `version` while this device kept the
/// baseline it held *before* the completion. The device's next versioned push then
/// carried a stale `baseVersion`, the server refused it, and — since current server releases
/// persist a refusal as a `sync_conflicts` row — the device raised a sheet **against its own
/// completion**:
///
///   "I marked an episode as played from ios and immediately got a sync conflict with the
///    max time of the episode being the server value and play time on the device being
///    the correct device time"
///
/// The server side of that report (the row froze and lied about it afterwards) is fixed
/// separately in the corresponding server change. This is the half that stops the row being
/// created.
@MainActor
final class CompletionOutboxBaselineTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tempDir: URL!
    private var outboxURL: URL!
    private var baselines: PlaybackBaselineStore!

    private let profileId = "test-completion-baseline"
    private let deviceId = "test-device-completion-baseline"
    private let epUrl = "https://cdn.example.com/completed-ep.mp3"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(profileId, forKey: "activeProfileId")

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("completion-baseline-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        outboxURL = tempDir.appendingPathComponent("outbox.json")
        baselines = PlaybackBaselineStore(fileURL: tempDir.appendingPathComponent("baselines.json"))
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: tempDir)
        baselines = nil
        outboxURL = nil
        tempDir = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "syncConflictStrategy"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private func makeService() -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { self.profileId },
            deviceIdProvider: { self.deviceId },
            completionOutboxFileURL: self.outboxURL
        )
    }

    private func makePending(episodeUrl: String? = nil) -> PendingCompletion {
        PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: episodeUrl ?? epUrl,
            episodeGuid: "guid-completed-1",
            durationSec: 3600,
            eventTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - The defect

    /// The whole bug in one assertion: the push earns a new `version` and the device has
    /// to keep it, or its next push argues with the completion it just made.
    func test_drain_recordsTheAckVersionAsTheBaseline() async {
        let service = makeService()
        service.enqueueCompletion(makePending())

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 1,
            accepted: [.init(episodeUrl: epUrl, version: 43)],
            conflicts: []
        ))

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertEqual(
            baselines.baseline(for: epUrl)?.syncedVersion, 43,
            "the completion push bumped the server to 43 and this device kept its old baseline — "
            + "its next push conflicts against its own mark-as-played"
        )
    }

    /// The baseline is a pair. A version with the wrong `completed` still misattributes the
    /// next completion divergence in the reconciler ladder.
    func test_drain_recordsTheCompletionTheServerReports() async {
        let service = makeService()
        service.enqueueCompletion(makePending())

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 1,
            accepted: [.init(episodeUrl: epUrl, version: 7, completed: true)],
            conflicts: []
        ))

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedCompleted, true)
    }

    /// The push asserts `completed: true`, but a completion is versionless BY DESIGN — a
    /// decision the user already made must land unconditionally rather than be allowed to
    /// conflict — so it goes through the server's merge, where a strictly-older event time
    /// keeps the stored flag. `accepted[].completed` reports what the row ended up with.
    ///
    /// Recording the asserted `true` instead claims an agreement this device never had, and
    /// `syncedCompleted` is what attributes the NEXT completion divergence in the sync
    /// contract's step (0) ladder — so a wrong flag resolves a later conflict the wrong way.
    func test_drain_doesNotRecordACompletionTheServerDiscarded() async {
        let service = makeService()
        service.enqueueCompletion(makePending())

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 1,
            accepted: [.init(episodeUrl: epUrl, version: 7, completed: false)],
            conflicts: []
        ))

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertEqual(
            baselines.baseline(for: epUrl)?.syncedCompleted, false,
            "recorded completed:true for a completion the server's merge discarded — "
            + "an agreement this device never had"
        )
    }

    /// The currently-deployed server predates `accepted[].completed` and sends no such key.
    /// This push asserted completion and the server accepted it, so absent falls back to
    /// what was asserted — the behaviour before the field existed, which keeps the fix
    /// working against production today.
    func test_drain_absentCompletedField_fallsBackToWhatWasAsserted() async {
        let service = makeService()
        service.enqueueCompletion(makePending())

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 1,
            accepted: [.init(episodeUrl: epUrl, version: 7)], // no `completed`
            conflicts: []
        ))

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertEqual(baselines.baseline(for: epUrl)?.syncedCompleted, true)
    }

    /// Decoded from the literal bytes the server's sync handler emits. A test that only ever
    /// builds the model in Swift cannot catch a key that does not match the wire — which is
    /// how the conflict list stayed undecodable for months while its unit tests passed.
    func test_acceptedCompleted_decodesFromTheServersJSON() throws {
        let json = Data(#"{"count":1,"accepted":[{"episodeUrl":"https://cdn.example.com/completed-ep.mp3","version":43,"completed":false}],"conflicts":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(ProPlaybackSyncResponse.self, from: json)

        XCTAssertEqual(decoded.accepted.first?.completed, false)
        XCTAssertEqual(decoded.accepted.first?.version, 43)
    }

    /// The sync contract's server rule 5 echoes `episodeUrl` byte-for-byte, and the store
    /// keys on it verbatim. An ack that does not map to what this drain pushed did not
    /// round-trip, so there is no agreement to record — writing one would authorize a later
    /// push under a version this device never agreed to. Mirrors the guard in
    /// `PlaybackSyncCoordinator`.
    func test_drain_ackForAnEpisodeItDidNotPush_recordsNothing() async {
        let service = makeService()
        service.enqueueCompletion(makePending())

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 1,
            accepted: [.init(episodeUrl: "https://cdn.example.com/some-other-ep.mp3", version: 99)],
            conflicts: []
        ))

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertNil(baselines.baseline(for: epUrl))
        XCTAssertNil(baselines.baseline(for: "https://cdn.example.com/some-other-ep.mp3"))
    }

    /// A gPodder or non-Pro client returns `nil` from `syncPlayback` — there is no version
    /// in that world. The drain must still succeed and still clear the outbox entry;
    /// recording a baseline is the Pro-only half.
    func test_drain_withNoProResponse_stillDrains_andRecordsNothing() async {
        let service = makeService()
        service.enqueueCompletion(makePending())

        let client = CASMockSyncClient() // no scripted response → returns nil

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertNil(baselines.baseline(for: epUrl))
        XCTAssertTrue(
            service.pendingCompletionGuids().isEmpty,
            "a successful push must still clear the outbox even when the client cannot report a version"
        )
    }

    /// A conflicted completion is not an agreement. The server refused the write, so the
    /// baseline must stay where it was and the entry must stay in the outbox for retry.
    func test_drain_conflictedCompletion_recordsNoBaseline() async {
        let service = makeService()
        service.enqueueCompletion(makePending())
        baselines.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 0,
            accepted: [],
            conflicts: [.init(episodeUrl: epUrl, server: .init(
                positionSec: 2167, completed: false, nowPlaying: false, version: 12))]
        ))

        await service.drainCompletionOutbox(using: client, baselines: baselines)

        XCTAssertEqual(
            baselines.baseline(for: epUrl)?.syncedVersion, 5,
            "recording the server's version off a conflict claims an agreement that does not exist"
        )
    }
}

/// `POST /playback/sync` response consumption, per the sync contract (iOS side).
///
/// `PlaybackReconciler` decides what to do about *one* row-4 conflict. This is the layer
/// that reads a whole response, applies the reconciler per conflict, and does the version
/// bookkeeping — and the bookkeeping is where the contract fails silently.
///
/// The defining rule, and the one every test here exists to hold: **`syncedVersion`
/// advances on an ack or an adopt, never on receipt of a `conflicts[]` entry.** A conflict
/// payload reports a value the server holds and this device has *not* accepted. Record it
/// as agreement and the next ordinary push carries a baseline that matches, the server
/// commits, and "both devices keep their own position" quietly becomes last-write-wins —
/// with no error, no failed request, and nothing in the log to find later.
import XCTest
@testable import YourPods

@MainActor
final class PlaybackSyncCoordinatorTests: XCTestCase {

    private var tempDir: URL!
    private var store: PlaybackBaselineStore!

    private let epUrl = "https://cdn.example.com/ep1.mp3"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = PlaybackBaselineStore(fileURL: tempDir.appendingPathComponent("baselines.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Builders

    private func response(
        accepted: [ProPlaybackSyncResponse.Accepted] = [],
        conflicts: [ProPlaybackSyncResponse.Conflict] = []
    ) -> ProPlaybackSyncResponse {
        ProPlaybackSyncResponse(count: accepted.count, accepted: accepted, conflicts: conflicts)
    }

    private func conflict(
        url: String? = nil,
        serverPosition: Double,
        serverCompleted: Bool = false,
        serverNowPlaying: Bool = false,
        version: Int64 = 12
    ) -> ProPlaybackSyncResponse.Conflict {
        ProPlaybackSyncResponse.Conflict(
            episodeUrl: url ?? epUrl,
            server: .init(
                positionSec: serverPosition,
                completed: serverCompleted,
                nowPlaying: serverNowPlaying,
                version: version
            )
        )
    }

    private func pushed(
        _ position: Double,
        completed: Bool = false,
        nowPlaying: Bool = false,
        url: String? = nil
    ) -> [String: PlaybackSnapshot] {
        [(url ?? epUrl): PlaybackSnapshot(positionSec: position, completed: completed, nowPlaying: nowPlaying)]
    }

    private func apply(
        _ response: ProPlaybackSyncResponse,
        pushed: [String: PlaybackSnapshot],
        strategy: SyncStrategy = .ask,
        attempt: Int = 1
    ) -> PlaybackSyncCoordinator.Outcome {
        PlaybackSyncCoordinator.apply(
            response: response,
            pushed: pushed,
            strategy: strategy,
            store: store,
            attempt: attempt
        )
    }

    // MARK: - accepted[] — the only ordinary way a baseline advances

    func test_acceptedEntry_advancesBaselineToAckedVersion() {
        _ = apply(
            response(accepted: [.init(episodeUrl: epUrl, version: 42)]),
            pushed: pushed(100)
        )
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 42)
    }

    /// `syncedCompleted` attributes a later `completed` divergence to the side that acted,
    /// so it has to record what *this device pushed*, not what the server happened to hold.
    func test_acceptedEntry_recordsThePushedCompletedFlag() {
        _ = apply(
            response(accepted: [.init(episodeUrl: epUrl, version: 42)]),
            pushed: pushed(100, completed: true)
        )
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedCompleted, true)
    }

    /// The server echoes `episodeUrl` byte-for-byte. An ack for a URL this cycle never
    /// pushed means the echo did not round-trip, and there is no honest `completed` to
    /// record — guessing one corrupts the attribution that resolves the next divergence.
    func test_EDGE_ackForUrlNotPushed_isSkipped_ratherThanGuessed() {
        _ = apply(
            response(accepted: [.init(episodeUrl: "https://cdn.example.com/other.mp3", version: 42)]),
            pushed: pushed(100)
        )
        XCTAssertNil(store.baseline(for: "https://cdn.example.com/other.mp3"))
    }

    // MARK: - conflicts[] — never an agreement

    /// The load-bearing test. A conflict reports a value we have not accepted.
    func test_conflictEntry_neverAdvancesTheBaselineOnReceipt() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        _ = apply(
            response(conflicts: [conflict(serverPosition: 2167, version: 12)]),
            pushed: pushed(828)
        )

        XCTAssertEqual(
            store.baseline(for: epUrl)?.syncedVersion, 5,
            "receiving a conflict is not agreeing with it — advancing here makes the next push clobber the server"
        )
    }

    func test_conflict_adoptOutcome_advancesBaselineToServerVersion() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        // Within tolerance, server larger → adopt the server's value wholesale.
        let outcome = apply(
            response(conflicts: [conflict(serverPosition: 831, version: 12)]),
            pushed: pushed(828)
        )

        XCTAssertEqual(outcome.adopts.map(\.episodeUrl), [epUrl])
        XCTAssertEqual(outcome.adopts.first?.position, 831)
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 12, "an adopt IS an agreement")
    }

    /// The device won, so the resolved value is one the server does not hold yet. The
    /// baseline may only advance when *that* push is acked.
    func test_conflict_rePushOutcome_carriesServerVersion_andLeavesBaselineAlone() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let outcome = apply(
            response(conflicts: [conflict(serverPosition: 2167, version: 12)]),
            pushed: pushed(828),
            strategy: .deviceWins
        )

        XCTAssertEqual(outcome.rePushes.count, 1)
        XCTAssertEqual(outcome.rePushes.first?.position, 828)
        XCTAssertEqual(
            outcome.rePushes.first?.baseVersion, 12,
            "the resolving push must use the version the conflict reported, not the stale baseline"
        )
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 5)
    }

    /// Ladder (c). The one outcome that deliberately stays dirty: no prompt, no re-push,
    /// no version advance. It is not "stop pushing" — the next cycle conflicts again.
    func test_conflict_bothSidesPlaying_producesNoWorkAtAll() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let outcome = apply(
            response(conflicts: [conflict(serverPosition: 2167, serverNowPlaying: true, version: 12)]),
            pushed: pushed(828, nowPlaying: true)
        )

        XCTAssertTrue(outcome.adopts.isEmpty)
        XCTAssertTrue(outcome.rePushes.isEmpty)
        XCTAssertTrue(outcome.prompts.isEmpty)
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 5)
    }

    /// Ladder (d) under `.ask` — the only path that reaches the user.
    func test_conflict_neitherPlaying_underAsk_producesAPrompt() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let outcome = apply(
            response(conflicts: [conflict(serverPosition: 2167, version: 12)]),
            pushed: pushed(828)
        )

        XCTAssertEqual(outcome.prompts.count, 1)
        XCTAssertEqual(outcome.prompts.first?.localPosition, 828)
        XCTAssertEqual(outcome.prompts.first?.serverPosition, 2167)
        XCTAssertTrue(outcome.rePushes.isEmpty)
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 5)
    }

    /// Step (0). No baseline ⇒ this device never agreed with the server on this episode,
    /// so "both sides changed since the baseline" is an unfounded claim and a prompt
    /// asserting it would be a lie. Resolve once by the legacy merge semantics.
    func test_conflict_withNoBaseline_resolvesSilently_andNeverPrompts() {
        let outcome = apply(
            response(conflicts: [conflict(serverPosition: 2167, version: 12)]),
            pushed: pushed(828)
        )

        XCTAssertTrue(outcome.prompts.isEmpty, "a fresh install must not prompt on first contact")
        XCTAssertEqual(outcome.adopts.count, 1, "larger position wins by legacy semantics")
        XCTAssertEqual(outcome.adopts.first?.position, 2167)
    }

    // MARK: - Bounding

    /// CAS retry must terminate in the table — adopt or prompt — never in an unbounded
    /// loop and never in an unconditional write. Three attempts per episode per cycle.
    func test_EDGE_rePush_isNotEmittedBeyondTheAttemptBound() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let outcome = apply(
            response(conflicts: [conflict(serverPosition: 2167, version: 12)]),
            pushed: pushed(828),
            strategy: .deviceWins,
            attempt: PlaybackSyncCoordinator.maxAttempts
        )

        XCTAssertTrue(outcome.rePushes.isEmpty, "the bound must stop the cycle, not spin")
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 5, "giving up is not agreeing")
    }

    // MARK: - Degenerate responses

    /// An older deployment answers with no arrays at all. That is not an error and
    /// must not be treated as one — it is simply a server with nothing to say about CAS.
    func test_emptyResponse_producesNoWorkAndTouchesNothing() {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let outcome = apply(response(), pushed: pushed(828))

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 5)
    }

    func test_conflictForUrlNotPushed_isSkipped() {
        let outcome = apply(
            response(conflicts: [conflict(url: "https://cdn.example.com/other.mp3", serverPosition: 2167)]),
            pushed: pushed(828)
        )
        XCTAssertTrue(outcome.isEmpty, "without the pushed snapshot there is no local side to resolve against")
    }
}

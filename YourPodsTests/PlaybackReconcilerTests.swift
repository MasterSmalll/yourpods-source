/// Row-4 playback conflict resolution, per the sync contract (iOS side).
///
/// The sync contract replaces the older server-side merge (`GREATEST` on position,
/// event-time branches, the `now_playing` write gate) with per-episode CAS: the client
/// stores the `version` it last agreed with the server on, pushes it as `baseVersion`, and
/// a mismatch comes back as an entry in `conflicts[]` at HTTP 200 — *not* 409, which
/// is queue CAS and a false analogy.
///
/// Everything in this file is the client half of row 4 of the table ("local changed
/// AND server changed"). Rows 1–3 never reach it: they are "do nothing", "adopt", and
/// "push and take the ack". Detection is never computed here — a conflict entry *is*
/// row 4. This type only decides what to do about one.
///
/// Deliberately pure: no `AVPlayer`, no store, no clock, no singletons. This
/// bug class is silent — a wrong `syncedVersion` advance turns "each device keeps its
/// own value" into last-write-wins churn with no error anywhere — so the decision has
/// to be assertable in isolation from the machinery that carries it out.
import XCTest
@testable import YourPods

final class PlaybackReconcilerTests: XCTestCase {

    // MARK: - Helpers

    private func local(
        _ position: Double,
        completed: Bool = false,
        nowPlaying: Bool = false
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(positionSec: position, completed: completed, nowPlaying: nowPlaying)
    }

    private func server(
        _ position: Double,
        completed: Bool = false,
        nowPlaying: Bool = false,
        version: Int64 = 12
    ) -> ServerPlaybackConflict {
        ServerPlaybackConflict(
            positionSec: position,
            completed: completed,
            nowPlaying: nowPlaying,
            version: version
        )
    }

    /// A baseline that agrees with both sides on `completed`, so the `completed`
    /// rule is inert and the position ladder is what's under test.
    private func baseline(_ version: Int64 = 8, completed: Bool = false) -> PlaybackBaseline {
        PlaybackBaseline(syncedVersion: version, syncedCompleted: completed)
    }

    // MARK: - Position ladder (a)–(d)

    /// (a) within 5s → take the larger, no prompt. A *position* tolerance, not a clock
    /// tolerance: being wrong costs seconds of audio, not divergence.
    func test_ladderA_withinFiveSeconds_takesLarger() {
        // Server larger → the resolved state equals the server's → adopt.
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100), baseline: baseline(), server: server(103), strategy: .ask
            ),
            .adoptServer(position: 103, completed: false, version: 12)
        )

        // Local larger → resolved differs from the server → re-push, and the baseline
        // for that push is the version the *conflict* reported, not the stale one.
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(103), baseline: baseline(), server: server(100), strategy: .ask
            ),
            .rePushLocal(position: 103, completed: false, baseVersion: 12)
        )
    }

    /// EDGE: exactly 5s apart is inside the tolerance; 5.01s is not.
    func test_ladderA_boundary() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100), baseline: baseline(), server: server(105), strategy: .ask
            ),
            .adoptServer(position: 105, completed: false, version: 12),
            "5.0s apart must resolve inside (a), not fall through to the prompt"
        )
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100), baseline: baseline(), server: server(105.01), strategy: .ask
            ),
            .prompt(localPosition: 100, serverPosition: 105.01),
            "beyond the tolerance with neither side playing is a genuine (d)"
        )
    }

    /// (b) exactly one side playing → the playing side wins, silently.
    func test_ladderB_playingSideWins_silently() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100, nowPlaying: true), baseline: baseline(),
                server: server(900), strategy: .ask
            ),
            .rePushLocal(position: 100, completed: false, baseVersion: 12)
        )
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100), baseline: baseline(),
                server: server(900, nowPlaying: true), strategy: .ask
            ),
            .adoptServer(position: 900, completed: false, version: 12)
        )
    }

    /// (c) both playing → each device keeps its own value. No prompt, no re-push, and
    /// critically **no version advance**: advance here and the next push matches, the
    /// write lands, and "each keeps its own" becomes LWW churn between two players.
    func test_ladderC_bothPlaying_keepsLocalAndAdvancesNothing() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100, nowPlaying: true), baseline: baseline(),
                server: server(900, nowPlaying: true), strategy: .ask
            ),
            .keepLocalSilently
        )
    }

    /// (c) is not "stop pushing" — the next cycle's ordinary push still goes out with
    /// the same stale baseline and conflicts again. That repeat is a silent no-op, so
    /// it must resolve identically however many times it recurs.
    func test_ladderC_repeatsIdentically_isNotAnErrorPath() {
        let repeated = (0..<3).map { i in
            PlaybackReconciler.resolve(
                local: local(100 + Double(i) * 30, nowPlaying: true),
                baseline: baseline(),
                server: server(900 + Double(i) * 30, nowPlaying: true, version: 12 + Int64(i)),
                strategy: .ask
            )
        }
        XCTAssertEqual(repeated, [.keepLocalSilently, .keepLocalSilently, .keepLocalSilently])
    }

    /// (d) neither playing → `syncConflictStrategy` decides. The prompt fires *only*
    /// here: two idle devices genuinely disagreeing, which is the case the user asked
    /// to be asked about.
    func test_ladderD_neitherPlaying_honoursStrategy() {
        let cases: [(SyncStrategy, PlaybackResolution)] = [
            (.serverWins, .adoptServer(position: 900, completed: false, version: 12)),
            (.deviceWins, .rePushLocal(position: 100, completed: false, baseVersion: 12)),
            (.ask, .prompt(localPosition: 100, serverPosition: 900)),
        ]
        for (strategy, expected) in cases {
            XCTAssertEqual(
                PlaybackReconciler.resolve(
                    local: local(100), baseline: baseline(), server: server(900), strategy: strategy
                ),
                expected,
                "strategy \(strategy) must resolve to \(expected)"
            )
        }
    }

    // MARK: - `completed` resolves first, and independently of position

    /// The sync contract's worked example: the device is playing at 12:04, the user
    /// marks the episode played on web. `completed` is attributed to web (the device
    /// never touched the flag) while position stays local via (b). The result is a
    /// combination neither device held — intended. Under the position ladder alone,
    /// (b) would have taken the whole server state and the mark-played would have
    /// vanished with no error.
    func test_completed_serverFlipped_survivesAPositionWinByTheDevice() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(724, completed: false, nowPlaying: true),
                baseline: baseline(completed: false),
                server: server(2167.4, completed: true),
                strategy: .ask
            ),
            .rePushLocal(position: 724, completed: true, baseVersion: 12),
            "the device keeps playing at 12:04 AND the episode leaves Up Next"
        )
    }

    /// The mirror: the device marks played while another device is playing. Position
    /// adopts the playing side via (b), but the deliberate flag is never what gets
    /// discarded — so the resolved state differs from the server's and must be pushed.
    func test_completed_localFlipped_survivesAPositionWinByTheServer() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(724, completed: true),
                baseline: baseline(completed: false),
                server: server(2167.4, completed: false, nowPlaying: true),
                strategy: .ask
            ),
            .rePushLocal(position: 2167.4, completed: true, baseVersion: 12)
        )
    }

    /// Both sides agree on `completed` → the rule is inert and must not perturb the
    /// ladder, including when both are already `true`.
    func test_completed_agreeing_leavesTheLadderAlone() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(100, completed: true), baseline: baseline(completed: true),
                server: server(900, completed: true, nowPlaying: true), strategy: .ask
            ),
            .adoptServer(position: 900, completed: true, version: 12)
        )
    }

    // MARK: - Version bookkeeping

    /// An adopt is the only outcome that advances `syncedVersion` off the conflict
    /// payload, and it advances it to the version the server reported.
    func test_adopt_carriesTheServerVersion() {
        guard case let .adoptServer(_, _, version) = PlaybackReconciler.resolve(
            local: local(100), baseline: baseline(), server: server(900, version: 77),
            strategy: .serverWins
        ) else { return XCTFail("expected an adopt") }
        XCTAssertEqual(version, 77)
    }

    /// A local win re-pushes with `baseVersion` = the version from the *conflict*
    /// payload — a version learned from a conflict is a valid baseline for exactly
    /// that resolving push and nothing else. `syncedVersion` advances on its ack, not
    /// here, which is why no resolution carries a "new synced version" for local wins.
    func test_localWin_rePushesWithTheConflictReportedVersion() {
        guard case let .rePushLocal(_, _, baseVersion) = PlaybackReconciler.resolve(
            local: local(100), baseline: baseline(8), server: server(900, version: 77),
            strategy: .deviceWins
        ) else { return XCTFail("expected a re-push") }
        XCTAssertEqual(baseVersion, 77, "must not re-push the stale baseline it already lost with")
    }

    /// The client rule plus the wire contract: unknown ⇒ send `0`, which is distinguishable
    /// from an omitted `baseVersion` (legacy last-write-wins) on the wire.
    func test_baseVersionForPush_unknownBaselineSendsZeroSentinel() {
        XCTAssertEqual(PlaybackReconciler.baseVersionForPush(baseline: nil), 0)
        XCTAssertEqual(
            PlaybackReconciler.baseVersionForPush(baseline: baseline(8)), 8
        )
    }

    // MARK: - No baseline ⇒ no prompt (matrix cases 4 and 6)

    /// A conflict on a push that carried `baseVersion: 0` is not a real row 4: the
    /// client has never agreed with the server on this episode, so "both sides changed
    /// since the baseline" is an unfounded claim and a prompt asserting it lies to the
    /// user. Asserted as zero-prompt rather than by resolved value: only the absence of
    /// a prompt is settled here. Which side wins `completed` is deliberately left
    /// unpinned, so both sides are held equal in this fixture.
    func test_noBaseline_neverPrompts_evenUnderAskStrategy() {
        let resolution = PlaybackReconciler.resolve(
            local: local(100), baseline: nil, server: server(2167.4), strategy: .ask
        )
        XCTAssertEqual(
            resolution,
            .adoptServer(position: 2167.4, completed: false, version: 12),
            "an upgrading install must not meet this work as a prompt storm on first launch"
        )
    }

    /// The other direction of step (0): a device that genuinely listened offline keeps
    /// its own larger position instead of losing it to the server's high-water mark.
    func test_noBaseline_localAhead_keepsLocalPosition() {
        XCTAssertEqual(
            PlaybackReconciler.resolve(
                local: local(2400), baseline: nil, server: server(2167.4), strategy: .ask
            ),
            .rePushLocal(position: 2400, completed: false, baseVersion: 12)
        )
    }
}

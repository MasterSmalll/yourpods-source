import Foundation

/// Row-4 playback conflict resolution, per the sync contract.
///
/// It replaces the legacy server-side merge with per-episode CAS. The client stores the
/// `version` it last agreed with the server on, pushes it as `baseVersion`, and a
/// mismatch comes back as an entry in `conflicts[]` at **HTTP 200** — not 409. (Queue
/// CAS answers 409 because it replaces the queue atomically; playback is per-episode
/// partial success, so 49 commits and 1 conflict is not a failed request.)
///
/// "Server vs baseline" is never computed here. A conflict entry *is* row 4 of the
/// table; this type only decides what to do about one. Rows 1–3 — nothing, adopt, push
/// — never reach it.
///
/// Kept pure on purpose. This bug class is silent: advance `syncedVersion` on the
/// wrong outcome and the next push matches, the write lands, and "each device keeps its
/// own value" quietly becomes last-write-wins churn with no error anywhere.
enum PlaybackReconciler {

    /// Position tolerance for ladder step (a). A *position* tolerance, not a clock
    /// tolerance — being wrong inside it costs seconds of audio, not divergence.
    static let positionToleranceSeconds: Double = 5

    // MARK: - Entry point

    /// - Parameter baseline: `nil` when the client holds no `syncedVersion` for this
    ///   episode — the push carried the `baseVersion: 0` sentinel. See step (0).
    static func resolve(
        local: PlaybackSnapshot,
        baseline: PlaybackBaseline?,
        server: ServerPlaybackConflict,
        strategy: SyncStrategy
    ) -> PlaybackResolution {
        // Step (0) — no baseline ⇒ not a real row 4, and never a prompt. The client has
        // never agreed with the server on this episode, so "both sides changed since the
        // baseline" is an unfounded claim. Resolve once by legacy merge semantics; the
        // resulting ack establishes a baseline and every later conflict here is real.
        guard let baseline else {
            return settle(
                position: max(local.positionSec, server.positionSec),
                completed: local.completed || server.completed,
                local: local,
                server: server
            )
        }

        let completed = resolveCompleted(local: local, baseline: baseline, server: server)

        // (c) Both playing — each device keeps its own value. No prompt, no re-push, and
        // no version advance: this is the one outcome that deliberately stays dirty. It
        // is not "stop pushing" — the next cycle's ordinary push goes out with the same
        // stale baseline and conflicts again, silently, for as long as both play.
        if local.nowPlaying && server.nowPlaying {
            return .keepLocalSilently
        }

        switch positionWinner(local: local, server: server, strategy: strategy) {
        case .ask:
            return .prompt(localPosition: local.positionSec, serverPosition: server.positionSec)
        case .local:
            return settle(position: local.positionSec, completed: completed, local: local, server: server)
        case .server:
            return settle(position: server.positionSec, completed: completed, local: local, server: server)
        }
    }

    /// Client rule 3 + the wire contract: unknown ⇒ `0`, which the server reads as "I
    /// believe no row exists" and conflicts on. Distinct from an *omitted* `baseVersion`,
    /// which is the legacy last-write-wins path and not an escape hatch.
    static func baseVersionForPush(baseline: PlaybackBaseline?) -> Int64 {
        baseline?.syncedVersion ?? 0
    }

    // MARK: - `completed` — resolved first, and independently of position

    /// `completed` is a deliberate user action and it is the field that removes an
    /// episode from Up Next, so losing it is visible in a way seconds are not. The
    /// position ladder takes only `positionSec` and `nowPlaying`, so left to itself it
    /// would decide `completed` as a side effect of who was playing.
    ///
    /// Detection is still entirely the version — `syncedCompleted` never detects a
    /// conflict, it only **attributes** one. A version says *that* two sides diverged;
    /// it cannot say *which* one flipped a boolean.
    private static func resolveCompleted(
        local: PlaybackSnapshot,
        baseline: PlaybackBaseline,
        server: ServerPlaybackConflict
    ) -> Bool {
        guard local.completed != server.completed else { return local.completed }
        // Exactly one side can differ from the baseline here: booleans have two states,
        // so if local != server then one of them equals `syncedCompleted`. The side that
        // differs is the side that acted, and it wins. The other never touched the flag.
        return local.completed != baseline.syncedCompleted ? local.completed : server.completed
    }

    // MARK: - Position ladder (a)–(d)

    private enum PositionWinner { case local, server, ask }

    private static func positionWinner(
        local: PlaybackSnapshot,
        server: ServerPlaybackConflict,
        strategy: SyncStrategy
    ) -> PositionWinner {
        // (a) Within tolerance → take the larger, no prompt.
        if abs(local.positionSec - server.positionSec) <= positionToleranceSeconds {
            return local.positionSec > server.positionSec ? .local : .server
        }
        // (b) Exactly one side playing → the playing side wins, silently.
        if local.nowPlaying != server.nowPlaying {
            return local.nowPlaying ? .local : .server
        }
        // (d) Neither playing → the user's strategy. The prompt fires only here.
        switch strategy {
        case .deviceWins: return .local
        case .serverWins: return .server
        case .ask: return .ask
        }
    }

    // MARK: - Version bookkeeping

    /// The bookkeeping rules reduce to one comparison: if the resolved state is exactly
    /// what the server already holds, this is an adopt and `syncedVersion` becomes the
    /// server's version. Otherwise the device won something and MUST re-push it, using
    /// the version the *conflict* reported as the baseline — valid for that resolving
    /// push and nothing else. `syncedVersion` advances on its ack, never on receipt of
    /// the conflict payload, which would claim agreement on a value the server does not
    /// hold.
    ///
    /// The resolved state may be a combination neither device held — local position with
    /// the other side's `completed`. That is intended, and it is why the comparison is
    /// against both fields rather than position alone.
    private static func settle(
        position: Double,
        completed: Bool,
        local: PlaybackSnapshot,
        server: ServerPlaybackConflict
    ) -> PlaybackResolution {
        if position == server.positionSec && completed == server.completed {
            return .adoptServer(position: position, completed: completed, version: server.version)
        }
        return .rePushLocal(position: position, completed: completed, baseVersion: server.version)
    }
}

// MARK: - Value types

/// The device's current state for one episode.
struct PlaybackSnapshot: Sendable, Equatable {
    let positionSec: Double
    let completed: Bool
    let nowPlaying: Bool

    init(positionSec: Double, completed: Bool, nowPlaying: Bool) {
        self.positionSec = positionSec
        self.completed = completed
        self.nowPlaying = nowPlaying
    }
}

/// What the client last **agreed** with the server on, per episode.
///
/// Not values — with one named exception. `syncedCompleted` exists solely to attribute a
/// `completed` divergence to the side that caused it. Position is retained for nothing:
/// it survives only as conflict-sheet copy ("this device 12:04, other device 36:07").
struct PlaybackBaseline: Sendable, Equatable, Codable {
    let syncedVersion: Int64
    let syncedCompleted: Bool

    init(syncedVersion: Int64, syncedCompleted: Bool) {
        self.syncedVersion = syncedVersion
        self.syncedCompleted = syncedCompleted
    }
}

/// One entry of `conflicts[].server` from `POST /playback/sync`.
///
/// `nowPlaying` is required, not decorative — ladder steps (b) and (c) cannot be
/// evaluated without it.
struct ServerPlaybackConflict: Sendable, Equatable {
    let positionSec: Double
    let completed: Bool
    let nowPlaying: Bool
    let version: Int64

    init(positionSec: Double, completed: Bool, nowPlaying: Bool, version: Int64) {
        self.positionSec = positionSec
        self.completed = completed
        self.nowPlaying = nowPlaying
        self.version = version
    }
}

/// What to do about one row-4 conflict.
///
/// There is deliberately no "resolve by writing unconditionally" case: CAS retry
/// terminates in the table — adopt or prompt — never in an unconditional write. The
/// queue's retry ends at `baseVersion: nil`, a lost-update valve that is acceptable for
/// ordering and is exactly the silent clobber this exists to prevent for position.
enum PlaybackResolution: Sendable, Equatable {
    /// Take the server's values. `syncedVersion` becomes `version`; the episode is clean.
    case adoptServer(position: Double, completed: Bool, version: Int64)
    /// The device won. Re-push these values in the same cycle with this `baseVersion`.
    /// `syncedVersion` advances only when that push is acked.
    case rePushLocal(position: Double, completed: Bool, baseVersion: Int64)
    /// Ladder (c). Keep the local value, advance nothing, push nothing, say nothing.
    case keepLocalSilently
    /// Ladder (d) under `.ask`. Becomes one row in the batched conflict sheet — N
    /// conflicts in a cycle open one sheet with a list, not N sheets.
    case prompt(localPosition: Double, serverPosition: Double)
}

import Foundation
import OSLog

/// `POST /playback/sync` response consumption, per the sync contract.
///
/// `PlaybackReconciler` decides what to do about one row-4 conflict. This reads a whole
/// response, applies the reconciler per conflict, and owns the **version bookkeeping** —
/// which is the half that fails silently.
///
/// One rule governs everything here: **`syncedVersion` advances on an ack or on an adopt,
/// never on receipt of a `conflicts[]` entry.** A conflict reports a value the server holds
/// and this device has not accepted. Record it as agreement and the next ordinary push
/// carries a matching baseline, the server commits, and the contract's "each device keeps its own
/// value" degrades to last-write-wins — with no error, no failed request, and nothing in
/// the log to find weeks later when the position is wrong.
///
/// The work it emits is deliberately data, not effects: the caller does the writing, the
/// re-pushing, and the prompting. That keeps the decision — the part that is silent when
/// wrong — assertable without a network, a store, or an `AVPlayer`.
@MainActor
enum PlaybackSyncCoordinator {

    private static let logger = Logger(subsystem: "com.yourpods", category: "sync")

    /// CAS retry terminates in the table — adopt or prompt — never in an unconditional
    /// write and never in a spin. The queue's retry ends at `baseVersion: nil`, a
    /// lost-update valve that is acceptable for ordering and is exactly the silent clobber
    /// this exists to prevent for position.
    static let maxAttempts = 3

    // MARK: - Emitted work

    /// Take the server's values locally. The baseline has already been advanced.
    struct Adopt: Equatable {
        let episodeUrl: String
        let position: Double
        let completed: Bool
    }

    /// The device won. Push these values with this `baseVersion` — valid for the resolving
    /// push and nothing else. The baseline advances only when that push is acked.
    struct RePush: Equatable {
        let episodeUrl: String
        let position: Double
        let completed: Bool
        let baseVersion: Int64
    }

    /// Ladder (d) under `.ask`. Becomes one row in the batched conflict sheet — N conflicts
    /// in a cycle open one sheet with a list, not N sheets.
    struct Prompt: Equatable {
        let episodeUrl: String
        let localPosition: Double
        let serverPosition: Double
    }

    struct Outcome: Equatable {
        var adopts: [Adopt] = []
        var rePushes: [RePush] = []
        var prompts: [Prompt] = []

        var isEmpty: Bool { adopts.isEmpty && rePushes.isEmpty && prompts.isEmpty }
    }

    // MARK: - Entry point

    /// - Parameters:
    ///   - pushed: what this cycle asserted, keyed by `episodeUrl` **exactly as sent**.
    ///     This is the local side of row 4: the state we claimed, not whatever the player
    ///     has drifted to since, so the resolution is deterministic for the request it
    ///     answers. Drift is the next cycle's problem, and the next cycle will see it.
    ///   - attempt: 1 for the ordinary push; incremented per resolving re-push.
    static func apply(
        response: ProPlaybackSyncResponse,
        pushed: [String: PlaybackSnapshot],
        strategy: SyncStrategy,
        store: PlaybackBaselineStore,
        attempt: Int
    ) -> Outcome {
        var outcome = Outcome()

        for ack in response.accepted {
            // The server echoes `episodeUrl` byte-for-byte (rule 5). If it does not map to
            // something this cycle pushed, the echo did not round-trip and there is no
            // honest `completed` to record — and a guessed one corrupts the attribution
            // that resolves the *next* `completed` divergence.
            guard let local = pushed[ack.episodeUrl] else {
                logger.error("Ack for un-pushed episodeUrl (echo mismatch), skipping baseline: \(ack.episodeUrl)")
                continue
            }
            // Prefer the server's report of what the row ended up with (the sync contract's
            // server rule 8). Every push reaching this function carries a baseVersion, and a versioned
            // write is verbatim — so the asserted flag IS the landed one here, and the
            // fallback is exact. Taking the server's answer when it offers one keeps that
            // true by construction rather than by an argument about which arm ran, and
            // covers a server that has the field against a push that turns out not to be
            // verbatim after all.
            store.recordAgreement(
                episodeUrl: ack.episodeUrl,
                version: ack.version,
                completed: ack.completed ?? local.completed
            )
        }

        for conflict in response.conflicts {
            guard let local = pushed[conflict.episodeUrl] else {
                logger.error("Conflict for un-pushed episodeUrl, no local side to resolve against: \(conflict.episodeUrl)")
                continue
            }

            let resolution = PlaybackReconciler.resolve(
                local: local,
                baseline: store.baseline(for: conflict.episodeUrl),
                server: conflict.server.asPlaybackConflict,
                strategy: strategy
            )

            switch resolution {
            case let .adoptServer(position, completed, version):
                // Taking the server's value wholesale IS an agreement at that version.
                store.recordAgreement(episodeUrl: conflict.episodeUrl, version: version, completed: completed)
                outcome.adopts.append(Adopt(episodeUrl: conflict.episodeUrl, position: position, completed: completed))

            case let .rePushLocal(position, completed, baseVersion):
                guard attempt < maxAttempts else {
                    // Giving up is not agreeing: the baseline stays where it was, the row
                    // stays dirty, and the next cycle tries again from a clean attempt count.
                    logger.info("Playback CAS gave up after \(maxAttempts) attempts, leaving dirty: \(conflict.episodeUrl)")
                    continue
                }
                outcome.rePushes.append(RePush(
                    episodeUrl: conflict.episodeUrl,
                    position: position,
                    completed: completed,
                    baseVersion: baseVersion
                ))

            case .keepLocalSilently:
                // Ladder (c) — both playing. Advance nothing, push nothing, say nothing.
                logger.debug("Both devices playing, each keeps its own position: \(conflict.episodeUrl)")

            case let .prompt(localPosition, serverPosition):
                outcome.prompts.append(Prompt(
                    episodeUrl: conflict.episodeUrl,
                    localPosition: localPosition,
                    serverPosition: serverPosition
                ))
            }
        }

        if !response.accepted.isEmpty || !response.conflicts.isEmpty {
            store.persist()
        }

        return outcome
    }
}

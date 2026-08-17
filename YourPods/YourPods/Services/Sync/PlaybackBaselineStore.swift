import Foundation
import OSLog

/// Per-episode CAS baseline persistence, per the sync contract.
///
/// Answers exactly one question: **what `version` did this device last *agree* with the
/// server on for this episode?** That answer is what `baseVersion` carries on the next
/// push, and it is the entire basis of conflict detection in the sync contract.
///
/// "Agree" is narrow and load-bearing. A baseline is written on an **ack** (the server
/// committed our value and told us the resulting version) or on an **adopt** (we took the
/// server's value wholesale). It is never written on receipt of a `conflicts[]` entry:
/// that payload reports a value the server holds and we have *not* accepted, and recording
/// it would claim an agreement that does not exist — the next push would then match, the
/// write would land, and the contract's "each device keeps its own value" collapses into
/// last-write-wins churn with no error, no log line, and no failed request.
///
/// Keys are the `episodeUrl` **verbatim**, because the contract's server rule 5 echoes it back
/// byte-for-byte and it is the only key an ack can be mapped by. Normalizing it (percent
/// decoding, host case folding, dropping a query) sends the ack to a key nothing pushed,
/// leaves the real row's baseline stale, and re-conflicts it every cycle forever.
///
/// Scoped per profile for the same reason `actionMap` is: a `version` is a per-account row
/// counter, so one learned under another account is a meaningless integer that, if it
/// happens to match, authorizes a write this device never agreed to.
@MainActor
final class PlaybackBaselineStore {

    private let logger = Logger(subsystem: "com.yourpods", category: "sync")

    private let fileURL: URL
    private var baselines: [String: PlaybackBaseline] = [:]

    /// Profile-scoped path. The default (nil / "global") profile keeps the unsuffixed
    /// filename; named profiles get a `_<profileId>` suffix. Mirrors
    /// `EpisodeActionSyncService.actionMapFileURL(forProfile:)`.
    static func fileURL(forProfile profileId: String?) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let profileId, profileId != "global" {
            return appSupport.appendingPathComponent("playbackBaselines_\(profileId).json")
        }
        return appSupport.appendingPathComponent("playbackBaselines.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    convenience init(profileId: String?) {
        self.init(fileURL: Self.fileURL(forProfile: profileId))
    }

    var count: Int { baselines.count }

    // MARK: - Reading

    /// `nil` means "never agreed on this episode" — the caller pushes the `0` sentinel and
    /// any resulting conflict is resolved by step (0), never prompted.
    func baseline(for episodeUrl: String) -> PlaybackBaseline? {
        baselines[episodeUrl]
    }

    // MARK: - Writing

    /// Record an agreement. Call on an **ack** or an **adopt** — never on a conflict.
    func recordAgreement(episodeUrl: String, version: Int64, completed: Bool) {
        // An empty key would collide across every episode whose feed carries no enclosure
        // URL, so one ack would silently authorize writes for all of them.
        guard !episodeUrl.isEmpty else {
            logger.debug("Skipped baseline for empty episodeUrl (version \(version))")
            return
        }
        baselines[episodeUrl] = PlaybackBaseline(syncedVersion: version, syncedCompleted: completed)
    }

    /// Advance the version of an **existing** baseline, keeping its `syncedCompleted`.
    ///
    /// For an ack from a push that said nothing about completion — the episode-action log,
    /// which replays gPodder-shaped `play` rows with `completed: nil`. Those writes still
    /// bump the row's `version`, so ignoring their acks leaves every baseline stale from
    /// the first progress ping onward: the next versioned push is refused, and current
    /// server releases persist a refusal as a `sync_conflicts` row. The device would raise a
    /// sheet against its own progress reporting, once per sync, for as long as it played.
    ///
    /// `syncedCompleted` is preserved rather than assumed, and the server's merge is what
    /// makes that true: an action push sends `nowPlaying` absent (→ `false`) and `completed`
    /// absent (→ `false`), so the merge's `completed` CASE lands on
    /// `GREATEST(stored, false)` — the stored flag, unchanged. Recording `false` instead
    /// would misattribute the next completion divergence in the reconciler's ladder, which
    /// is the one thing `syncedCompleted` exists to get right.
    ///
    /// **Does nothing when no baseline exists.** With no prior agreement there is no
    /// `syncedCompleted` to preserve, and inventing one is the same misattribution. The
    /// episode keeps pushing the `0` sentinel until an ack that *does* carry a flag —
    /// step (0) resolves that first conflict without ever prompting, which is exactly what
    /// it is for.
    func advanceVersion(episodeUrl: String, version: Int64) {
        guard let existing = baselines[episodeUrl] else { return }
        guard version > existing.syncedVersion else { return }
        baselines[episodeUrl] = PlaybackBaseline(
            syncedVersion: version,
            syncedCompleted: existing.syncedCompleted
        )
    }

    /// Drop every baseline — sign-out and profile switch. Versions must not outlive the
    /// account that issued them.
    func clear() {
        baselines.removeAll()
        persist()
    }

    // MARK: - Persistence

    /// A baseline that only lives in memory is worse than none: the next cold start pushes
    /// `0`, the server conflicts, and step (0) resolves by legacy merge semantics — so the
    /// feature silently degrades to what it replaced while looking correct in one session.
    func persist() {
        do {
            let data = try JSONEncoder().encode(baselines)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist playback baselines: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            baselines = try JSONDecoder().decode([String: PlaybackBaseline].self, from: data)
            logger.debug("Loaded \(self.baselines.count) playback baselines")
        } catch {
            // Degrade to legacy LWW rather than crash the sync. Every episode re-establishes
            // a baseline on its next ack.
            logger.error("Failed to load playback baselines, starting empty: \(error.localizedDescription)")
            baselines = [:]
        }
    }
}

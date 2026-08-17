import Foundation
// AVFoundation has not audited AVMetadataItem for Sendable, even though
// AVFoundation's own `loadMetadata(for:)`/`load(.dataValue)` APIs are
// designed to hand these across the exact async/concurrent boundaries this
// file uses: `withTimeout` races every load — including each CHAP item's
// `dataValue` load in `chaptersFromID3Items` — inside its own `TaskGroup`,
// and `chaptersFromID3Items` itself is called into from an actor. Apple's
// own guidance for consuming an un-audited-but-safe-in-practice framework
// type this way is `@preconcurrency import`, which downgrades the
// compiler's Sendable diagnostics for AVFoundation types to warnings under
// this project's `targeted` strict-concurrency mode instead of leaving them
// silently unchecked.
@preconcurrency import AVFoundation
import os

/// Extracts chapters embedded in the audio file itself.
///
/// `podcast:chapters` is concentrated almost entirely in the Podcasting 2.0
/// community; mainstream shows that ship chapters embed them in the file. This
/// is the path that makes chapters (and chapter images) work for them.
///
/// HARD RULE — every AVAsset property is read via async `load(...)`, never a
/// synchronous getter. On iOS 26, `duration`, `availableChapterLocales`,
/// `availableMetadataFormats`, and `commonMetadata` each perform an XPC
/// round-trip to mediaserverd which, for indefinite-duration assets, returns
/// only after an internal ~20 s timeout — a severe main-thread hang, and a
/// watchdog kill if the app is backgrounded during it (SwiftAudioEx #105,
/// react-native-track-player #2665). The Simulator does NOT reproduce this;
/// a source-scanning guard test is the only enforcement that runs, so
/// this file is written as though that guard is already watching it.
actor EmbeddedChapterExtractor {

    static let shared = EmbeddedChapterExtractor()

    // `static`, not an instance `let`: `chaptersFromID3Items` and
    // `chaptersFromGroups` are both deliberately `nonisolated static func`s
    // (see their doc comments) so their blocking artwork work runs off the
    // actor's executor — an instance property would not be reachable from
    // there. `Logger` is a `Sendable` value type, so sharing one instance
    // across actor-isolated and nonisolated call sites is safe.
    //
    // Not `private`: those two functions live in
    // `EmbeddedChapterExtractor+Builders.swift` as a `static` extension (see
    // that file's header comment for why), and Swift's `private` is
    // same-FILE scoped even across extensions of one type — `internal`
    // (the default here) is the least-open access level that still reaches
    // across that file boundary within this module.
    static let logger = Logger(subsystem: "com.yourpods", category: "chapters")

    /// Containers known NOT to carry ID3 CHAP or MP4 chapter atoms. This is the
    /// only list `mayContainChapters` consults — see its doc comment for why a
    /// second "capable" allowlist was deliberately not added alongside it.
    private static let chapterIncapableExtensions: Set<String> = [
        "ogg", "oga", "opus", "wav", "flac", "wma", "aiff", "aif"
    ]

    /// Cheap pre-filter, NOT a safety mechanism — the async duration check in
    /// `chapters(for:)` is what actually protects against the iOS 26 hang.
    /// This function exists purely to skip constructing an asset for formats
    /// that structurally cannot carry chapters.
    ///
    /// Deliberately permissive and deny-list-only: an extension must be
    /// positively known to be incapable of carrying chapters to be rejected;
    /// everything else — including no extension at all — is allowed. Dynamic
    /// ad-insertion and tracking-prefixed URLs routinely carry no file
    /// extension, and rejecting those would silently disable chapters for
    /// exactly the mainstream shows most likely to embed them.
    ///
    /// A parallel "capable" allowlist (mp3/m4a/m4b/mp4/m4v/aac) was considered
    /// and dropped: every extension that list would accept is already accepted
    /// by "absent from the deny list," so a second list would only add a way
    /// for the two to silently drift out of sync with no test able to catch it.
    static func mayContainChapters(audioUrl: String) -> Bool {
        guard let url = URL(string: audioUrl) else { return false }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return true }   // extensionless: allow (DAI/tracking URLs)
        return !chapterIncapableExtensions.contains(ext)
    }

    /// Options dictionary for `AVURLAsset(url:options:)`, carrying auth headers
    /// for protected feeds. Pulled out as a pure function of value types so the
    /// header-attachment behavior is independently testable: `AVURLAsset`
    /// exposes no public getter for the options it was constructed with, so a
    /// test asserting on the asset itself cannot prove headers were attached.
    ///
    /// Uses the literal key, not the named `AVURLAssetHTTPHeaderFieldsKey`
    /// symbol — current SDKs export it from the AVFoundation binary for ABI
    /// compatibility but no longer declare it in public headers, so the name
    /// does not resolve at compile time. Mirrors the identical literal already
    /// used for authed playback in `AudioManager.swift:711`.
    static func assetOptions(for headers: [String: String]?) -> [String: Any] {
        guard let headers, !headers.isEmpty else { return [:] }
        return ["AVURLAssetHTTPHeaderFieldsKey": headers]
    }

    /// Builds the asset to read chapters from: the downloaded file when
    /// present (mirrors `AudioManager`'s local-file preference so we always
    /// parse from disk, not the network, once an episode is downloaded), else
    /// the remote URL with auth headers attached for protected feeds.
    ///
    /// Returns nil — rather than falling back to a placeholder path like
    /// `/dev/null` — when there is neither a local file nor a parseable remote
    /// URL. A fabricated asset that "succeeds" at construction but is backed by
    /// nothing real is worse than an explicit nil: it invites a caller to await
    /// `.load(.duration)` on it and reason about the result as if it came from
    /// a real file. `chapters(for:)`, the only caller, already guards against
    /// this exact case before calling in, so the nil here should never
    /// actually surface in production — it exists for callers that do not
    /// exist yet, so the contract is correct on its own terms.
    static func makeAsset(for item: QueueItem) -> AVURLAsset? {
        if let local = item.localFileUrl {
            return AVURLAsset(url: local)
        }
        guard let url = URL(string: item.audioUrl) else { return nil }
        let options = assetOptions(for: item.authHeaders)
        return AVURLAsset(url: url, options: options.isEmpty ? nil : options)
    }

    /// True iff `duration` is a real, positive, playable length. Extracted as
    /// a pure function so the exact guard is independently testable: `isNumeric`
    /// — the canonical one-shot check that rejects invalid, indefinite, AND
    /// ±infinite times together — is checked, and short-circuits, before
    /// `.seconds` is ever read. `CMTime.seconds` on any of those three states
    /// is NaN or ±infinity. An earlier version of this guard checked
    /// `isValid && !isIndefinite` by hand and missed `.positiveInfinity`:
    /// that value IS valid and IS NOT indefinite, so both hand-checks pass,
    /// and its `.seconds` (`+inf`) satisfies `> 0` — silently treating an
    /// infinite-duration asset as playable. `isNumeric` closes that gap by
    /// construction instead of enumerating every non-numeric CMTime state.
    static func isPlayableDuration(_ duration: CMTime) -> Bool {
        guard duration.isNumeric else { return false }
        return duration.seconds > 0
    }

    /// Chapters embedded in the audio file, or an empty array. Never throws:
    /// this is an enhancement, and the feed-sourced chain remains the fallback.
    func chapters(for item: QueueItem) async -> [Chapter] {
        guard !item.audioUrl.isEmpty || item.localFileUrl != nil else {
            Self.logger.debug("⟦CHAPTERS⟧ skip — no audio URL or local file")
            return []
        }
        // Pre-filter only applies to the remote URL; a downloaded episode is
        // already known-good and always proceeds regardless of audioUrl.
        guard item.localFileUrl != nil || Self.mayContainChapters(audioUrl: item.audioUrl) else {
            Self.logger.debug("⟦CHAPTERS⟧ skip — format cannot carry chapters: \(item.audioUrl)")
            return []
        }
        guard let asset = Self.makeAsset(for: item) else {
            Self.logger.debug("⟦CHAPTERS⟧ skip — could not construct asset: \(item.audioUrl)")
            return []
        }

        // THE hang guard. Indefinite duration (live streams, some HLS) is the
        // iOS 26 trigger condition — bail before touching any other metadata,
        // via the async `load(...)` API only. Never a synchronous getter.
        // Bounded by `headerLoadTimeout` — see that constant's doc comment
        // for why this is a per-CALLER latency bound, not a
        // protect-other-actor-callers mechanism (actors are reentrant;
        // there is nothing here to protect them from).
        guard let duration = await Self.withTimeout(seconds: Self.headerLoadTimeout, operation: {
            try await asset.load(.duration)
        }) else {
            Self.logger.debug("⟦CHAPTERS⟧ duration load failed or timed out: \(item.audioUrl)")
            return []
        }
        guard Self.isPlayableDuration(duration) else {
            Self.logger.debug("⟦CHAPTERS⟧ skip — indefinite or invalid duration: \(item.audioUrl)")
            return []
        }

        return await extract(from: asset, audioUrl: item.audioUrl)
    }

    /// Bound for the two SMALL, metadata-about-the-file loads: the duration
    /// load above and `availableMetadataFormats` below. Neither reads a
    /// payload of meaningful size, so this stays close to
    /// `AudioManager.artworkFetchTimeout` (8s) — this repo's existing
    /// precedent for "a degraded-but-present network must not hang a fetch
    /// for the OS default ~60s."
    ///
    /// This is a bound on how long the CALLER of `chapters(for:)` can be kept
    /// waiting, not a defense against blocking other actor callers.
    /// `EmbeddedChapterExtractor` is an actor, but Swift actors are
    /// reentrant: an actor-isolated method releases the actor at every
    /// `await`, so an unbounded load here was never capable of queuing other
    /// `chapters(for:)` calls behind it. The
    /// timeout is still worth having for the caller's own sake (chapter
    /// extraction is a background enhancement; nothing should wait 60s+ for
    /// it), and the actual on-actor-blocking hazard — synchronous work that
    /// does NOT hit an `await` — is what `chaptersFromID3Items` being a
    /// `nonisolated static func` guards against (see its doc comment).
    static let headerLoadTimeout: TimeInterval = 8

    /// Bound for the PAYLOAD load: `loadMetadata(for: .id3Metadata)`, which
    /// must read the entire ID3v2 tag to enumerate its frames (778,511 bytes
    /// in the committed fixture — measured, not assumed: see
    /// `chaptersFromID3Items`'s doc comment for why the per-item `dataValue`
    /// loads do NOT get their own network-shaped budget). `AudioManager
    /// .artworkFetchTimeout`'s 8s is a `URLRequest.timeoutInterval`, which is
    /// a PER-STALL IDLE timeout that resets on every chunk received — not a
    /// comparable precedent for `withTimeout` here, which is a hard TOTAL
    /// wall-clock deadline. Reusing 8s as a total deadline for a 778 KB
    /// payload would require ≥780 kbps sustained for the whole fetch, well
    /// above what "weak but present" means for the CarPlay case that 8s was
    /// tuned for, and would abort a slower-but-still-progressing connection
    /// that the per-stall precedent would have let finish. 30s is chosen
    /// instead: comfortably covers a sustained ≥210 kbps link fetching this
    /// fixture's tag end-to-end (0.778 MB × 8 / 30s ≈ 207 kbps), while still
    /// failing well inside the ~60s a user would tolerate waiting on a
    /// background enhancement.
    static let payloadLoadTimeout: TimeInterval = 30

    /// Races `operation` against `seconds`; returns nil on timeout AND on any
    /// thrown error — every call site here already treats a failed load as
    /// "skip, don't crash" (the prior code used `try?`/`catch` for the same
    /// outcome), so folding both into one nil keeps that contract unchanged.
    /// Relies on AVFoundation's async `load(...)` family observing Swift Task
    /// cancellation (documented Apple behavior for the continuation-based
    /// bridging behind these APIs), so the losing side of the race is
    /// cancelled rather than left running forever in the background —
    /// `withTaskGroup` will not return until it has, so this call can still
    /// exceed `seconds` by however long that cancellation takes to land.
    ///
    /// Not `private`, for the same cross-file reason as `logger` above:
    /// `chaptersFromID3Items` and `chaptersFromGroups` (in
    /// `EmbeddedChapterExtractor+Builders.swift`) both call this.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Container dispatch. MP3 goes through raw CHAP metadata items; MP4
    /// goes through `chaptersFromGroups` — the groups API is the only path
    /// that returns anything for that container (raw CHAP items are an
    /// ID3-only concept and return zero for MP4/M4A).
    ///
    /// This IS actor-isolated (an instance method, no `nonisolated`), and
    /// that's fine for everything it does directly: Swift actors are
    /// reentrant, so an actor-isolated method releases the actor at every
    /// `await` regardless of isolation — the `withTimeout` calls below never
    /// needed protecting from blocking other `chapters(for:)` callers,
    /// because there was never a way for them to do so. What DOES need to
    /// stay off the actor is `chaptersFromID3Items`'s SYNCHRONOUS work
    /// (`ChapterArtworkStore.store`'s ImageIO decode + JPEG encode + disk
    /// write, which has no internal `await` to reentrantly yield at) — see
    /// that function's doc comment for how `static` accomplishes that.
    private func extract(from asset: AVURLAsset, audioUrl: String) async -> [Chapter] {
        guard let formats = await Self.withTimeout(seconds: Self.headerLoadTimeout, operation: {
            try await asset.load(.availableMetadataFormats)
        }) else {
            Self.logger.debug("⟦CHAPTERS⟧ metadata formats load failed or timed out: \(audioUrl)")
            return []
        }

        if formats.contains(.id3Metadata) {
            if let metadata = await Self.withTimeout(seconds: Self.payloadLoadTimeout, operation: {
                try await asset.loadMetadata(for: .id3Metadata)
            }) {
                let chapters = await Self.chaptersFromID3Items(metadata, audioUrl: audioUrl)
                if !chapters.isEmpty {
                    Self.logger.info("⟦CHAPTERS⟧ embedded id3 count=\(chapters.count) url=\(audioUrl)")
                    return chapters
                }
            } else {
                Self.logger.debug("⟦CHAPTERS⟧ id3 metadata load failed or timed out: \(audioUrl)")
            }
        }

        // Fallback: the groups API. This is the ONLY path for MP4/M4A (raw
        // CHAP items are an ID3-only concept and don't exist for that
        // container), but this line is also reached for an MP3 that carries
        // `.id3Metadata` with no CHAP frames inside it (`chaptersFromID3Items`
        // returned `[]` above) — the container isn't re-checked here, so the
        // log marker below must stay container-agnostic ("embedded groups",
        // not "embedded mp4") or a diagnosis reading these logs would wrongly
        // conclude an MP3 was MP4.
        let chapters = await Self.chaptersFromGroups(asset, audioUrl: audioUrl)
        if !chapters.isEmpty {
            Self.logger.info("⟦CHAPTERS⟧ embedded groups count=\(chapters.count) url=\(audioUrl)")
        }
        return chapters
    }
}

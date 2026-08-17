import Foundation
import os

/// Chapters embedded in the audio file. Injected so tests need no AVFoundation.
protocol EmbeddedChapterProviding: Sendable {
    func chapters(for item: QueueItem) async -> [Chapter]
}

/// Chapters supplied by the feed. Injected so tests need no network.
protocol FeedChapterProviding: Sendable {
    func chapters(chaptersUrl: String?, chaptersJSON: String?, description: String?) async -> [Chapter]
}

extension EmbeddedChapterExtractor: EmbeddedChapterProviding {}

// Deliberately NOT `extension ChapterService: FeedChapterProviding {}` alone:
// `fetchAllChapters` has a defaulted `chaptersJSON` parameter, and this repo
// has a documented bug class (see memory notes
// `syncclient-witness-signatures-must-match` /
// `getcurrentplayback-protocol-witness-noop`) where a defaulted parameter on
// the wrapped method can stop a same-named conformance from witnessing,
// silently falling back to a protocol-extension no-op. Naming the witness
// method `chapters` (not `fetchAllChapters`) and forwarding every argument
// explicitly means there is no defaulted-parameter overload for the compiler
// to get confused between — either this method exists and is called, or the
// build fails to find a witness at all. `ChapterCoordinatorTests
// .test_defaultInit_wiresRealFeedProvider` (and, for the embedded side,
// `.test_defaultInit_wiresRealEmbeddedChapterExtractor`) pin this at runtime
// through the coordinator's real default initializer, not just at compile time.
extension ChapterService: FeedChapterProviding {
    func chapters(chaptersUrl: String?, chaptersJSON: String?, description: String?) async -> [Chapter] {
        await fetchAllChapters(chaptersUrl: chaptersUrl, chaptersJSON: chaptersJSON, description: description)
    }
}

/// The single owner of chapter state.
///
/// Before this existed, six call sites independently re-fetched chapters into
/// private @State, nothing owned `[Chapter]`, and no chapter-boundary event
/// existed — every `currentChapter` was a computed property SwiftUI
/// re-evaluated on position change, so nothing could react to a crossing.
@MainActor
@Observable
final class ChapterCoordinator {

    /// Lifecycle of `loadedItemId`'s resolution. A total state machine,
    /// deliberately NOT inferred from `chapters.isEmpty` (a *display*
    /// field): two earlier versions of this guard used `chapters.isEmpty`
    /// as a lifecycle proxy and each broke a different way — one wedged
    /// permanently (a failed/empty resolution could never retry), the other
    /// re-ran the fetch chain on every re-observation of an already-
    /// resolved, genuinely chapter-less item (the common case for most
    /// episodes). See `load(for:)` for the full history.
    private enum LoadState {
        case idle
        case loading(Task<Void, Never>)
        case resolved(producedChapters: Bool)
    }

    private(set) var chapters: [Chapter] = []
    private(set) var currentIndex: Int?

    /// Fired when playback crosses a chapter boundary. Every place that can
    /// change `currentIndex` (`updatePosition`, a cross-item switch, an
    /// item-becomes-nil clear, and `apply()`) routes through the single
    /// `setCurrentIndex` choke point, so this fires exactly on an ACTUAL
    /// transition — never redundantly re-announcing "no chapter" when there
    /// already was no chapter.
    ///
    /// This is a PLAIN CONSUMER SLOT — a single external observer, exactly
    /// like `AudioManager.onItemChanged`/`onPositionChanged`. `attach(to:)`
    /// never reads, wraps, or replaces it, in either direction:
    /// - Lock-screen chapter artwork (deliberately NOT a title-equality
    ///   heuristic, which couples chapter artwork to the "Publish Chapter
    ///   Titles" setting) is driven internally by a private hook installed
    ///   by `attach(to:)` and fired from `setCurrentIndex` ALONGSIDE this
    ///   callback — not through it.
    /// - No production site assigns this today: the chapter-display surfaces
    ///   (`NowPlayingBar`, `HomeView`, `EpisodeDetailSheet`, `CarPlayService`,
    ///   `SiriIntentHandler`) all ended up READING `visibleChapters` /
    ///   `currentChapter` directly rather than subscribing to a callback. The
    ///   slot is kept, and kept SAFE, for whatever future consumer does want
    ///   the boundary event: a consumer may assign this directly — including a
    ///   bare `= { ... }` that replaces whatever was here before — whether
    ///   before OR after `attach(to:)` runs, and either order is harmless to
    ///   lock-screen artwork, because artwork is not routed through this
    ///   property. (An earlier version of `attach(to:)` chained onto this
    ///   property directly; that meant a consumer assigning it AFTER
    ///   `attach(to:)` — the only order that could happen in production, since
    ///   `attach` runs first, in `YourPodsApp.init()` — would silently sever
    ///   the artwork wiring with no error. See `ChapterPlaybackWiringTests
    ///   .test_onChapterChanged_survivesConsumerAssignment_afterAttach`, which
    ///   pins that hazard closed.)
    ///
    /// If a second observer is ever needed, promote this to an observer list
    /// (e.g. `addChapterObserver(_:)`) rather than reintroducing chaining
    /// here — chaining is exactly the shape that caused the bug above.
    var onChapterChanged: ((Chapter?) -> Void)?

    private let embedded: EmbeddedChapterProviding
    private let feed: FeedChapterProviding
    private let logger = Logger(subsystem: "com.yourpods", category: "chapters")

    private var loadedItemId: String?
    private var state: LoadState = .idle

    /// How many times a resolution that came back with ZERO chapters may be
    /// retried within a SINGLE VISIT to an item, before this visit stops
    /// retrying. Matches this repo's existing "cap retries at 3, then stop"
    /// convention — the same cap the audio stream-error retry uses. NOT a
    /// permanent verdict: `emptyRetryCount` resets whenever the item
    /// changes away and back (see `load(for:)`'s cross-item branch), so a
    /// later visit gets its own fresh budget. Neither extreme is acceptable
    /// within one visit: unlimited retry re-runs the full AVAsset/network
    /// chain on every re-observation of a genuinely chapter-less episode
    /// (most episodes have none); zero retry means one transient failure —
    /// the embedded extractor's 8s AVAsset timeout, then an equally-failed
    /// feed fetch — hides chapters for an episode that DOES have them for
    /// the rest of THIS visit, with no retrigger, view reappearance,
    /// restore, or seek able to recover it before the visit ends. Residual
    /// hazard, inherent to any finite cap rather than a gap in this one:
    /// several transient failures in a row within one visit (e.g. offline
    /// for the whole visit) exhausts the budget and the item stays
    /// unretried until the NEXT visit — not solved here, just not hidden
    /// by the name.
    static let maxEmptyResolutionRetries = 3
    private var emptyRetryCount = 0

    /// Monotonic counter identifying each fetch ATTEMPT, independent of item
    /// id. `loadedItemId`/`state` alone can't distinguish two attempts at
    /// the SAME id: a switch away (A -> B) leaves A's in-flight attempt
    /// ORPHANED — cancelled (see `load(for:)`) but not necessarily stopped
    /// instantly, since cancellation is cooperative — and it can still be
    /// resolving in the background when a later, independent attempt at A
    /// (A -> B -> A) starts and finishes first. Only generation comparison
    /// in `apply` protects the fresher attempt's result from being clobbered
    /// by the orphaned one's late response — see
    /// `test_orphanedResponse_fromEarlierVisit...`.
    private var loadGeneration = 0

    init(embedded: EmbeddedChapterProviding = EmbeddedChapterExtractor.shared,
         feed: FeedChapterProviding = ChapterService.shared) {
        self.embedded = embedded
        self.feed = feed
    }

    var currentChapter: Chapter? {
        guard let currentIndex, chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    /// Chapters for display. Hidden chapters (CHAP frames absent from the CTOC,
    /// which exist to carry art) stay in `chapters` so time lookups resolve.
    /// Recomputed on every access rather than cached: chapter counts top out
    /// in the tens per episode, so filtering is negligible next to the async
    /// network/AVFoundation work already gating `chapters` itself, and a
    /// cached copy would be one more place to forget to invalidate.
    var visibleChapters: [Chapter] {
        chapters.filter { !$0.isHidden }
    }

    /// Resolve chapters for an item.
    ///
    /// Order: embedded → podcast:chapters JSON → inline Podlove → description.
    /// First non-empty source wins. Embedded ranks first because embedded
    /// chapters shift with dynamically-inserted ads and stay aligned with the
    /// audio actually playing, while feed timestamps drift. DO NOT reorder
    /// this without re-reading that rationale — it also sidesteps the
    /// titles-without-images trap for free: a feed supplying titles with no
    /// `img` can't mask embedded art, because embedded wins whenever it exists.
    ///
    /// Same-item semantics (deliberately never blanks `chapters`):
    /// - A call while the item is CURRENTLY resolving joins that in-flight
    ///   attempt (`Task.value`) instead of starting a redundant second fetch
    ///   — two `onItemChanged` firings in quick succession, or a restore/
    ///   seek landing mid-fetch, should cost exactly one fetch.
    /// - A call once the item resolved WITH real chapters is a permanent
    ///   no-op: a static audio file's chapters don't change, so there's
    ///   nothing to gain by refetching on every SwiftUI `.task` retrigger or
    ///   view reappearance.
    /// - A call once the item resolved to ZERO chapters retries, up to
    ///   `maxEmptyResolutionRetries` — see that constant's doc comment for
    ///   why neither "always retry" nor "never retry" is acceptable here.
    ///
    /// Cross-item semantics (a genuine switch to a DIFFERENT item):
    /// `chapters` clears synchronously, and any still-running attempt for
    /// the OUTGOING item is cancelled. The outgoing chapters aren't merely
    /// stale for the new item, they're WRONG — the coordinator indexes the new
    /// item's playback position against `chapters`, so leaving A's chapters
    /// in place while B's clock runs would resolve
    /// `currentChapter`/`onChapterChanged` against the wrong episode's
    /// boundaries. Cancelling the outgoing attempt matters independently of
    /// that correctness point: without it, rapidly switching through five
    /// episodes leaves five concurrent, uncancelled AVAsset/network loads
    /// running for episodes nobody is looking at anymore.
    ///
    /// Cancellation, and why joiners don't install their own handler: this
    /// call installs `withTaskCancellationHandler` around `task.value` ONLY
    /// when it just created `task` (the "originator"). A joiner (the
    /// in-flight branch above) does a plain `await task.value` with no
    /// handler of its own — a shared `Task` has exactly one cancellation
    /// flag, so if a joiner cancelled it too, that joiner's own governing
    /// context going away (e.g. its SwiftUI `.task` torn down) would cancel
    /// the fetch out from under the ORIGINATOR and any other joiner who may
    /// still need the result. This is a deliberate trade-off, not an
    /// oversight — building per-waiter reference-counted cancellation (only
    /// actually cancel once every joiner has given up) is disproportionate
    /// complexity for a coordinator where at most a couple of joiners are
    /// ever realistically concurrent (two `onItemChanged` firings for the
    /// same episode in quick succession).
    ///
    /// The asymmetry runs the OTHER way too, and this is a live hazard for
    /// the playback wiring below, not just a historical note: the ORIGINATOR's own
    /// cancellation DOES cancel the shared fetch for every joiner. When
    /// that happens, `markAborted` resets `state` to `.idle` and a
    /// surviving joiner's `load(for:)` call simply returns with `chapters`
    /// unchanged (typically still empty — a resolution with real chapters
    /// is terminal and never re-enters `.loading`) and no fetch actually
    /// happened for it on THIS call. No hang, no leak, no clobber —
    /// `state == .idle` makes a later call for the same item start a
    /// genuinely fresh, unbudgeted attempt (see `markAborted`) — but the
    /// surviving joiner gets nothing from the attempt it joined. This was
    /// tolerable when written, before `load(for:)` had any production
    /// callers; it no longer is (stale comment corrected in a later
    /// review): `attach(to:)` (below) polls position via
    /// `pollPosition(from:)`, which calls `load(for:)` directly, so an
    /// originator's view disappearing mid-fetch can silently starve any
    /// joiner riding along on that same attempt. This does NOT reach CarPlay:
    /// `CarPlayService`'s `seekToPreviousChapter`/`seekToNextChapter` READ
    /// `chapterCoordinator?.visibleChapters` — the already-resolved list —
    /// and never call `load(for:)` as a joiner, so there is no attempt for
    /// them to be starved of. A join branch that restarts (rather than
    /// returns) when it observes `state == .idle` after `task.value`
    /// resolves would close the joiner gap — not done here; it remains a
    /// known, accepted gap, not an oversight.
    /// `allowRemoteEmbeddedRead` gates ONLY the remote-asset embedded read.
    /// When `false` (the cold-launch seed) AND the episode is not downloaded
    /// (`localFileUrl == nil`), the embedded provider is skipped entirely and
    /// resolution goes straight to the feed sources — so a restored, not-yet-
    /// playing, undownloaded episode never triggers HTTP range reads of its
    /// audio headers at launch (the Global Constraint: never pre-parse embedded
    /// chapters for non-playing, undownloaded episodes). A DOWNLOADED episode
    /// still reads embedded chapters even when this is `false`: a local file
    /// read costs nothing. The play path passes `true`, so pressing Play always
    /// recovers embedded chapters the seed deferred (the empty-resolution retry
    /// budget above permits the same-item re-attempt). Feed chapters are always
    /// free (the feed is already fetched) and seed regardless of this flag.
    func load(for item: QueueItem?, allowRemoteEmbeddedRead: Bool = true) async {
        guard let item else {
            loadGeneration += 1
            if case .loading(let task) = state { task.cancel() }
            loadedItemId = nil
            state = .idle
            emptyRetryCount = 0
            setChapters([])
            return
        }

        if item.id == loadedItemId {
            switch state {
            case .loading(let task):
                // Join, don't duplicate. No cancellation handler here —
                // see the doc comment above for why only the originator
                // (below) is allowed to cancel the shared task.
                //
                // HAZARD FOR THE PLAYBACK WIRING: if the ORIGINATOR is cancelled while
                // this joiner is still awaiting, `task` aborts (see
                // `markAborted`) and this call returns with `chapters`
                // unchanged — this joiner gets nothing from this attempt,
                // though a later same-id call will retry fresh (`state`
                // resets to `.idle`, not `.resolved`). See the cancellation
                // doc comment above for the full reasoning.
                await task.value
                return
            case .resolved(let producedChapters):
                guard !producedChapters else {
                    logger.debug("⟦CHAPTERS⟧ skip — already resolved item=\(item.id)")
                    return
                }
                guard emptyRetryCount < Self.maxEmptyResolutionRetries else {
                    logger.debug("⟦CHAPTERS⟧ skip — empty-resolution retry budget exhausted item=\(item.id)")
                    return
                }
                emptyRetryCount += 1
                // Falls through to start a fresh attempt below. `chapters`
                // is already empty here (the prior resolution produced
                // nothing) — nothing to hold or clear.
            case .idle:
                break
            }
        } else {
            // Genuine switch: cancel any still-running attempt for the
            // OUTGOING item and clear immediately.
            if case .loading(let oldTask) = state { oldTask.cancel() }
            setChapters([])
            emptyRetryCount = 0
        }

        loadGeneration += 1
        let generation = loadGeneration
        loadedItemId = item.id

        let embedded = self.embedded
        let feed = self.feed
        let task = Task<Void, Never> { [weak self] in
            guard !Task.isCancelled else {
                self?.markAborted(generation: generation)
                return
            }
            // Skip the embedded read only when it would be a REMOTE read
            // (undownloaded) AND the caller opted out (the cold-launch seed).
            // A downloaded episode reads its local file regardless — that
            // costs nothing. See `load(for:allowRemoteEmbeddedRead:)`'s doc.
            let mayReadEmbedded = allowRemoteEmbeddedRead || item.localFileUrl != nil
            let embeddedChapters = mayReadEmbedded ? await embedded.chapters(for: item) : []
            if !mayReadEmbedded {
                self?.logger.debug("⟦CHAPTERS⟧ seed — deferring remote embedded read for undownloaded item=\(item.id); feed sources only")
            }
            if !embeddedChapters.isEmpty {
                // Deliberately no cancellation check here: the fetch is
                // already DONE (no more resource cost to save by
                // suppressing this), so deliver the result — `apply`'s
                // generation check remains the sole correctness gate,
                // exactly as it is for a non-cancelled call.
                self?.logger.info("⟦CHAPTERS⟧ source=embedded count=\(embeddedChapters.count) item=\(item.id)")
                self?.apply(embeddedChapters, generation: generation)
                return
            }
            guard !Task.isCancelled else {
                // Embedded came back empty AND we've since been cancelled:
                // don't start the feed chain's network fetch for an item
                // nobody is looking at anymore.
                self?.markAborted(generation: generation)
                return
            }

            // ChapterService already implements the remaining chain in order
            // (URL → inline JSON → description regex).
            let feedChapters = await feed.chapters(chaptersUrl: item.chaptersUrl,
                                                    chaptersJSON: item.chaptersJSON,
                                                    description: item.episodeDescription)
            self?.logger.info("⟦CHAPTERS⟧ source=feed count=\(feedChapters.count) item=\(item.id)")
            self?.apply(feedChapters, generation: generation)
        }
        state = .loading(task)

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func apply(_ newChapters: [Chapter], generation: Int) {
        // A newer load may have started (possibly for the same item id —
        // hence comparing generation, not id; see `loadGeneration`'s doc
        // comment for the orphaned-attempt case this guards against) while
        // we were awaiting.
        guard generation == loadGeneration else {
            logger.debug("⟦CHAPTERS⟧ discarding stale chapter load result, generation=\(generation) current=\(self.loadGeneration)")
            return
        }
        // Sorted defensively: real providers (`EmbeddedChapterExtractor`,
        // `ChapterService`) always return time-sorted chapters, but nothing
        // in the type system enforces that contract, and `updatePosition`'s
        // `lastIndex(where:)` silently resolves the WRONG chapter on
        // unsorted input — it picks by array position, not by time. Sorted
        // once here (per load), not per position tick — `ChapterNavigator`
        // already defends the identical predicate the same way, per-call,
        // because it has no persistent state to sort into ahead of time.
        //
        // Tie-break is EXPLICIT (decorate with original index, break ties on
        // it), not left to `sorted(by:)`'s stability: `sorted(by:)` is
        // documented as NOT guaranteed stable — it only behaves that way
        // today because small arrays take the standard library's
        // insertion-sort path. An episode with >20 chapters and duplicate
        // start times could order either way and this coordinator has
        // already paid for that exact trap once. Pinning
        // `test_currentIndex_tieBreaksTowardLaterDeclaredChapter_whenStartTimesMatch`
        // to "later-declared wins" requires this to be a genuine guarantee,
        // not an implementation accident.
        let sorted = newChapters
            .enumerated()
            .sorted {
                $0.element.startTime != $1.element.startTime
                    ? $0.element.startTime < $1.element.startTime
                    : $0.offset < $1.offset
            }
            .map(\.element)
        setChapters(sorted)
        state = .resolved(producedChapters: !newChapters.isEmpty)
    }

    /// A task bailed out early because it was cancelled before producing a
    /// result. Resets to `.idle` (not `.resolved`) rather than leaving
    /// `state` stuck at `.loading` a finished-but-never-cleared task forever
    /// — `.idle` means a future call for this item starts a genuinely fresh
    /// attempt. If this attempt was itself an empty-resolution retry,
    /// `emptyRetryCount` was ALREADY incremented (at the `.resolved` empty
    /// branch in `load(for:)`) before the task started, and this does not
    /// decrement it — but that leftover count is harmless, because the next
    /// same-item call now takes the `.idle` branch, which never consults the
    /// empty-retry budget at all (only the `.resolved` empty branch does).
    /// So an aborted attempt neither costs a confirmed empty resolution nor
    /// is blocked by one. Guarded by generation for the same reason `apply`
    /// is: a newer load may already have moved `state` on.
    private func markAborted(generation: Int) {
        guard generation == loadGeneration else { return }
        state = .idle
    }

    /// Structural pairing for the three sites that replace `chapters`
    /// wholesale (`load(for: nil)`, the cross-item switch, and `apply()`):
    /// assigning `chapters` WITHOUT also resetting `currentIndex` through
    /// `setCurrentIndex` is exactly what would reopen the cross-array
    /// index-equality hazard `setCurrentIndex` closes — "episode A at index
    /// 2" and "episode B, unrelated, also happens to resolve to index 2"
    /// must never be treated as the same chapter identity. Routing every
    /// `chapters` replacement through this one method makes a fourth,
    /// forgetful "assign chapters, then remember to reset the index" call
    /// site impossible, rather than relying on three sites to each remember
    /// the convention independently.
    private func setChapters(_ newChapters: [Chapter]) {
        chapters = newChapters
        setCurrentIndex(nil)
    }

    /// The single choke point for every place that can change
    /// `currentIndex` — `updatePosition`, and (via `setChapters` above) a
    /// cross-item switch, an item-becomes-nil clear, and `apply()` — so
    /// "fire `onChapterChanged` exactly on a crossing" is one invariant
    /// enforced once, not four call sites each independently re-deciding
    /// whether to notify. Gated on an ACTUAL transition (`newIndex !=
    /// currentIndex`): redundantly re-announcing "no chapter" when there
    /// was already no chapter is exactly the noise an artwork consumer
    /// would otherwise have to filter back out.
    ///
    /// Also the single choke point for the internal artwork hook
    /// (`chapterBoundaryHook`, installed by `attach(to:)`) — fired here
    /// ALONGSIDE `onChapterChanged`, never through it. See `onChapterChanged`'s
    /// own doc comment for why the two are kept structurally separate.
    ///
    /// `position` is purely for the log line — `updatePosition` is the only
    /// caller that has a real one; the three `setChapters` callers have no
    /// meaningful position to report, so it stays nil for those.
    private func setCurrentIndex(_ newIndex: Int?, position: TimeInterval? = nil) {
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
        let chapter = newIndex.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil }
        let positionSuffix = position.map { " @\($0)" } ?? ""
        logger.debug("⟦CHAPTERS⟧ boundary → \(chapter?.title ?? "none")\(positionSuffix)")
        chapterBoundaryHook?(chapter)
        onChapterChanged?(chapter)
    }

    /// Update the playback position and fire `onChapterChanged` if — and
    /// only if — this crosses a boundary.
    ///
    /// Edge-triggered on purpose: position ticks arrive about once a second,
    /// and firing per tick would rebuild Now Playing artwork continuously.
    ///
    /// Hidden chapters deliberately participate in this lookup: a CHAP frame
    /// absent from the CTOC exists precisely to carry art (see
    /// `Chapter.isHidden`), so crossing into one must still fire. Filter for
    /// DISPLAY only, via `visibleChapters` — never here, and never for any
    /// other time-based lookup against `chapters`.
    func updatePosition(_ position: TimeInterval) {
        guard !chapters.isEmpty else { return }
        // `chapters` is kept time-sorted by `apply()`, so the LAST index
        // satisfying "starts at or before `position`" is the chronologically
        // current chapter — not merely the last one in array order.
        let newIndex = chapters.lastIndex(where: { $0.startTime <= position })
        setCurrentIndex(newIndex, position: position)
    }

    // MARK: - Playback wiring

    /// True once `attach(to:)` has installed its callbacks. `attach(to:)` is
    /// meant to be called exactly once, from the app's composition root — a
    /// second call would re-wrap `onItemChanged` (and `onPositionChanged`)
    /// a SECOND time and reassign `chapterBoundaryHook` again, double-firing
    /// every downstream effect (two `applyChapterArtwork` calls per
    /// crossing, the existing-handler chain invoked twice, etc.). Enforced
    /// here — not just documented — so a future call site that accidentally
    /// attaches twice fails loudly (a logged no-op) instead of silently
    /// double-firing.
    private var isAttached = false

    /// Internal-only hook driving lock-screen chapter artwork. Installed by
    /// `attach(to:)`, fired by `setCurrentIndex` ALONGSIDE `onChapterChanged`
    /// — never through it, and never assigned to or read from that property.
    /// This is what makes `onChapterChanged` a genuinely harmless plain
    /// consumer slot: a consumer overwriting `onChapterChanged` (before or
    /// after `attach(to:)`) can never touch this. See `onChapterChanged`'s
    /// doc comment for the full rationale and the bug this replaced.
    private var chapterBoundaryHook: ((Chapter?) -> Void)?

    /// Wires this coordinator to live playback. Call ONCE, from the app's
    /// composition root — never from a per-view `.task`. `load(for:)`'s own
    /// doc comment explains why: its originator installs
    /// `withTaskCancellationHandler`, so a view whose `.task` created the
    /// load would cancel the SHARED fetch for every other joiner when that
    /// view disappears. `onItemChanged`'s wrap below is an un-cancelled,
    /// app-lifetime `Task` with no governing view context, so it can never
    /// be that view-teardown.
    ///
    /// Installs four things:
    /// 1. `audioManager.onItemChanged` wrapped (existing handler runs FIRST,
    ///    never dropped — `AudioManager.onItemChanged` already has a
    ///    production body: `PlayerManager` drives `syncPlaybackState` from
    ///    it, and `YourPodsApp` wraps it again for Watch/CarPlay/Live
    ///    Activity) to `load(for:)` the new item, then immediately resolve
    ///    position via `pollPosition(from:)` — see its doc comment for why
    ///    the immediate call matters (no chapter is current between a load
    ///    resolving and the next tick).
    /// 2. `chapterBoundaryHook` (a PRIVATE property, not `onChapterChanged`)
    ///    installed to push boundary crossings into
    ///    `audioManager.applyChapterArtwork`. Deliberately NOT implemented by
    ///    wrapping the public `onChapterChanged` — an earlier version did
    ///    exactly that ("existing handler runs first, never dropped", same
    ///    shape as (1) and (3) below), which protects a handler assigned
    ///    BEFORE `attach(to:)`. But `attach(to:)` runs first, in
    ///    `YourPodsApp.init()`, before any view exists — nothing is ever
    ///    assigned before it in production. The hazard that would matter runs
    ///    the OTHER way: any consumer that assigns `onChapterChanged` AFTER
    ///    `attach(to:)` has run would, with a plain
    ///    `chapterCoordinator.onChapterChanged = { ... }`, replace a wrapped
    ///    closure wholesale and silently sever lock-screen artwork with no
    ///    error. (No production site assigns `onChapterChanged` today — the
    ///    chapter-display surfaces read `visibleChapters`/`currentChapter`
    ///    directly — but the slot is public and kept safe for one that might;
    ///    see `onChapterChanged`'s own doc comment.) Firing this from a
    ///    separate private property, at the same `setCurrentIndex` choke
    ///    point `onChapterChanged` itself fires from, makes `onChapterChanged`
    ///    assignment harmless in BOTH directions.
    /// 3. `audioManager.onPositionChanged` wired directly to `updatePosition`
    ///    — fired from AudioManager's own `readyToPlay`-gated periodic time
    ///    observer (~0.5s cadence, `AudioManager.swift`'s
    ///    `setupPlayerObservers()`). Deliberately NOT routed through
    ///    `pollPosition(from:)`: by the time this fires, the current player
    ///    item is already `readyToPlay`, which can only happen well after
    ///    (1) already ran `load(for:)` for it — so `chapters` is already
    ///    correct for the current item, and re-running `load(for:)` on
    ///    every ~0.5s tick would needlessly burn the empty-resolution retry
    ///    budget (`maxEmptyResolutionRetries`, see its doc comment) for the
    ///    common case of a chapter-less episode — 4 complete
    ///    AVAsset-extraction-then-feed-fetch chains back to back instead of
    ///    1 — and log-spam `⟦CHAPTERS⟧ skip — already resolved` at 2 Hz for
    ///    the whole length of a chaptered episode, in the exact log channel
    ///    this feature is verified through.
    /// 4. A one-shot COLD-LAUNCH SEED, fired only when
    ///    `audioManager.currentItem` is already set at attach time.
    ///    `restoreQueue()` (from `PlayerManager.init`, before
    ///    `onItemChanged` is even assigned) restores `currentItem` by direct
    ///    property assignment, so no `onItemChanged` firing ever comes for it
    ///    and (1) would never load its chapters. This seeds them through the
    ///    same `pollPosition(from:)` primitive (1) uses, into a detached
    ///    `Task` so `attach(to:)` can stay synchronous — see the seed's own
    ///    inline comment below and
    ///    `ChapterPlaybackWiringTests
    ///    .test_attach_seedsChaptersForAlreadySetCurrentItem_coldLaunchRestore`.
    func attach(to audioManager: AudioManager) {
        guard !isAttached else {
            logger.debug("⟦CHAPTERS⟧ attach(to:) called again — ignoring, already attached")
            return
        }
        isAttached = true

        let existingOnItemChanged = audioManager.onItemChanged
        audioManager.onItemChanged = { [weak self, weak audioManager] item in
            existingOnItemChanged?(item)
            Task { @MainActor in
                guard let self, let audioManager else { return }
                await self.pollPosition(from: audioManager)
            }
        }

        chapterBoundaryHook = { [weak audioManager, weak self] chapter in
            // `loadedItemId` — the episode these chapters actually belong to
            // — NOT `audioManager.currentItem?.id`, which is whoever happens
            // to be current at this instant.
            //
            // Reading the live `currentItem` here made
            // `applyChapterArtwork`'s cross-episode guard a TAUTOLOGY: that
            // method re-compares the id it is handed against `currentItem?.id`,
            // and both reads happen in one synchronous MainActor turn with no
            // suspension between them, so the comparison could never fail and
            // the guard could never reject anything.
            //
            // The window it has to reject is real. `AudioManager.playEpisode`
            // assigns `currentItem = B` early (seeding Now Playing while
            // buffering) but fires `onItemChanged` — the sole trigger for
            // `load(for:)` — only at the very end, after `await
            // urlResolver.resolveUrl(...)` (a network HEAD, up to 5s) and
            // after `player.removeAllItems()`. Across that await the main
            // actor is released while A's player item is still installed and
            // playing, so the periodic time observer keeps firing
            // `onPositionChanged` with A's clock into `updatePosition` (wired
            // above with no `load(for:)` prefix — see this method's doc
            // comment, point 3) against chapters that are still A's. A tick
            // crossing an A-chapter boundary in that window therefore fires
            // this hook while `currentItem` already reads B; sourcing the id
            // from the live item would stamp A's chapter art onto B's Now
            // Playing entry as `.chapter` (the highest, non-upgradeable kind)
            // and bump `nowPlayingLoadToken`, killing B's own in-flight
            // artwork fetch. Streaming episodes only — the local-file branch
            // has no await in the window. Pinned by
            // `ChapterPlaybackWiringTests
            // .test_boundaryCrossing_afterCurrentItemAdvanced_doesNotPaintStaleChapterArtOntoTheNewEpisode`.
            //
            // No coordinator means no chapter to apply, so a nil `self` is a
            // plain early return rather than a call with a nil id.
            guard let audioManager, let self, let itemId = self.loadedItemId else { return }
            audioManager.applyChapterArtwork(
                key: chapter?.embeddedImageKey,
                chapterIndex: self.currentIndex,
                forItemId: itemId)
        }

        let existingOnPositionChanged = audioManager.onPositionChanged
        audioManager.onPositionChanged = { [weak self] position in
            existingOnPositionChanged?(position)
            self?.updatePosition(position)
        }

        // Cold-launch seed. `AudioManager.restoreQueue()` (called
        // from `PlayerManager.init`, BEFORE `audioManager.onItemChanged` is
        // even assigned — see `PlayerManager.init`) restores `currentItem`
        // via direct property assignment, never through
        // `playEpisode`/`onItemChanged`. By the time THIS method runs (later
        // still, in the app's composition root), a restored item can already
        // be sitting in `audioManager.currentItem` with no chapters loaded
        // and no future `onItemChanged` firing ever coming for it — the wrap
        // above only reacts to a NEW item change, not to state that was
        // already there when we attached. Seed it through the same
        // load-then-updatePosition primitive the wrap above uses
        // (`pollPosition(from:)`), so the restored episode's chapters and
        // chapter artwork resolve before the user ever taps Play.
        //
        // `attach(to:)` stays synchronous on purpose (an async signature
        // would ripple into the app's composition root, out of scope here),
        // so this is fired into a detached `Task` rather than awaited
        // in-line. `[weak self, weak audioManager]` matches the
        // `onItemChanged` wrap's capture list above for the same reason: a
        // stored/escaping closure or in-flight `Task` must never keep either
        // object alive past its natural lifetime.
        //
        // `allowRemoteEmbeddedRead: false` — the restored item is NOT playing
        // yet, so seeding must not spend the user's data. Feed chapters (already
        // fetched) still seed; a downloaded episode still reads its embedded
        // chapters locally; only the REMOTE embedded read of an undownloaded
        // episode is deferred to Play. See `load(for:allowRemoteEmbeddedRead:)`.
        if audioManager.currentItem != nil {
            logger.debug("⟦CHAPTERS⟧ attach(to:) seeding chapters for a currentItem already set at attach time (cold launch)")
            Task { @MainActor [weak self, weak audioManager] in
                guard let self, let audioManager else { return }
                await self.pollPosition(from: audioManager, allowRemoteEmbeddedRead: false)
            }
        }
    }

    /// Loads chapters for `audioManager.currentItem`, then immediately
    /// updates position — always in that order. `load(for:)`'s own
    /// cross-item branch clears `chapters` SYNCHRONOUSLY (before any
    /// `await`) the instant it detects a genuine item switch, so calling it
    /// first here means `updatePosition` can never evaluate a position
    /// against a DIFFERENT (outgoing) item's stale `chapters` — a call that
    /// lands in the gap between `AudioManager.currentItem` switching and
    /// this load actually running simply joins the same in-flight fetch (or
    /// observes the synchronous clear) instead of briefly attributing the
    /// wrong episode's chapter art to the new item's Now Playing entry.
    ///
    /// Used by `attach(to:)` in two places: its `onItemChanged` wrap, and the
    /// cold-launch seed, fired once into a detached `Task` from
    /// `attach(to:)` when `audioManager.currentItem` is already set at attach
    /// time — so it resolves AFTER `attach(to:)` has returned, not within it.
    /// Both are one-shot resolutions of "whatever
    /// `currentItem`/`currentPosition` are right now" — never assume a call
    /// here implies the item JUST changed. The continuous per-tick driver
    /// (`onPositionChanged`, also wired in `attach(to:)`) calls
    /// `updatePosition` directly, without this `load(for:)` prefix, because
    /// by the time it fires `chapters` is already known-correct for the
    /// current item (see `attach(to:)`'s doc comment, point 3).
    ///
    /// Not `private`: exposed so tests can invoke this sequence directly.
    ///
    /// `allowRemoteEmbeddedRead` defaults to `true` (the play path: you are
    /// starting this episode, so its asset loads anyway and reading embedded
    /// chapters costs nothing extra). The cold-launch seed passes `false` — see
    /// `load(for:allowRemoteEmbeddedRead:)` for what that gates and why.
    func pollPosition(from audioManager: AudioManager, allowRemoteEmbeddedRead: Bool = true) async {
        await load(for: audioManager.currentItem, allowRemoteEmbeddedRead: allowRemoteEmbeddedRead)
        updatePosition(audioManager.currentPosition)
    }
}

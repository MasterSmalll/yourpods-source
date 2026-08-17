import XCTest
@testable import YourPods

/// The wiring connecting `ChapterCoordinator` to `AudioManager` —
/// everything `attach(to:)` installs (see `ChapterCoordinator.swift`'s
/// "Playback wiring" section) plus `pollPosition(from:)`, the sequence
/// `attach(to:)`'s `onItemChanged` wrap uses.
///
/// This is deliberately a SEPARATE test file from `ChapterCoordinatorTests`
/// (which pins the coordinator's own state machine in isolation) and
/// `CarPlayOfflineNowPlayingTests` (which pins `applyChapterArtwork` in
/// isolation) — this file exists to prove the two are actually CONNECTED,
/// which neither of those can show on its own. The verification standard on
/// this feature: a well-tested helper that production never calls has
/// recurred multiple times, so every test here exercises the real `attach`/
/// `pollPosition` methods that `YourPodsApp.init()` actually calls, never a
/// hand-rolled equivalent.
@MainActor
final class ChapterPlaybackWiringTests: XCTestCase {

    // MARK: - Fakes (same shape as ChapterCoordinatorTests)

    private struct FakeEmbedded: EmbeddedChapterProviding {
        let result: [Chapter]
        func chapters(for item: QueueItem) async -> [Chapter] { result }
    }

    private struct FakeFeed: FeedChapterProviding {
        func chapters(chaptersUrl: String?, chaptersJSON: String?, description: String?) async -> [Chapter] { [] }
    }

    /// Returns different chapters per item id — needed to prove `pollPosition`
    /// re-resolves against the CORRECT item's chapters on a switch, which a
    /// same-result-for-every-item fake (`FakeEmbedded`) cannot distinguish.
    private struct KeyedEmbedded: EmbeddedChapterProviding {
        let results: [String: [Chapter]]
        func chapters(for item: QueueItem) async -> [Chapter] { results[item.id] ?? [] }
    }

    /// Records which item ids the embedded (remote/local file) provider was
    /// actually asked to read — the seam that proves the cold-launch seed
    /// does NOT trigger a remote embedded read for an undownloaded episode.
    /// `actor` (not a mutable class) because `load(for:)` awaits the provider
    /// from a non-`@MainActor` `Task` — the same pattern as `CountingEmbedded`
    /// in `ChapterCoordinatorTests`.
    private actor RecordingEmbedded: EmbeddedChapterProviding {
        let results: [String: [Chapter]]
        private(set) var askedFor: [String] = []
        init(results: [String: [Chapter]]) { self.results = results }
        func chapters(for item: QueueItem) async -> [Chapter] {
            askedFor.append(item.id)
            return results[item.id] ?? []
        }
    }

    /// A feed provider returning a fixed set for every episode.
    private struct FixedFeed: FeedChapterProviding {
        let result: [Chapter]
        func chapters(chaptersUrl: String?, chaptersJSON: String?, description: String?) async -> [Chapter] { result }
    }

    private func coordinator(_ chapters: [Chapter]) -> ChapterCoordinator {
        ChapterCoordinator(embedded: FakeEmbedded(result: chapters), feed: FakeFeed())
    }

    private func makeItem(id: String = "ep-1", positionSeconds: Int = 0) -> QueueItem {
        QueueItem(id: id, title: "Ep", podcastTitle: "Pod",
                  audioUrl: "https://unreachable.invalid/\(id).mp3", artworkUrl: nil,
                  durationSeconds: 3600, positionSeconds: positionSeconds,
                  podcastUrl: "https://e.g/feed", pubDate: nil)
    }

    private func threeChapters() -> [Chapter] {
        [Chapter(startTime: 0, title: "One"),
         Chapter(startTime: 60, title: "Two"),
         Chapter(startTime: 120, title: "Three")]
    }

    /// Bounded poll for an async condition — never a real-time sleep.
    private func poll(maxIterations: Int = 10_000, until condition: () -> Bool) async -> Bool {
        var i = 0
        while !condition() {
            guard i < maxIterations else { return false }
            i += 1
            await Task.yield()
        }
        return true
    }

    // MARK: - onItemChanged → load (hazard 5: append, don't replace)

    /// Breaking this: temporarily changing `attach`'s `onItemChanged` wrap to
    /// drop `existingOnItemChanged?(item)` turns this red — `existingFired`
    /// never flips to true. Confirmed by making that exact edit and
    /// observing the failure.
    func test_onItemChanged_preservesExistingHandler_andDrivesLoad() async {
        let manager = AudioManager()
        var existingFired = false
        manager.onItemChanged = { _ in existingFired = true }

        let sut = coordinator([Chapter(startTime: 0, title: "Only")])
        sut.attach(to: manager)

        let item = makeItem()
        // `pollPosition(from:)` (which the onItemChanged wrap now calls)
        // loads `audioManager.currentItem`, not the closure's `item`
        // parameter — matching real `playEpisode`, which always sets
        // `currentItem` BEFORE firing `onItemChanged` (never independently).
        // Omitting this line reproduces exactly that mismatch: `chapters`
        // stays empty because `load(for: nil)` runs instead of loading `item`.
        manager.currentItem = item
        manager.onItemChanged?(item)

        let loaded = await poll { !sut.chapters.isEmpty }
        XCTAssertTrue(loaded, "attach(to:) must drive load(for:) from onItemChanged")
        XCTAssertTrue(existingFired, "the pre-existing onItemChanged handler must still run — append, not replace")
    }

    // MARK: - hazard 3: immediate updatePosition once load resolves

    /// Breaking this: deleting the immediate `pollPosition(from:)` call from
    /// `attach`'s `onItemChanged` wrap turns this red — `currentChapter`
    /// stays nil after the poll times out, because nothing else calls
    /// `updatePosition` for a resumed episode until the NEXT real position
    /// tick from `AudioManager`'s periodic time observer. Confirmed by
    /// making that exact deletion and observing the failure.
    func test_onItemChanged_seedsCurrentChapterImmediately_resumingMidEpisode() async {
        let manager = AudioManager()
        // Offline + unreachable host: playEpisode still seeds currentPosition
        // and fires onItemChanged synchronously (see AudioManager.playEpisode),
        // but skips the real network URL-resolution request that would
        // otherwise make this test slow and host-dependent (matches
        // CarPlayOfflineNowPlayingTests' `makeOfflineManager()` pattern).
        manager.networkMonitor = MockNetworkMonitor(isConnected: false)
        let sut = coordinator(threeChapters())
        sut.attach(to: manager)

        // Resume at 90s — squarely inside chapter "Two" (60...120).
        let item = makeItem(positionSeconds: 90)
        await manager.playEpisode(item)   // real playEpisode: seeds currentPosition BEFORE firing onItemChanged

        let sawChapter = await poll { sut.currentChapter?.title == "Two" }
        XCTAssertTrue(sawChapter,
                      "resuming mid-episode must show the correct chapter immediately, not wait for the next position tick")
    }

    // MARK: - onChapterChanged → applyChapterArtwork

    /// Breaking this: changing `forItemId: itemId` to `forItemId: nil` in
    /// `attach`'s `onChapterChanged` wrap turns this red —
    /// `applyChapterArtwork`'s own guard (`guard let itemId, currentItem?.id
    /// == itemId`) rejects a nil id, so `currentArtworkChapterIndex` stays
    /// nil. Confirmed by making that exact edit and observing the failure.
    func test_onChapterChanged_pushesResolvedArtwork_intoAudioManager() async throws {
        let manager = AudioManager()
        let item = makeItem(id: "ch-wiring-\(UUID().uuidString)")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 1))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }

        let sut = coordinator([
            Chapter(startTime: 0, title: "One"),
            Chapter(startTime: 60, title: "Two", embeddedImageKey: key),
        ])
        sut.attach(to: manager)
        await sut.load(for: item)

        sut.updatePosition(90)   // crosses into "Two", which carries `key`

        XCTAssertEqual(manager.currentArtworkKind, .chapter)
        XCTAssertEqual(manager.currentArtworkChapterIndex, 1)
    }

    /// Crossing into a chapter with no art must fall back to episode art,
    /// not leave the previous chapter's art stuck on screen.
    func test_onChapterChanged_fallsBackToEpisodeArt_whenNewChapterHasNoArt() async throws {
        let manager = AudioManager()
        let item = makeItem(id: "ch-fallback-\(UUID().uuidString)")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 0))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }

        let sut = coordinator([
            Chapter(startTime: 0, title: "One", embeddedImageKey: key),
            Chapter(startTime: 60, title: "Two"),   // no art
        ])
        sut.attach(to: manager)
        await sut.load(for: item)

        sut.updatePosition(10)   // "One" — has art
        XCTAssertEqual(manager.currentArtworkKind, .chapter, "precondition: chapter art must be showing")

        sut.updatePosition(70)   // "Two" — no art, must fall back
        XCTAssertNotEqual(manager.currentArtworkKind, .chapter,
                          "crossing into an art-less chapter must clear the chapter artwork kind")
        XCTAssertNil(manager.currentArtworkChapterIndex)
    }

    // MARK: - onChapterChanged is a plain consumer slot (round 3 fix: attach must not occupy it)
    //
    // History: `attach(to:)` used to install the internal artwork wiring by
    // wrapping `onChapterChanged` itself ("existing handler runs first,
    // never dropped" — the same chain-don't-replace shape used for
    // `onItemChanged`/`onPositionChanged` above). That protected a consumer
    // that assigned `onChapterChanged` BEFORE `attach(to:)` ran. But
    // `attach(to:)` runs first, in `YourPodsApp.init()`, before any view
    // exists — nothing is EVER assigned before it in production. The real
    // hazard runs the other way: `onChapterChanged` has five
    // consumers, every one of which assigns it AFTER `attach(to:)` has
    // already run, and a plain `chapterCoordinator.onChapterChanged = { ... }`
    // replaces a wrapped closure wholesale — silently severing lock-screen
    // artwork with no error.
    //
    // A "preserves a pre-attach consumer" test (the previous version of this
    // section) does not catch that: it passes identically whether or not
    // `attach(to:)` even installs artwork wiring through `onChapterChanged`
    // at all, because nothing in this file's job — proving the ChapterCoordinator
    // <-> AudioManager CONNECTION — depends on assignment ORDER unless the
    // test actually assigns AFTER attach. It was also fully redundant with
    // `ChapterCoordinatorTests` (see its `onChapterChanged` firing tests,
    // e.g. around line 628), which already pins "a directly-assigned
    // `onChapterChanged` fires on a crossing" in isolation, with no `attach`
    // call at all. Deleted rather than kept as decorative coverage.
    //
    // The fix restructures instead of chaining harder: `attach(to:)` now
    // drives lock-screen artwork from a PRIVATE hook (`chapterBoundaryHook`)
    // fired by `setCurrentIndex` ALONGSIDE `onChapterChanged`, never through
    // it — see `ChapterCoordinator.onChapterChanged`'s doc comment. The test
    // below pins the actual production order and the actual hazard.

    /// A consumer assigning `onChapterChanged` AFTER `attach(to:)` — the ONLY
    /// order that ever happens in production, since `attach` runs first in
    /// `YourPodsApp.init()` — must not sever lock-screen chapter artwork.
    ///
    /// Verified RED against the pre-fix code (chaining `onChapterChanged`
    /// inside `attach`): this exact test failed with
    /// `currentArtworkKind == placeholder` (not `.chapter`) and
    /// `currentArtworkChapterIndex == nil`, because the post-attach
    /// assignment below replaced the wrapped closure wholesale, discarding
    /// the artwork call entirely. Passes after the fix because the artwork
    /// path (`chapterBoundaryHook`) no longer lives inside `onChapterChanged`
    /// at all, so overwriting the property cannot touch it.
    func test_onChapterChanged_survivesConsumerAssignment_afterAttach() async throws {
        let manager = AudioManager()
        let item = makeItem(id: "ch-post-attach-\(UUID().uuidString)")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 1))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }

        let sut = coordinator([
            Chapter(startTime: 0, title: "One"),
            Chapter(startTime: 60, title: "Two", embeddedImageKey: key),
        ])

        // Production order: attach FIRST (composition root), consumer
        // assignment SECOND (a view appearing later, e.g. the
        // NowPlayingBar) — never the reverse.
        sut.attach(to: manager)
        var consumerFired: String??
        sut.onChapterChanged = { chapter in consumerFired = chapter?.title }

        await sut.load(for: item)
        sut.updatePosition(70)   // crosses into "Two", which carries `key`

        XCTAssertEqual(manager.currentArtworkKind, .chapter,
                       "a consumer assigning onChapterChanged after attach(to:) must not sever lock-screen chapter artwork")
        XCTAssertEqual(manager.currentArtworkChapterIndex, 1)
        XCTAssertEqual(consumerFired, .some("Two"),
                       "the post-attach consumer itself must still fire — onChapterChanged is a real, working slot")
    }

    // MARK: - Cross-episode leak: the boundary hook must tag artwork with the
    //         episode the CHAPTERS belong to, not whoever is "current" right now
    //
    // `AudioManager.playEpisode` assigns `currentItem = B` early (to seed Now
    // Playing while buffering) and only fires `onItemChanged?(item)` — the sole
    // trigger for `load(for:)` — at the very END, after `await
    // urlResolver.resolveUrl(...)` (a network HEAD, up to 5s) and after
    // `player.removeAllItems()`. Throughout that await the main actor is
    // released, A's player item is STILL installed and playing, and the
    // periodic time observer keeps firing `onPositionChanged` with A's clock.
    // `attach(to:)` wires that straight to `updatePosition` (no `load(for:)`
    // prefix — see `attach(to:)`'s doc comment, point 3), and `chapters` is
    // still A's. So a tick crossing an A-chapter boundary during that window
    // fires the boundary hook while `currentItem` already reads B.
    //
    // Sourcing the id from `audioManager.currentItem` in the hook made
    // `applyChapterArtwork`'s cross-episode guard a TAUTOLOGY: both reads
    // happen in one synchronous MainActor turn with no suspension between, so
    // the id handed in always equalled the id compared against and the guard
    // could never reject. A's chapter art then landed on B's Now Playing entry
    // as `.chapter` (the highest, non-upgradeable kind) and bumped
    // `nowPlayingLoadToken`, killing B's own in-flight artwork fetch.
    //
    // Sourcing it from `loadedItemId` (the episode these chapters actually
    // belong to) makes the guard load-bearing.

    /// A position tick crossing one of episode A's chapter boundaries while
    /// `currentItem` has already advanced to episode B must NOT paint A's
    /// chapter art onto B.
    ///
    /// Discriminating: with the hook reading `audioManager.currentItem?.id`
    /// (the pre-fix wiring) this fails with `currentArtworkKind == .chapter`
    /// and `currentArtworkChapterIndex == 1`. Drives the real
    /// per-tick production path (`updatePosition`), not `pollPosition`, which
    /// clears synchronously and so can never exhibit the window.
    func test_boundaryCrossing_afterCurrentItemAdvanced_doesNotPaintStaleChapterArtOntoTheNewEpisode() async throws {
        let manager = AudioManager()
        let itemA = makeItem(id: "cross-A-\(UUID().uuidString)")
        let itemB = makeItem(id: "cross-B-\(UUID().uuidString)")

        // Real stored image: without this, `applyChapterArtwork`'s
        // `guard let image = ChapterArtworkStore.image(forKey:)` bails early
        // and the assertions below would hold even with the bug present.
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                          audioUrl: itemA.audioUrl, index: 1))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }

        let sut = coordinator([
            Chapter(startTime: 0, title: "A-One"),
            Chapter(startTime: 60, title: "A-Two", embeddedImageKey: key),
        ])
        manager.currentItem = itemA
        sut.attach(to: manager)
        await sut.load(for: itemA)

        sut.updatePosition(10)   // settled inside A's art-less first chapter
        XCTAssertNotEqual(manager.currentArtworkKind, .chapter,
                          "precondition: no chapter art showing yet")

        // The playEpisode window: `currentItem` is already B (seeded before
        // the URL-resolution await), but `onItemChanged` has not fired, so
        // `chapters` — and `loadedItemId` — are still A's.
        manager.currentItem = itemB

        // A's clock keeps ticking from A's still-installed player item and
        // crosses into A's SECOND chapter, which carries art.
        sut.updatePosition(90)

        XCTAssertNotEqual(manager.currentArtworkKind, .chapter,
                          "episode A's chapter art must never be applied to episode B's Now Playing entry")
        XCTAssertNil(manager.currentArtworkChapterIndex,
                     "a rejected cross-episode call must not record a chapter index against the new episode")
    }

    // MARK: - onPositionChanged → updatePosition (the real per-tick production hook)

    /// `AudioManager.onPositionChanged` (fired from its own `readyToPlay`-
    /// gated periodic time observer — see `AudioManager.swift`'s
    /// `setupPlayerObservers()`) is the actual continuous position driver in
    /// production; this simulates a tick by invoking the callback directly,
    /// the same trust boundary already used for `onItemChanged` firing from
    /// `manager.onItemChanged?(item)` above — the real `AVPlayer` observer
    /// itself is verified via `sim-verify`, not a unit test (no real decoded
    /// audio + readyToPlay wait in this suite).
    ///
    /// Breaking this: deleting `self?.updatePosition(position)` from
    /// `attach`'s `onPositionChanged` wrap turns this red — `currentChapter`
    /// never updates even though a position matching "Two" is delivered.
    /// Confirmed by making that exact edit and observing the failure.
    func test_onPositionChanged_drivesUpdatePosition() async {
        let manager = AudioManager()
        let sut = coordinator(threeChapters())
        sut.attach(to: manager)
        await sut.load(for: makeItem())

        manager.onPositionChanged?(90)   // simulates a real periodic-observer tick

        XCTAssertEqual(sut.currentChapter?.title, "Two",
                       "attach(to:) must wire AudioManager.onPositionChanged to drive updatePosition")
    }

    /// Same append-not-replace treatment as `onItemChanged`/`onChapterChanged`
    /// above, for the new `onPositionChanged` callback `attach(to:)` wires.
    func test_onPositionChanged_preservesExistingHandler() async {
        let manager = AudioManager()
        var existingFired = false
        manager.onPositionChanged = { _ in existingFired = true }

        let sut = coordinator([])
        sut.attach(to: manager)

        manager.onPositionChanged?(5)

        XCTAssertTrue(existingFired, "attach(to:) must preserve a pre-existing onPositionChanged handler")
    }

    // MARK: - pollPosition(from:): the load-then-updatePosition sequence attach uses

    func test_pollPosition_loadsThenUpdatesPosition_forCurrentItem() async {
        let manager = AudioManager()
        let item = makeItem(id: "poll-1")
        manager.currentItem = item
        manager.currentPosition = 65   // inside "Two"

        let sut = coordinator(threeChapters())
        await sut.pollPosition(from: manager)

        XCTAssertEqual(sut.currentChapter?.title, "Two",
                       "pollPosition must load the current item's chapters and resolve the current chapter")
    }

    /// The race this guards against: a call landing between `currentItem`
    /// switching and a load actually clearing `chapters` must not evaluate
    /// `updatePosition` against the OUTGOING item's stale chapters.
    /// `pollPosition` closes this by always calling `load(for:)` — which
    /// clears synchronously on a genuine item switch — before
    /// `updatePosition`.
    ///
    /// Pinned via the INTERMEDIATE `onChapterChanged` sequence, not just the
    /// final state — a prior version of this test asserted only
    /// `sut.currentChapter == nil` after the switch, which both orderings
    /// reach (broken: A's stale index 0→1 fires then load's clear fires
    /// 1→nil; correct: load's clear fires 0→nil, then `updatePosition`
    /// against B's now-empty `chapters` is a no-op) — same final value,
    /// making that assertion pass under EITHER ordering. Recording every
    /// firing distinguishes them: broken order fires TWICE (`"A2"` for the
    /// nonexistent chapter B is wrongly given, then `nil`); correct order
    /// fires ONCE (`nil`).
    ///
    /// Confirmed by temporarily reordering `pollPosition` to call
    /// `updatePosition` before `load(for:)` and observing this go red — the
    /// fired sequence under the swap was `["A2", nil]`.
    func test_pollPosition_onItemSwitch_reResolvesAgainstTheNewItemsChapters_notStaleOnes() async {
        let manager = AudioManager()
        let itemA = makeItem(id: "A")
        let itemB = makeItem(id: "B")
        let embedded = KeyedEmbedded(results: [
            "A": [Chapter(startTime: 0, title: "A1"), Chapter(startTime: 60, title: "A2")],
            "B": [],   // B genuinely has no chapters
        ])
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed())

        // Establish A's state via a real poll tick (the production path),
        // BEFORE installing the recorder — this is setup, not part of what's
        // being pinned.
        manager.currentItem = itemA
        manager.currentPosition = 30
        await sut.pollPosition(from: manager)
        XCTAssertEqual(sut.currentChapter?.title, "A1", "precondition: A's first chapter must be current")

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        // Switch item WITHOUT going through onItemChanged at all — simulating
        // a poll tick landing before any load-triggering handler has run.
        manager.currentItem = itemB
        manager.currentPosition = 90   // inside A's SECOND chapter's range (60...), if A's stale chapters were used
        await sut.pollPosition(from: manager)

        XCTAssertEqual(fired, [nil],
                       "a tick for B must clear straight to nil, never transiently fire A's stale second chapter first")
    }

    func test_pollPosition_withNoCurrentItem_clearsChapters() async {
        let manager = AudioManager()
        let sut = coordinator(threeChapters())
        await sut.load(for: makeItem())
        XCTAssertFalse(sut.chapters.isEmpty)

        manager.currentItem = nil
        await sut.pollPosition(from: manager)

        XCTAssertTrue(sut.chapters.isEmpty)
    }

    // MARK: - Retain cycle (called-out hazard: strong `self` in onChapterChanged)

    /// Breaking this: changing `onChapterChanged`'s capture list from
    /// `[weak audioManager, weak self]` to `[weak audioManager]` (implicitly
    /// capturing `self` strongly) turns this red — `weakSut` stays non-nil
    /// after `sut = nil`, because `audioManager.onItemChanged`'s closure
    /// (which the test still holds via `manager`) would keep the coordinator
    /// alive through its strong self-reference. Confirmed by making that
    /// exact edit and observing the failure.
    func test_attach_doesNotRetainCoordinator_viaItsOwnStoredClosures() {
        let manager = AudioManager()
        var sut: ChapterCoordinator? = coordinator([])
        weak var weakSut = sut

        sut?.attach(to: manager)
        sut = nil

        XCTAssertNil(weakSut, "attach(to:) must not leave the coordinator retained by its own stored closures")
    }

    // MARK: - Idempotency (Minor 5: attach must not silently re-wrap on a second call)
    //
    // `attach(to:)` guards against a second call with `isAttached` (returns
    // immediately, logged). This section is honest about the limits of what
    // could be VERIFIED here, not just what was fixed:
    //
    // The first version of this test asserted that a pre-existing
    // `onItemChanged` handler's call count stayed at 1 after two `attach`
    // calls — it PASSED even with the `isAttached` guard deleted entirely
    // (confirmed by actually deleting it and running the test), so it is
    // removed rather than left as decorative coverage. The reason it can't distinguish the two cases: chain-
    // wrapping (`existingHandler?(x); newBehavior()`) calls whatever was
    // there BEFORE exactly once no matter how many layers wrap it — a
    // second, un-guarded `attach` call adds a SECOND `newBehavior()` (a
    // second `Task { pollPosition }`, a second `applyChapterArtwork` call
    // per crossing), never a second call to the ORIGINAL pre-existing
    // handler. The `onItemChanged` side of that duplication is additionally
    // masked by `load(for:)`'s own (correct, separately-tested-in-
    // `ChapterCoordinatorTests`) same-item coalescing — two concurrent
    // `load(for: sameItem)` calls already collapse into one provider call
    // by design, so a provider-call-count assertion would read "1" whether
    // or not the idempotency guard exists. The `onChapterChanged` side's
    // duplication (a second `applyChapterArtwork` call with IDENTICAL
    // arguments to the first) produces no difference in `AudioManager`'s
    // public state either, and `AudioManager` is `final` — there's no seam
    // to count the raw call. Genuinely not unit-testable at this layer
    // without adding test-only instrumentation to production code, which
    // wasn't judged worth it for something the `isAttached` guard already
    // prevents structurally.
    func test_attach_secondCall_isANoOp_doesNotCrashOrBreakNormalOperation() async {
        let manager = AudioManager()
        let sut = coordinator([Chapter(startTime: 0, title: "Only")])
        sut.attach(to: manager)
        sut.attach(to: manager)   // second call — must be ignored, not crash

        let item = makeItem()
        manager.currentItem = item
        manager.onItemChanged?(item)

        let loaded = await poll { !sut.chapters.isEmpty }
        XCTAssertTrue(loaded, "a second attach(to:) call must not break normal chapter loading")
    }

    // MARK: - Cold-launch seed (attach(to:) must resolve an already-set currentItem)
    //
    // `AudioManager.restoreQueue()` (called from `PlayerManager.init`, BEFORE
    // `audioManager.onItemChanged` is even assigned — see
    // `PlayerManager.swift:122` vs `:125`) restores `currentItem` directly via
    // property assignment, never through `playEpisode`/`onItemChanged`.
    // `onItemChanged` is the sole driver of `load(for:)`, so on cold launch
    // the restored episode has no chapters until the user taps Play. `attach(to:)`
    // (which runs later still, in `YourPodsApp.init()`) must seed from whatever
    // `audioManager.currentItem` already holds at attach time — see
    // `ChapterCoordinator.attach(to:)`'s doc comment.

    /// Breaking this: removing the cold-launch seed from `attach(to:)` turns
    /// this red — `chapters` stays empty forever, because nothing ever fires
    /// `onItemChanged` for an item that was set by direct property assignment
    /// (restoreQueue's shape) before `attach` ran.
    func test_attach_seedsChaptersForAlreadySetCurrentItem_coldLaunchRestore() async {
        let manager = AudioManager()
        // Cold-launch shape: `currentItem`/`currentPosition` set directly,
        // exactly as `restoreQueue()` does — never via `playEpisode`, and
        // `onItemChanged` is never fired.
        //
        // DOWNLOADED item on purpose: the seed defers only REMOTE embedded
        // reads (the network policy — see the "must not spend data" section
        // below), so a downloaded restored episode still seeds its embedded
        // chapters at attach time (a local file read costs nothing). An
        // undownloaded item here would legitimately NOT seed embedded chapters
        // anymore — that case is covered by the network-policy tests below.
        let item = downloadedItem(positionSeconds: 90)
        manager.currentItem = item
        manager.currentPosition = 90

        let sut = coordinator(threeChapters())
        sut.attach(to: manager)

        // Poll on the FINAL state (currentChapter), not the intermediate
        // "chapters non-empty" state — matching
        // `test_onItemChanged_seedsCurrentChapterImmediately_resumingMidEpisode`'s
        // pattern above. `pollPosition`'s `load(for:)` then `updatePosition(...)`
        // both run inside the same seeded `Task`; polling on `chapters.isEmpty`
        // alone can observe the gap between the two (chapters populated,
        // `updatePosition` not yet run) and fail for a scheduling reason that
        // has nothing to do with whether the seed itself is correct.
        let resolved = await poll { sut.currentChapter?.title == "Two" }
        XCTAssertTrue(resolved,
                      "attach(to:) must seed chapters (and resolve position) for an item already set as currentItem at attach time (cold launch)")
    }

    /// A second `attach(to:)` call must not re-seed — pinned by switching
    /// `currentItem` to a DIFFERENT item between the two `attach` calls.
    ///
    /// A same-item second call (the previous version of this test) cannot
    /// discriminate: whether or not the `isAttached` guard exists, re-running
    /// the seed for the SAME item hits `load(for:)`'s own resolved-coalescing
    /// (an already-`.resolved(producedChapters: true)` item is a permanent
    /// no-op — see that method's doc comment), so both "guard present" and
    /// "guard absent" land on the identical final state. Using `KeyedEmbedded`
    /// (which returns genuinely different chapters per item id — see its doc
    /// comment above) to swap in item B before the second `attach(to:)` call
    /// breaks that tie: with the guard intact, the second call is a logged
    /// no-op, so item B's chapters are never loaded and `sut.chapters` stays
    /// exactly item A's. With the guard removed, the second call re-runs the
    /// cold-launch seed against whatever `currentItem` now is (item B), which
    /// `load(for:)`'s cross-item branch (`ChapterCoordinator.swift:274-280`)
    /// clears and replaces — a directly observable difference.
    ///
    /// Verified RED against the guard removed (temporarily bypassing the
    /// `isAttached` early-return in `attach(to:)`), then restored and
    /// reconfirmed green.
    func test_attach_secondCall_doesNotReSeed_whenCurrentItemChangedBetweenCalls() async {
        let manager = AudioManager()
        // Downloaded items: the seed reads embedded chapters at attach time
        // only for a local file (the network policy defers remote reads — see
        // the section below). This test is about the isAttached guard, not the
        // policy, so both items are downloaded to keep the seed's embedded read
        // in play.
        let itemA = downloadedItem(id: "A", positionSeconds: 90)
        let itemB = downloadedItem(id: "B", positionSeconds: 90)
        let embedded = KeyedEmbedded(results: [
            "A": [Chapter(startTime: 0, title: "A-One"), Chapter(startTime: 60, title: "A-Two")],
            "B": [Chapter(startTime: 0, title: "B-One")],
        ])
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed())

        // First attach: cold-launch shape for item A — currentItem/Position
        // set directly, exactly as restoreQueue() does.
        manager.currentItem = itemA
        manager.currentPosition = 90
        sut.attach(to: manager)
        let resolvedA = await poll { sut.currentChapter?.title == "A-Two" }
        XCTAssertTrue(resolvedA, "precondition: the first attach(to:) call must seed item A's chapters")

        // Swap currentItem to B by direct property assignment (never via
        // onItemChanged, matching the cold-launch shape) before the SECOND
        // attach(to:) call — simulating that call landing after the app has
        // already moved on to a different item.
        manager.currentItem = itemB
        sut.attach(to: manager)   // second call — isAttached guard must ignore this

        // A bare assertion immediately after the second attach(to:) call
        // would pass trivially either way: the (buggy, guard-removed) reseed
        // is fired into a detached Task that hasn't had a chance to run yet
        // at this point in the test's own execution. Poll for the DIVERGENT
        // condition instead, so a guard-removed run gets every opportunity to
        // manifest before we assert it didn't happen; with the guard intact
        // this condition never becomes true and the poll exhausts its budget
        // (a bounded, non-real-time loop — see the `poll` helper above).
        let divergedToItemB = await poll(maxIterations: 2_000) { sut.chapters.first?.title != "A-One" }
        XCTAssertFalse(divergedToItemB, "a second attach(to:) call must not re-seed for the new currentItem")
        XCTAssertEqual(sut.chapters.first?.title, "A-One",
                       "chapters must stay item A's — the isAttached guard must ignore the second attach(to:) call")
    }

    // MARK: - Cold-launch seed must not spend data (network policy)
    //
    // The seed exists so a restored episode shows chapters/artwork before Play.
    // But `EmbeddedChapterExtractor.chapters(for:)` builds a REMOTE asset and
    // does HTTP range reads for an undownloaded episode whose format passes the
    // pre-filter — so an unconditional seed spends cellular data at launch on an
    // episode the user has not started. The Global Constraint: "never pre-parse
    // embedded chapters for non-playing, undownloaded episodes." The fix keeps
    // the seed but makes it use FREE sources only for undownloaded episodes:
    // feed chapters (already fetched) always seed; the remote embedded read is
    // deferred to Play, when the asset loads anyway. Downloaded episodes
    // (localFileUrl != nil) read embedded chapters locally at seed time as
    // before — a local read costs nothing.

    private func remoteItem(id: String = "ep-1", positionSeconds: Int = 0) -> QueueItem {
        makeItem(id: id, positionSeconds: positionSeconds)   // localFileUrl == nil
    }

    private func downloadedItem(id: String = "ep-1", positionSeconds: Int = 0) -> QueueItem {
        var item = makeItem(id: id, positionSeconds: positionSeconds)
        item.localFileUrl = URL(fileURLWithPath: "/tmp/\(id).mp3")
        return item
    }

    /// Breaking this: removing the seed's `allowRemoteEmbeddedRead: false`
    /// argument (so the seed reads embedded chapters unconditionally) turns
    /// this red — `askedFor` then contains the undownloaded item's id.
    func test_coldLaunchSeed_undownloadedItem_doesNotDoRemoteEmbeddedRead_butSeedsFeedChapters() async {
        let manager = AudioManager()
        let item = remoteItem()
        manager.currentItem = item
        manager.currentPosition = 0

        let embedded = RecordingEmbedded(results: ["ep-1": [Chapter(startTime: 0, title: "Embedded")]])
        let sut = ChapterCoordinator(embedded: embedded,
                                     feed: FixedFeed(result: [Chapter(startTime: 0, title: "Feed")]))
        sut.attach(to: manager)

        // Feed chapters (free) still seed.
        let seeded = await poll { sut.chapters.first?.title == "Feed" }
        XCTAssertTrue(seeded, "the seed must still surface FEED chapters for an undownloaded restored episode")
        // The remote embedded read must NOT have happened.
        let asked = await embedded.askedFor
        XCTAssertFalse(asked.contains("ep-1"),
                       "the cold-launch seed must not do a remote embedded read for an undownloaded episode")
    }

    /// A DOWNLOADED restored episode reads embedded chapters locally at seed
    /// time (a local read costs nothing, and embedded ranks ahead of feed).
    func test_coldLaunchSeed_downloadedItem_readsEmbeddedChaptersLocally() async {
        let manager = AudioManager()
        let item = downloadedItem()
        manager.currentItem = item
        manager.currentPosition = 0

        let embedded = RecordingEmbedded(results: ["ep-1": [Chapter(startTime: 0, title: "Embedded")]])
        let sut = ChapterCoordinator(embedded: embedded,
                                     feed: FixedFeed(result: [Chapter(startTime: 0, title: "Feed")]))
        sut.attach(to: manager)

        let seeded = await poll { sut.chapters.first?.title == "Embedded" }
        XCTAssertTrue(seeded, "a downloaded restored episode must seed its embedded chapters (local read, no data cost)")
        let asked = await embedded.askedFor
        XCTAssertTrue(asked.contains("ep-1"),
                      "a downloaded episode's embedded chapters are read locally at seed time")
    }

    /// The PLAY path (onItemChanged) always reads embedded chapters, even for an
    /// undownloaded episode — you are playing it, so the asset loads regardless.
    func test_playPath_undownloadedItem_stillDoesEmbeddedRead() async {
        let manager = AudioManager()
        let embedded = RecordingEmbedded(results: ["ep-1": [Chapter(startTime: 0, title: "Embedded")]])
        let sut = ChapterCoordinator(embedded: embedded, feed: FixedFeed(result: []))
        sut.attach(to: manager)   // no currentItem yet → no seed

        let item = remoteItem()
        manager.currentItem = item
        manager.onItemChanged?(item)   // play path

        let loaded = await poll { sut.chapters.first?.title == "Embedded" }
        XCTAssertTrue(loaded, "the play path must read embedded chapters even for an undownloaded episode")
        let asked = await embedded.askedFor
        XCTAssertTrue(asked.contains("ep-1"), "the play path is not subject to the seed's remote-read deferral")
    }

    /// Upgrade path: the deferral of the remote embedded read is TEMPORARY, not
    /// a permanent block — a later ALLOWED load recovers the embedded chapters.
    ///
    /// Driven at the `load(for:allowRemoteEmbeddedRead:)` level, awaiting each
    /// call to completion, on purpose. Routing this through `attach` + a
    /// back-to-back `onItemChanged` (the seed Task and the play Task firing in
    /// the same synchronous stretch) is genuinely racy: if the play load lands
    /// while the seed's load is still in flight, it JOINS that in-flight
    /// (deferred) attempt via `load(for:)`'s same-item coalescing and recovers
    /// nothing until a later trigger. That race cannot happen in production —
    /// the seed runs at launch and its deferred load does no network, resolving
    /// long before the user taps Play — but a test that fires both immediately
    /// would be flaky. Awaiting each `load` in sequence tests the real upgrade
    /// semantics deterministically (both loads are the exact production calls,
    /// just sequenced rather than raced). The narrow production race is an
    /// accepted minor limitation.
    func test_deferredRemoteEmbeddedRead_isRecoveredByASubsequentAllowedLoad() async {
        let item = remoteItem()   // undownloaded
        // Embedded-only episode (no feed chapters): nothing free to fall back to.
        let embedded = RecordingEmbedded(results: ["ep-1": [Chapter(startTime: 0, title: "Embedded")]])
        let sut = ChapterCoordinator(embedded: embedded, feed: FixedFeed(result: []))

        // Seed-shaped load: the remote embedded read is deferred.
        await sut.load(for: item, allowRemoteEmbeddedRead: false)
        let askedAfterSeed = await embedded.askedFor
        XCTAssertFalse(askedAfterSeed.contains("ep-1"),
                       "the deferred load must not do the remote embedded read")
        XCTAssertTrue(sut.chapters.isEmpty,
                      "with feed empty and the embedded read deferred, the deferred load resolves to no chapters")

        // Play-shaped load: same item, remote read allowed. The empty-resolution
        // retry budget in `load(for:)` permits the re-attempt.
        await sut.load(for: item, allowRemoteEmbeddedRead: true)
        XCTAssertEqual(sut.chapters.first?.title, "Embedded",
                       "an allowed load recovers the deferred embedded chapters")
        let askedAfterPlay = await embedded.askedFor
        XCTAssertTrue(askedAfterPlay.contains("ep-1"), "the allowed load did the embedded read")
    }
}

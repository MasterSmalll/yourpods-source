import XCTest
@testable import YourPods

@MainActor
final class ChapterCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    private struct FakeEmbedded: EmbeddedChapterProviding {
        let result: [Chapter]
        func chapters(for item: QueueItem) async -> [Chapter] { result }
    }

    private struct FakeFeed: FeedChapterProviding {
        let result: [Chapter]
        func chapters(chaptersUrl: String?, chaptersJSON: String?, description: String?) async -> [Chapter] {
            result
        }
    }

    /// Counts calls and allows changing the result mid-test, so a test can
    /// prove the fetch chain did or didn't re-run, and that a retry can
    /// recover once a source starts returning real chapters. A genuine
    /// actor (not `@unchecked Sendable`) so both are race-free without any
    /// manual synchronization.
    private actor CountingEmbedded: EmbeddedChapterProviding {
        private var result: [Chapter]
        private(set) var callCount = 0
        init(result: [Chapter]) { self.result = result }
        func setResult(_ newResult: [Chapter]) { result = newResult }
        func chapters(for item: QueueItem) async -> [Chapter] {
            callCount += 1
            return result
        }
    }

    /// An `EmbeddedChapterProviding` fake whose calls can be independently
    /// suspended and resolved out of order, so tests can pin exact
    /// interleavings (two loads in flight at once, resolved in either
    /// order) without any real-time sleep. Calls for an item id NOT in
    /// `blocked` resolve immediately from `immediate`.
    ///
    /// Keyed by an incrementing call token rather than by item id: two
    /// calls for the SAME item id (e.g. an orphaned earlier attempt and a
    /// brand new later one, see `test_orphanedResponse_...`) must be
    /// resolvable independently — a dictionary keyed by id alone would
    /// silently drop the first call's continuation when the second call
    /// overwrote the slot, leaking it.
    private actor ControllableEmbedded: EmbeddedChapterProviding {
        private var nextToken = 0
        private var pending: [Int: CheckedContinuation<[Chapter], Never>] = [:]
        private(set) var callOrder: [(token: Int, itemId: String)] = []
        private var blocked: Set<String> = []
        private var immediate: [String: [Chapter]] = [:]

        var callCount: Int { callOrder.count }

        func block(_ id: String) { blocked.insert(id) }
        func setImmediate(_ id: String, _ chapters: [Chapter]) { immediate[id] = chapters }

        func chapters(for item: QueueItem) async -> [Chapter] {
            let token = nextToken
            nextToken += 1
            callOrder.append((token, item.id))
            guard blocked.contains(item.id) else {
                return immediate[item.id] ?? []
            }
            return await withCheckedContinuation { pending[token] = $0 }
        }

        /// Resolve the call at `index` (0-based, in call order) with `chapters`.
        /// Callers must guard on `assertReached` before calling this —
        /// indexing an unreached call traps the whole test bundle, not just
        /// the one test (see `assertReached`'s doc comment).
        func resolveCall(_ index: Int, with chapters: [Chapter]) {
            let token = callOrder[index].token
            pending[token]?.resume(returning: chapters)
            pending[token] = nil
        }

        /// Polls up to a bounded number of scheduler turns rather than
        /// looping forever, so a broken dedupe/coalescing regression fails
        /// fast and loud instead of hanging the run — this repo has no
        /// hosted CI to time that out, and an earlier version of this exact
        /// helper (unbounded `while callOrder.count < n { await Task.yield() }`)
        /// spun for ~110s against a real regression in this class before
        /// being caught only by manually killing the process.
        func waitForCallCount(_ n: Int, maxIterations: Int = 10_000) async -> Bool {
            var iterations = 0
            while callOrder.count < n {
                guard iterations < maxIterations else { return false }
                iterations += 1
                await Task.yield()
            }
            return true
        }
    }

    /// A cancellation-aware `EmbeddedChapterProviding` fake, standing in for
    /// `EmbeddedChapterExtractor`'s real AVFoundation `load(...)` calls
    /// (which DO observe Task cancellation per Apple's documented
    /// behavior — see that type's `withTimeout` doc comment). Polls for
    /// either cancellation or an explicit `finish(with:)` signal, bounded
    /// to 10k iterations so a broken build fails a `XCTAssertFalse`/
    /// `XCTAssertTrue` instead of hanging.
    private actor CancellationAwareEmbedded: EmbeddedChapterProviding {
        private(set) var sawCancellation = false
        private(set) var entered = false
        private var finishResult: [Chapter]?

        func finish(with chapters: [Chapter]) { finishResult = chapters }

        func chapters(for item: QueueItem) async -> [Chapter] {
            entered = true
            for _ in 0..<10_000 {
                if Task.isCancelled {
                    sawCancellation = true
                    return []
                }
                if let finishResult { return finishResult }
                await Task.yield()
            }
            return []
        }

        /// Polls up to a bounded number of scheduler turns for
        /// `chapters(for:)` to have actually started running, the same
        /// discipline as `ControllableEmbedded.waitForCallCount`: a fixed
        /// yield count either wastes time or, if too short on a slower
        /// run, makes the test flaky — this waits for the real event.
        func waitForEntry(maxIterations: Int = 10_000) async -> Bool {
            var iterations = 0
            while !entered {
                guard iterations < maxIterations else { return false }
                iterations += 1
                await Task.yield()
            }
            return true
        }
    }

    /// Turns `ControllableEmbedded.waitForCallCount`'s bounded result into a
    /// file/line-attributed test assertion AND a value callers must check.
    /// A failed `waitForCallCount` used to be asserted-and-ignored here,
    /// which let call sites fall through to `resolveCall(_:)` and index an
    /// unreached slot in `callOrder` — an out-of-bounds trap that crashes
    /// the whole test *bundle* (not just the failing test), silently
    /// losing every other test's result. Returning `Bool` forces every call
    /// site to `guard await assertReached(...) else { return }` instead.
    /// Deliberately NOT `@discardableResult`: that attribute is exactly
    /// what would let a future call site be written as a bare `await` with
    /// no compiler warning, reopening the same out-of-bounds-trap class
    /// this return value exists to close.
    private func assertReached(_ n: Int, on embedded: ControllableEmbedded,
                                file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let reached = await embedded.waitForCallCount(n)
        XCTAssertTrue(reached, "expected at least \(n) provider call(s)", file: file, line: line)
        return reached
    }

    /// Same shape as `assertReached`, for `CancellationAwareEmbedded`'s
    /// `waitForEntry`. Also deliberately not `@discardableResult`.
    private func assertEntered(_ embedded: CancellationAwareEmbedded,
                                file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let entered = await embedded.waitForEntry()
        XCTAssertTrue(entered, "expected the embedded fetch to start", file: file, line: line)
        return entered
    }

    private func makeItem(id: String = "guid-1") -> QueueItem {
        QueueItem(id: id, title: "Ep", podcastTitle: "Pod",
                  audioUrl: "https://e.g/ep.mp3", artworkUrl: nil,
                  durationSeconds: 3600, podcastUrl: "https://e.g/feed", pubDate: nil)
    }

    private func coordinator(embedded: [Chapter], feed: [Chapter]) -> ChapterCoordinator {
        ChapterCoordinator(embedded: FakeEmbedded(result: embedded),
                           feed: FakeFeed(result: feed))
    }

    // MARK: - Precedence

    func test_prefersEmbedded_overFeed() async {
        let sut = coordinator(
            embedded: [Chapter(startTime: 0, title: "Embedded", embeddedImageKey: "k")],
            feed: [Chapter(startTime: 0, title: "Feed", img: "https://e.g/f.jpg")])

        await sut.load(for: makeItem())

        XCTAssertEqual(sut.chapters.map(\.title), ["Embedded"])
    }

    func test_fallsBackToFeed_whenNoEmbedded() async {
        let sut = coordinator(
            embedded: [],
            feed: [Chapter(startTime: 0, title: "Feed", img: "https://e.g/f.jpg")])

        await sut.load(for: makeItem())

        XCTAssertEqual(sut.chapters.map(\.title), ["Feed"])
    }

    /// The titles-without-images trap: a feed supplying bare titles must not
    /// mask embedded chapters that carry art.
    func test_embeddedWithArt_beatsFeedTitlesWithoutArt() async {
        let sut = coordinator(
            embedded: [Chapter(startTime: 0, title: "E", embeddedImageKey: "k")],
            feed: [Chapter(startTime: 0, title: "F", img: nil)])

        await sut.load(for: makeItem())

        XCTAssertNotNil(sut.chapters.first?.embeddedImageKey)
    }

    func test_emptyWhenNoSourceHasChapters() async {
        let sut = coordinator(embedded: [], feed: [])

        await sut.load(for: makeItem())

        XCTAssertTrue(sut.chapters.isEmpty)
    }

    func test_clearsChapters_whenItemBecomesNil() async {
        let sut = coordinator(embedded: [Chapter(startTime: 0, title: "E")], feed: [])
        await sut.load(for: makeItem())
        XCTAssertFalse(sut.chapters.isEmpty)

        await sut.load(for: nil)

        XCTAssertTrue(sut.chapters.isEmpty)
        XCTAssertNil(sut.currentChapter)
    }

    // MARK: - Hidden chapters

    func test_visibleChaptersExcludesHidden_butChaptersRetainsThem() async {
        let sut = coordinator(embedded: [
            Chapter(startTime: 0, title: "Shown"),
            Chapter(startTime: 10, title: "Art only", isHidden: true),
            Chapter(startTime: 20, title: "Also shown"),
        ], feed: [])

        await sut.load(for: makeItem())

        XCTAssertEqual(sut.chapters.count, 3, "hidden chapters stay for time lookups")
        XCTAssertEqual(sut.visibleChapters.map(\.title), ["Shown", "Also shown"])
    }

    // MARK: - Cross-item switch clears immediately (not "hold until ready")

    /// A genuine switch to a DIFFERENT item must clear `chapters`
    /// synchronously, not hold the outgoing item's chapters until the new
    /// ones resolve. Blank is absent data; the outgoing item's chapters are
    /// WRONG data once attributed to the new item's identity — the
    /// coordinator indexes the new item's playback position against
    /// `chapters`, so holding A's array while B's clock runs would resolve
    /// `currentChapter`/`onChapterChanged` against the wrong episode's
    /// boundaries, driving wrong lock-screen artwork.
    func test_crossItemSwitch_clearsChaptersImmediately_ratherThanShowingWrongEpisode() async {
        let embedded = ControllableEmbedded()
        await embedded.setImmediate("A", [Chapter(startTime: 0, title: "A-chapter")])
        await embedded.block("B")
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))

        await sut.load(for: makeItem(id: "A"))
        XCTAssertEqual(sut.chapters.map(\.title), ["A-chapter"])

        let loadB = Task { await sut.load(for: makeItem(id: "B")) }
        guard await assertReached(2, on: embedded) else { return }

        XCTAssertTrue(sut.chapters.isEmpty,
                       "a genuine item switch must clear immediately, not show A's chapters while B is loading")

        await embedded.resolveCall(1, with: [Chapter(startTime: 0, title: "B-chapter")])
        await loadB.value

        XCTAssertEqual(sut.chapters.map(\.title), ["B-chapter"])
    }

    // MARK: - Same-item calls never blank chapters

    /// A same-id call for an item that already finished resolving with real
    /// chapters must never blank `chapters`, and must never refetch either
    /// — the "SwiftUI `.task` retrigger mid-playback" case that
    /// uninterrupted lock-screen artwork depends on. The `callCount` assertion
    /// is what actually pins `.resolved(producedChapters: true)` as
    /// terminal: without it, deleting the "already resolved with chapters"
    /// early-return would still leave `chapters` correct (a same-value
    /// refetch looks identical from the outside) while silently
    /// re-running a full AVAsset reload on every retrigger.
    ///
    /// The OTHER same-id path — joining an in-flight attempt — is covered
    /// by `test_concurrentLoads_forSameInFlightItem_coalesceIntoOneProviderCall`,
    /// not duplicated here: `chapters` can only be empty while joining (a
    /// resolution WITH chapters is terminal and never re-enters `.loading`
    /// for the same id), so a standalone "join must not blank chapters"
    /// assertion in that state would be unfalsifiable — true regardless of
    /// whether the join branch actually clears anything.
    func test_sameItemCall_alreadyResolvedWithChapters_neverBlanksOrRefetches() async {
        let resolvedEmbedded = CountingEmbedded(result: [Chapter(startTime: 0, title: "A-chapter")])
        let sut = ChapterCoordinator(embedded: resolvedEmbedded, feed: FakeFeed(result: []))
        let item = makeItem(id: "A")

        await sut.load(for: item)
        XCTAssertEqual(sut.chapters.map(\.title), ["A-chapter"])

        await sut.load(for: item)   // same id, already resolved — must be inert

        XCTAssertEqual(sut.chapters.map(\.title), ["A-chapter"],
                        "a same-id call for an already-resolved item must never blank chapters")
        let callCount = await resolvedEmbedded.callCount
        XCTAssertEqual(callCount, 1,
                        "an item that resolved WITH real chapters must never refetch — that resolution is terminal")
    }

    // MARK: - Bounded retry for an empty resolution

    /// An item that resolves to ZERO chapters must be retried on the next
    /// same-id call — up to `maxEmptyResolutionRetries`, within THIS visit
    /// — not marked chapter-less after a single attempt. Without this, one
    /// transient failure (the embedded extractor's 8s AVAsset timeout, then
    /// an equally-failed feed fetch) would hide chapters for an episode
    /// that genuinely has them for the rest of the visit — no retrigger,
    /// view reappearance, restore, or seek could recover it before the item
    /// changes away and back. Deliberately NOT named "...thenStopsPermanently":
    /// the budget is per-visit (`emptyRetryCount` resets on a genuine item
    /// switch, see `maxEmptyResolutionRetries`'s doc comment), not a
    /// lifetime verdict on the item. This directly replaces
    /// `test_repeatLoad_forItemWithNoChaptersAnywhere_doesNotRefetch` from
    /// an earlier round, whose "must not re-run the fetch chain" assertion
    /// is no longer correct: that was a real design reversal, not a rename.
    func test_emptyResolution_retries_upToBoundedLimit_thenStopsForThisVisit() async {
        let embedded = CountingEmbedded(result: [])
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))
        let item = makeItem(id: "A")

        // First attempt + the documented retry budget = the total number of
        // fetches a permanently-empty item should ever cost.
        let totalAttemptsBeforeExhaustion = 1 + ChapterCoordinator.maxEmptyResolutionRetries
        for _ in 0..<totalAttemptsBeforeExhaustion {
            await sut.load(for: item)
        }
        let countAtExhaustion = await embedded.callCount
        XCTAssertEqual(countAtExhaustion, totalAttemptsBeforeExhaustion,
                        "each call up to the retry budget should re-attempt the fetch chain")
        XCTAssertTrue(sut.chapters.isEmpty)

        // One more call beyond the budget must not fetch again.
        await sut.load(for: item)
        let countAfterBudgetExceeded = await embedded.callCount
        XCTAssertEqual(countAfterBudgetExceeded, countAtExhaustion,
                        "once the empty-resolution retry budget is exhausted, further calls must not refetch")
    }

    /// A retry within the budget must be able to RECOVER once the source
    /// starts returning real chapters — the actual point of allowing
    /// retries at all.
    func test_emptyResolution_retrySucceeds_ifChaptersBecomeAvailable() async {
        let embedded = CountingEmbedded(result: [])
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))
        let item = makeItem(id: "A")

        await sut.load(for: item)
        XCTAssertTrue(sut.chapters.isEmpty)

        await embedded.setResult([Chapter(startTime: 0, title: "Recovered")])
        await sut.load(for: item)   // within the retry budget

        XCTAssertEqual(sut.chapters.map(\.title), ["Recovered"],
                        "a retry within the empty-resolution budget must be able to recover once the source has real chapters")
    }

    /// A second call for the item CURRENTLY resolving (still in flight) must
    /// join that attempt rather than starting a second, redundant
    /// AVAsset/network fetch for the identical item — two `onItemChanged`
    /// firings in quick succession, or a restore/seek landing mid-fetch,
    /// should cost exactly one fetch, not two.
    func test_concurrentLoads_forSameInFlightItem_coalesceIntoOneProviderCall() async {
        let embedded = ControllableEmbedded()
        await embedded.block("A")
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))
        let item = makeItem(id: "A")

        let first = Task { await sut.load(for: item) }
        guard await assertReached(1, on: embedded) else { return }

        let second = Task { await sut.load(for: item) }

        // Bounded settle window: if coalescing were broken, a second
        // provider call would show up within a handful of scheduler turns.
        // This can only ever add ~200 yields, never hang.
        for _ in 0..<200 { await Task.yield() }
        let countBeforeResolve = await embedded.callCount
        XCTAssertEqual(countBeforeResolve, 1,
                        "a concurrent same-item load must coalesce onto the in-flight attempt, not spawn a second provider call")
        guard countBeforeResolve == 1 else { return }   // don't hang below on a known-broken build

        await embedded.resolveCall(0, with: [Chapter(startTime: 0, title: "A-chapter")])
        await first.value
        await second.value

        XCTAssertEqual(sut.chapters.map(\.title), ["A-chapter"])
    }

    // MARK: - Staleness across item switches

    /// A late response for an item we've since switched AWAY from must not
    /// clobber the current item's chapters. (Two in-flight loads for the
    /// SAME id can no longer happen — see the coalescing tests above — so
    /// the reachable staleness case is a cross-item one: A's fetch is still
    /// resolving when we switch to B; A's response arrives after B's.)
    func test_staleLoad_fromSupersededItem_doesNotClobberNewerItem() async {
        let embedded = ControllableEmbedded()
        await embedded.block("A")
        await embedded.block("B")
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))

        let loadA = Task { await sut.load(for: makeItem(id: "A")) }
        guard await assertReached(1, on: embedded) else { return }

        let loadB = Task { await sut.load(for: makeItem(id: "B")) }
        guard await assertReached(2, on: embedded) else { return }

        // Resolve the NEWER (current) item first...
        await embedded.resolveCall(1, with: [Chapter(startTime: 0, title: "B-chapter")])
        await loadB.value

        // ...then the OLDER, superseded item's response arrives late.
        await embedded.resolveCall(0, with: [Chapter(startTime: 0, title: "A-chapter")])
        await loadA.value

        XCTAssertEqual(sut.chapters.map(\.title), ["B-chapter"],
                        "a late response for an item we've switched away from must not clobber the current item's chapters")
    }

    /// A -> B -> A: the FIRST visit to A is still resolving in the
    /// background — orphaned, no longer tracked by the coordinator's
    /// in-flight task — once we move on to B. Coalescing only ever looks at
    /// the CURRENT in-flight attempt, so it can't see that orphaned one:
    /// returning to A starts a brand new, independent third attempt. Only
    /// generation comparison (not item-id comparison) can tell the orphaned
    /// first attempt's eventual, late response is stale once it arrives.
    func test_orphanedResponse_fromEarlierVisit_doesNotClobberLaterVisit_toSameItem() async {
        let embedded = ControllableEmbedded()
        await embedded.block("A")
        await embedded.block("B")
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))

        let loadA1 = Task { await sut.load(for: makeItem(id: "A")) }       // call 0
        guard await assertReached(1, on: embedded) else { return }

        let loadB = Task { await sut.load(for: makeItem(id: "B")) }        // call 1
        guard await assertReached(2, on: embedded) else { return }
        await embedded.resolveCall(1, with: [Chapter(startTime: 0, title: "B-chapter")])
        await loadB.value

        let loadA2 = Task { await sut.load(for: makeItem(id: "A")) }       // call 2 — independent of call 0
        guard await assertReached(3, on: embedded) else { return }
        await embedded.resolveCall(2, with: [Chapter(startTime: 0, title: "A-second-visit")])
        await loadA2.value

        XCTAssertEqual(sut.chapters.map(\.title), ["A-second-visit"])

        // The orphaned FIRST attempt at A finally resolves, late.
        await embedded.resolveCall(0, with: [Chapter(startTime: 0, title: "A-first-visit-stale")])
        await loadA1.value

        XCTAssertEqual(sut.chapters.map(\.title), ["A-second-visit"],
                        "an orphaned response from an earlier visit to the same item must not clobber a later visit")
    }

    // MARK: - Cancellation semantics (originator vs. joiner)

    /// The ORIGINATOR (the call that creates the shared fetch task) must
    /// have its own cancellation propagate into the fetch — the hard rule
    /// "awaiting a Task's value does NOT propagate cancellation"
    /// is exactly the gap an unstructured `Task {}` opens, which is why
    /// `load(for:)` wraps the originator's `await task.value` in
    /// `withTaskCancellationHandler`. This proves that wrapping actually
    /// works, not just that it compiles.
    func test_originatorCancellation_propagatesIntoEmbeddedFetch() async {
        let embedded = CancellationAwareEmbedded()
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))
        let item = makeItem(id: "A")

        let loadTask = Task { await sut.load(for: item) }
        guard await assertEntered(embedded) else { return }
        loadTask.cancel()
        await loadTask.value

        let sawCancellation = await embedded.sawCancellation
        XCTAssertTrue(sawCancellation,
                       "cancelling the originator's own task must propagate into the embedded fetch, not leave it running unstructured")
    }

    /// A JOINER's own cancellation must NOT cancel the shared fetch —
    /// otherwise a view tearing down while merely joining an in-flight
    /// attempt (not the one that started it) would cancel the fetch out
    /// from under the originator, or any other joiner, who may still need
    /// the result. See `load(for:)`'s doc comment for why only the
    /// originator installs `withTaskCancellationHandler`.
    func test_joinerCancellation_doesNotCancelSharedTask_forOriginatorOrOtherJoiners() async {
        let embedded = CancellationAwareEmbedded()
        let sut = ChapterCoordinator(embedded: embedded, feed: FakeFeed(result: []))
        let item = makeItem(id: "A")

        let originator = Task { await sut.load(for: item) }
        guard await assertEntered(embedded) else { return }

        let joiner = Task { await sut.load(for: item) }
        for _ in 0..<20 { await Task.yield() }   // let it actually join
        joiner.cancel()
        for _ in 0..<20 { await Task.yield() }   // give a wrongly-wired cancellation a chance to land

        let sawCancellationAfterJoinerCancel = await embedded.sawCancellation
        XCTAssertFalse(sawCancellationAfterJoinerCancel,
                        "a joiner's own cancellation must not cancel the shared fetch out from under the originator")

        await embedded.finish(with: [Chapter(startTime: 0, title: "A-chapter")])
        await originator.value
        await joiner.value

        XCTAssertEqual(sut.chapters.map(\.title), ["A-chapter"],
                        "the originator must still receive a real result after an unrelated joiner cancels")
    }

    // MARK: - Real wiring (defect class: untested default-argument wiring)

    /// Pins the FEED leg of the default initializer's wiring:
    /// `ChapterService.shared`. `audioUrl: ""` makes
    /// `EmbeddedChapterExtractor.chapters(for:)` return `[]` via its own
    /// first guard without ever touching AVFoundation — fast and
    /// deterministic — which forces the coordinator down to the feed path,
    /// so a real "Wired" result can only come from
    /// `ChapterService.shared.fetchAllChapters` genuinely parsing the
    /// inline Podlove JSON below.
    ///
    /// This does NOT pin the embedded leg — swapping `init`'s `embedded:`
    /// default for a no-op provider would leave this test green, since its
    /// embedded call is engineered to return `[]` either way. See
    /// `test_defaultInit_wiresRealEmbeddedChapterExtractor` for that leg.
    func test_defaultInit_wiresRealFeedProvider() async {
        let sut = ChapterCoordinator()
        let podloveJSON = #"[{"startTime": 0.0, "title": "Wired", "img": null, "url": null}]"#
        let item = QueueItem(id: "wiring-check-feed", title: "Ep", podcastTitle: "Pod",
                              audioUrl: "", artworkUrl: nil, durationSeconds: 3600,
                              podcastUrl: "https://e.g/feed", pubDate: nil,
                              chaptersJSON: podloveJSON)

        await sut.load(for: item)

        XCTAssertEqual(sut.chapters.map(\.title), ["Wired"],
                        "default init must dispatch through the real ChapterService, not a stub")
    }

    /// Pins the EMBEDDED leg of the default initializer's wiring:
    /// `EmbeddedChapterExtractor.shared`, against the real, committed
    /// `chapters-id3.mp3` fixture (9 real CHAP frames — see
    /// `EmbeddedChapterExtractorTests`). Embedded is the precedence WINNER
    /// (`test_prefersEmbedded_overFeed`), so this is the more important leg
    /// to prove is really wired: `test_defaultInit_wiresRealFeedProvider`
    /// alone stays green even if `init`'s `embedded:` default were swapped
    /// for a no-op provider (confirmed by doing exactly that).
    ///
    /// `XCTUnwrap`, not `XCTSkip`, on the fixture lookup: this is the only
    /// test pinning the embedded (precedence-winning) leg, and
    /// `chapters-id3.mp3` is a fixture already committed to the repo and
    /// used by `EmbeddedChapterExtractorTests` — its absence would be a
    /// packaging defect, not a legitimate reason to silently skip the one
    /// test that would catch it.
    func test_defaultInit_wiresRealEmbeddedChapterExtractor() async throws {
        let bundle = Bundle(for: type(of: self))
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: "chapters-id3", withExtension: "mp3"),
                                        "chapters-id3.mp3 must be a committed test fixture")
        let sut = ChapterCoordinator()
        var item = QueueItem(id: "wiring-check-embedded", title: "Ep", podcastTitle: "Pod",
                              audioUrl: "https://e.g/ep.mp3", artworkUrl: nil, durationSeconds: 3600,
                              podcastUrl: "https://e.g/feed", pubDate: nil)
        item.localFileUrl = fixtureURL

        await sut.load(for: item)

        XCTAssertEqual(sut.chapters.count, 9,
                        "default init must dispatch through the real EmbeddedChapterExtractor, not a stub")
    }

    // MARK: - Boundary events

    private func threeChapters() -> [Chapter] {
        [Chapter(startTime: 0, title: "One"),
         Chapter(startTime: 60, title: "Two"),
         Chapter(startTime: 120, title: "Three")]
    }

    func test_currentIndexTracksPosition() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem())

        let cases: [(position: TimeInterval, expected: Int?)] = [
            (0, 0), (30, 0), (59.9, 0), (60, 1), (61, 1), (119, 1), (120, 2), (5000, 2),
        ]

        for c in cases {
            sut.updatePosition(c.position)
            XCTAssertEqual(sut.currentIndex, c.expected, "position \(c.position)")
        }
    }

    /// EDGE: a first chapter starting after 0 leaves a gap with no chapter.
    func test_currentIndexNil_beforeFirstChapterStart() async {
        let sut = coordinator(embedded: [Chapter(startTime: 30, title: "Late")], feed: [])
        await sut.load(for: makeItem())

        sut.updatePosition(10)

        XCTAssertNil(sut.currentIndex)
        XCTAssertNil(sut.currentChapter)
    }

    func test_firesOnChapterChanged_onCrossing() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem())

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        sut.updatePosition(0)
        sut.updatePosition(60)
        sut.updatePosition(120)

        XCTAssertEqual(fired, ["One", "Two", "Three"])
    }

    /// Position ticks arrive ~1/s. Firing per tick would rebuild Now Playing
    /// artwork continuously — the event must be edge-triggered. Verified by
    /// deliberately breaking edge-triggering (dropping the `newIndex !=
    /// currentIndex` guard) and observing this go red.
    func test_doesNotFire_whenPositionMovesWithinChapter() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem())
        sut.updatePosition(0)

        var fireCount = 0
        sut.onChapterChanged = { _ in fireCount += 1 }

        sut.updatePosition(10)
        sut.updatePosition(20)
        sut.updatePosition(30)
        sut.updatePosition(59)

        XCTAssertEqual(fireCount, 0)
    }

    func test_firesOnBackwardCrossing() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem())
        sut.updatePosition(120)

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        sut.updatePosition(30)   // scrub back to chapter one

        XCTAssertEqual(fired, ["One"])
    }

    func test_firesNil_whenScrubbingBeforeFirstChapter() async {
        let sut = coordinator(embedded: [Chapter(startTime: 30, title: "Late")], feed: [])
        await sut.load(for: makeItem())
        sut.updatePosition(40)

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        sut.updatePosition(5)

        XCTAssertEqual(fired, [nil])
    }

    /// Hidden chapters carry art and must still be crossed into. Verified by
    /// deliberately swapping `chapters` for `visibleChapters` in the lookup
    /// and observing this go red.
    func test_hiddenChaptersParticipateInBoundaryEvents() async {
        let sut = coordinator(embedded: [
            Chapter(startTime: 0, title: "Shown"),
            Chapter(startTime: 60, title: "Art only", isHidden: true),
        ], feed: [])
        await sut.load(for: makeItem())
        sut.updatePosition(0)

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        sut.updatePosition(60)

        XCTAssertEqual(fired, ["Art only"])
    }

    func test_doesNotFire_whenNoChapters() async {
        let sut = coordinator(embedded: [], feed: [])
        await sut.load(for: makeItem())

        var fireCount = 0
        sut.onChapterChanged = { _ in fireCount += 1 }

        sut.updatePosition(10)
        sut.updatePosition(100)

        XCTAssertEqual(fireCount, 0)
    }

    // MARK: - Boundary events: defensive ordering

    /// Real providers (`EmbeddedChapterExtractor`, `ChapterService`) always
    /// return time-sorted chapters, but nothing in the type system enforces
    /// that contract, and `lastIndex(where:)` silently resolves the WRONG
    /// chapter on unsorted input — it picks by array position, not by time.
    /// "Correct" (startTime 30) is placed BEFORE "WrongIfUnsorted" (startTime
    /// 0) in the raw array on purpose: an unsorted `lastIndex` scan hits
    /// "WrongIfUnsorted" first (it's last in array order) and would return
    /// it, even though "Correct" is the chronologically current chapter at
    /// position 45. `ChapterNavigator` already defends against this exact
    /// hazard for the identical predicate (see its own internal `.sorted`).
    func test_updatePosition_resolvesCorrectly_evenWhenProviderReturnsUnsortedChapters() async {
        let sut = coordinator(embedded: [
            Chapter(startTime: 30, title: "Correct"),
            Chapter(startTime: 0, title: "WrongIfUnsorted"),
        ], feed: [])
        await sut.load(for: makeItem())

        sut.updatePosition(45)

        XCTAssertEqual(sut.currentChapter?.title, "Correct")
    }

    /// Two chapters sharing a startTime is unusual but not impossible in a
    /// malformed feed. `lastIndex` (not `firstIndex`) makes the tie-break
    /// deterministic — the later-declared entry wins — rather than silently
    /// depending on incidental array order once chapters are sorted. This is
    /// only a real guarantee, not an accident of small-array behavior,
    /// because `apply()` breaks ties EXPLICITLY on original array index
    /// rather than relying on `sorted(by:)`'s stability — which the standard
    /// library does not document or guarantee (see `apply()`'s comment).
    func test_currentIndex_tieBreaksTowardLaterDeclaredChapter_whenStartTimesMatch() async {
        let sut = coordinator(embedded: [
            Chapter(startTime: 60, title: "First declared"),
            Chapter(startTime: 60, title: "Second declared"),
        ], feed: [])
        await sut.load(for: makeItem())

        sut.updatePosition(60)

        XCTAssertEqual(sut.currentChapter?.title, "Second declared")
    }

    // MARK: - Boundary events: the two deferred items

    /// DEFERRED ITEM 1: a cross-item switch clears
    /// `chapters`/`currentIndex` synchronously in `load(for:)` but must also
    /// notify — otherwise an artwork consumer wired to `onChapterChanged`
    /// keeps showing the OUTGOING episode's chapter/art until the new item
    /// resolves. This also proves DEFERRED ITEM 2 doesn't double-fire:
    /// `apply()` resolving the new item's chapters must not re-announce nil
    /// a second time once the switch has already cleared it.
    func test_crossItemSwitch_firesNilExactlyOnce_notAgainWhenApplyResolves() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem(id: "A"))
        sut.updatePosition(30)   // currentIndex = 0 ("One")

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        await sut.load(for: makeItem(id: "B"))   // genuine switch; fakes resolve synchronously

        XCTAssertEqual(fired, [nil],
                        "must fire nil exactly once for the switch itself, not again when B's load resolves")
    }

    /// Firing nil when there was never a current chapter to begin with is
    /// exactly the noise the artwork consumer would otherwise have to
    /// filter back out — the switch must stay silent in that case.
    func test_crossItemSwitch_doesNotFire_whenLeavingWithNoCurrentChapter() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem(id: "A"))
        // no updatePosition call — currentIndex stays nil

        var fireCount = 0
        sut.onChapterChanged = { _ in fireCount += 1 }

        await sut.load(for: makeItem(id: "B"))

        XCTAssertEqual(fireCount, 0,
                        "switching away with no current chapter must not fire a redundant nil")
    }

    /// The item-becomes-nil clear (already implemented) must obey
    /// the same "actual transition only" rule as the other two clearing
    /// paths, for the same noise reason.
    func test_itemBecomesNil_firesNil_whenLeavingACurrentChapter() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem())
        sut.updatePosition(30)

        var fired: [String?] = []
        sut.onChapterChanged = { fired.append($0?.title) }

        await sut.load(for: nil)

        XCTAssertEqual(fired, [nil])
    }

    func test_itemBecomesNil_doesNotFire_whenNoCurrentChapter() async {
        let sut = coordinator(embedded: threeChapters(), feed: [])
        await sut.load(for: makeItem())
        // no updatePosition call — currentIndex stays nil

        var fireCount = 0
        sut.onChapterChanged = { _ in fireCount += 1 }

        await sut.load(for: nil)

        XCTAssertEqual(fireCount, 0)
    }
}

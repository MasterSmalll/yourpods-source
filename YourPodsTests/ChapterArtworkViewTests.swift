import XCTest
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import YourPods

final class ChapterArtworkViewTests: XCTestCase {

    /// `store()` writes real files into the simulator's Caches directory
    /// under UUID-unique keys (matching `ChapterArtworkStoreTests`'
    /// convention); clean them up so runs don't accumulate.
    private var keysToCleanUp: [String] = []

    override func tearDown() {
        for key in keysToCleanUp {
            ImageCacheStore.shared.cache.removeObject(forKey: key as NSString)
            ImageCacheStore.shared.removeFromDisk(key: key)
        }
        keysToCleanUp = []
        super.tearDown()
    }

    // MARK: - source(for:) precedence

    /// Precedence, tested through the resolver rather than the view body —
    /// SwiftUI view bodies are not directly assertable.
    func test_resolvesEmbeddedKey_beforeRemoteUrl() throws {
        let url = "https://e.g/pref-\(UUID().uuidString).mp3"
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 32),
                                                          audioUrl: url, index: 0))
        keysToCleanUp.append(key)
        let chapter = Chapter(startTime: 0, title: "C", img: "https://e.g/remote.jpg",
                              embeddedImageKey: key)

        let source = ChapterArtworkView.source(for: chapter)

        XCTAssertEqual(source, .embedded(key), "embedded art must win — it is already local")
    }

    func test_fallsBackToRemoteUrl_whenNoEmbeddedKey() {
        let chapter = Chapter(startTime: 0, title: "C", img: "https://e.g/remote.jpg")

        XCTAssertEqual(ChapterArtworkView.source(for: chapter),
                       .remote("https://e.g/remote.jpg"))
    }

    func test_fallsBackToRemote_whenEmbeddedKeyEvicted() {
        let chapter = Chapter(startTime: 0, title: "C", img: "https://e.g/remote.jpg",
                              embeddedImageKey: "chapterart:evicted-\(UUID().uuidString):0")

        XCTAssertEqual(ChapterArtworkView.source(for: chapter),
                       .remote("https://e.g/remote.jpg"),
                       "an evicted key must fall back rather than render nothing")
    }

    func test_noneWhenNeitherSourcePresent() {
        XCTAssertEqual(ChapterArtworkView.source(for: Chapter(startTime: 0, title: "C")), .none)
    }

    // MARK: - hasAnyDeclaredSource(for:) — the non-IO predicate
    //
    // `source(for:)` itself must never be called from a body that re-evaluates
    // per position tick (PlayerView's main artwork) — see its doc comment.
    // `hasAnyDeclaredSource(for:)` is the cheap substitute: no disk read, no
    // `ChapterArtworkStore` lookup, pure field checks.

    func test_hasAnyDeclaredSource_trueForEmbeddedKey_evenWithoutTouchingTheStore() {
        // A key is present but nothing was ever stored for it — a real disk
        // lookup (`source(for:)`) would say `.none`. The cheap predicate is
        // deliberately optimistic here (see its doc comment): it can't confirm
        // resolution without paying the exact cost it exists to avoid.
        let chapter = Chapter(startTime: 0, title: "C",
                              embeddedImageKey: "chapterart:never-stored-\(UUID().uuidString):0")
        XCTAssertTrue(ChapterArtworkView.hasAnyDeclaredSource(for: chapter))
    }

    func test_hasAnyDeclaredSource_trueForRemoteImg() {
        let chapter = Chapter(startTime: 0, title: "C", img: "https://e.g/remote.jpg")
        XCTAssertTrue(ChapterArtworkView.hasAnyDeclaredSource(for: chapter))
    }

    func test_hasAnyDeclaredSource_falseForEmptyRemoteImg_andNoEmbeddedKey() {
        let chapter = Chapter(startTime: 0, title: "C", img: "")
        XCTAssertFalse(ChapterArtworkView.hasAnyDeclaredSource(for: chapter))
    }

    func test_hasAnyDeclaredSource_falseWhenNeitherSourcePresent() {
        XCTAssertFalse(ChapterArtworkView.hasAnyDeclaredSource(for: Chapter(startTime: 0, title: "C")))
    }

    // MARK: - selection(forCurrentChapter:) — the shared player / mini-player gate

    // The full-screen player (`PlayerView`) and the mini-player thumbnail
    // (`NowPlayingBar`) must make the SAME decision about when to swap to
    // chapter art vs fall back to episode art, so both route through this one
    // gate rather than re-expressing `hasAnyDeclaredSource` inline (the
    // multi-call-site drift `ChapterCoordinator` exists to prevent). A `nil`
    // current chapter — or one that declares no artwork source — is `.episode`.
    // Table covers both directions (`.chapter`-expected and `.episode`-expected
    // rows) so no trivial always-one-value implementation can pass.
    func test_selection_forCurrentChapter() {
        let embedded = Chapter(startTime: 0, title: "Embedded", embeddedImageKey: "chapterart:x:0")
        let remote   = Chapter(startTime: 0, title: "Remote", img: "https://example.com/img.jpg")
        let emptyImg = Chapter(startTime: 0, title: "EmptyImg", img: "")
        let bare     = Chapter(startTime: 0, title: "Bare")

        let cases: [(name: String, chapter: Chapter?, expected: ChapterArtworkView.Selection)] = [
            ("nil current chapter falls back to episode",        nil,      .episode),
            ("embedded key shows chapter art",                   embedded, .chapter(embedded)),
            ("remote img shows chapter art",                     remote,   .chapter(remote)),
            ("empty img and no embedded key falls to episode",   emptyImg, .episode),
            ("no source at all falls back to episode",           bare,     .episode),
        ]

        for c in cases {
            XCTAssertEqual(
                ChapterArtworkView.selection(forCurrentChapter: c.chapter),
                c.expected,
                c.name
            )
        }
    }

    // MARK: - `body` actually follows the resolver's precedence
    //
    // History on this feature (four times now, confirmed a fifth time by
    // review on this exact task): a well-tested helper that production
    // never calls, with a fully green suite. The four `source(for:)` tests
    // above call the static resolver directly and never touch `body` — they
    // would keep passing even if `body`'s embedded branch, remote branch,
    // or both were deleted outright. Each of the three render tests below is
    // scoped to pin exactly one branch, and each was confirmed to fail when
    // that specific branch is deleted (not just reasoned about — each branch
    // was actually deleted and the red/green transition observed). A fourth
    // render test (evicted embedded key falls through to the remote branch)
    // was tried and deleted: `content`'s "still loading" placeholder and
    // `CachedAsyncImage`'s placeholder are the exact same `placeholder`
    // view value, so a center-pixel/alpha assertion can't distinguish
    // "genuinely reached the remote branch" from "stuck in the loading
    // branch forever" — confirmed by sabotage: permanently widening the
    // loading-branch condition to swallow evicted keys (never falling
    // through to remote) left that test green. The eviction-fallback
    // behavior is still covered at the `source(for:)` level
    // (`test_fallsBackToRemote_whenEmbeddedKeyEvicted`).
    //
    // Each render test below uses a DIFFERENT `size`. This is load-bearing,
    // not style: an experiment reproduced `ImageRenderer` returning a stale
    // bitmap from an unrelated prior render when two `ImageRenderer`
    // instances in the same process requested identical pixel dimensions
    // back to back — a sabotaged (dead) remote branch stayed GREEN paired
    // with a same-size prior render, and turned correctly RED the moment
    // the size differed, with nine other hypotheses (`.id(UUID())`,
    // `AnyView` erasure, avoiding a shared helper's call site, a second
    // `.uiImage` read, `@State` provenance tracking) tried first and ruled
    // out. The exact mechanism is NOT diagnosed — "reuses its backing
    // buffer independent of view identity/state/content" is stated more
    // strongly than the evidence supports (that framing would break
    // `ImageRenderer` for any repeated fixed-size render, which is
    // implausible on its face, and `GlassEnvironmentSafetyTests` elsewhere
    // in this codebase uses the identical technique without apparently
    // hitting it). What's actually load-bearing here is narrower and
    // empirically confirmed: distinct sizes made the specific reproduction
    // above go away. The mitigation is also only file-local (every render
    // test in *this* file uses a different size) for an effect the
    // reproduction suggests is process-wide, and it's enforced by this
    // comment, not the compiler — the next render test added to this file
    // (or any other) can silently reopen it by reusing a size already in
    // use somewhere else in the process.

    /// Pins the embedded branch: a chapter with a real stored embedded
    /// image, and a deliberately unreachable remote URL also present so a
    /// body that ignores the embedded key (or silently prefers remote)
    /// cannot pass by accident. Renders via `ImageRenderer` (the technique
    /// `GlassEnvironmentSafetyTests` already uses in this codebase) and
    /// samples the center pixel.
    ///
    /// Asserts channel *ordering* (b > g > r, each by a wide margin) rather
    /// than matching the fixture's absolute RGB values. `ImageRenderer`'s
    /// device-RGB → display pipeline was measured to drift raw channel
    /// values by ~18 in one run (confirmed empirically, not assumed) — a
    /// colorspace conversion artifact, not evidence of wrong image data.
    /// Ordering survives any such drift as long as it doesn't invert
    /// relative channel magnitudes, which a uniform gamma/gamut shift never
    /// does. The fixture's own channels (51, 153, 229) are ~76-178 apart,
    /// so this still can't be satisfied by any shade of grey (where
    /// r == g == b) — same anti-grey guarantee the abandoned tolerance-based
    /// version had, without inheriting its fragility to renderer changes.
    @MainActor
    func test_body_rendersEmbeddedArtwork_whenStoreHasImage() throws {
        let url = "https://e.g/body-embedded-\(UUID().uuidString).mp3"
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 32),
                                                          audioUrl: url, index: 0))
        keysToCleanUp.append(key)
        let chapter = Chapter(startTime: 0, title: "C", img: "https://e.g/must-not-be-used.jpg",
                              embeddedImageKey: key)

        let center = try renderedCenterPixel(of: ChapterArtworkView(chapter: chapter, size: 40, cornerRadius: 4))

        XCTAssertGreaterThan(Int(center.b), Int(center.g) + 40, "expected the fixture's blue-dominant embedded artwork")
        XCTAssertGreaterThan(Int(center.g), Int(center.r) + 40, "expected the fixture's blue-dominant embedded artwork")
    }

    /// Pins the remote branch: a chapter with *only* a remote URL (no
    /// embedded key at all). `CachedAsyncImage` starts every render in its
    /// `placeholder()` state before its own `.task(id: url)` can complete a
    /// network fetch — and the URL here is unreachable/nonexistent, so that
    /// fetch can never complete synchronously within the render regardless.
    /// The placeholder is opaque (`.quaternary` fill); asserting alpha > 0
    /// distinguishes "the remote branch ran and drew something" from
    /// "nothing rendered" without depending on any color value at all —
    /// this is the test that catches Important-1-class regressions (the
    /// remote branch quietly deleted, or `body` falling straight to the
    /// blank `.none` slot for a chapter that actually has art).
    @MainActor
    func test_body_showsPlaceholder_whenOnlyRemoteUrlPresent() throws {
        let chapter = Chapter(startTime: 0, title: "C",
                              img: "https://e.g/unreachable-\(UUID().uuidString).jpg")

        let center = try renderedCenterPixel(of: ChapterArtworkView(chapter: chapter, size: 41, cornerRadius: 4))

        XCTAssertGreaterThan(center.a, 0, "a chapter with only a remote URL must render the remote branch's placeholder, not blank space")
    }

    /// Pins the `.none` branch: no embedded key, no remote URL. Asserts
    /// both that nothing is drawn (alpha == 0 — the assertion the
    /// tolerance-based color check never actually made; `Color.red`,
    /// `placeholder`, or `EmptyView()` would all have kept a color-only
    /// assertion green here) and that the reserved-space decision
    /// (`ChapterArtworkView` still occupies `size` × `size` even with
    /// nothing to draw) actually holds.
    @MainActor
    func test_body_rendersBlankReservedSpace_whenChapterHasNoArtwork() throws {
        let chapter = Chapter(startTime: 0, title: "C")
        let size: CGFloat = 43

        let renderer = ImageRenderer(content: ChapterArtworkView(chapter: chapter, size: size, cornerRadius: 4))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage, "view must render even with no art")
        let cgImage = try XCTUnwrap(rendered.cgImage)

        XCTAssertEqual(cgImage.width, Int(size), "must still occupy the requested size")
        XCTAssertEqual(cgImage.height, Int(size), "must still occupy the requested size")
        let center = try XCTUnwrap(pixelColor(in: cgImage, x: cgImage.width / 2, y: cgImage.height / 2))
        XCTAssertEqual(center.a, 0, "a chapter with no art source must render nothing, not a placeholder")
    }

    // MARK: - ChapterListSheet wiring
    //
    // `ChapterListSheet` reads `@Environment(PodcastManager.self)` and
    // `@Environment(PlayerManager.self)` unconditionally, so rendering it
    // through `ImageRenderer` without both injected would hit the documented
    // SwiftUI env-trap crash class rather than produce a useful test
    // failure. Pinning the wiring at the source level instead matches this
    // codebase's existing precedent for exactly this situation
    // (`WidgetInteractivityGuardTests` scans real widget sources for
    // otherwise-unexercisable invariants).

    func test_chapterListSheet_delegatesToChapterArtworkView() throws {
        let source = try chapterListSheetSource()

        XCTAssertTrue(source.contains("ChapterArtworkView(chapter:"),
                      "ChapterListSheet must render chapter art through the shared resolver view")
        XCTAssertFalse(source.contains("CachedAsyncImage"),
                       "the old remote-only inline path must be fully replaced, not left running alongside ChapterArtworkView")
    }

    /// `anyChapterHasArt`'s own tests (below) call the helper directly and
    /// never touch the call site — the exact "well-tested helper production
    /// never calls" shape this whole file exists to guard against, one
    /// level up, on this task's own fix. Confirmed by sabotage: deleting
    /// the `if showsArtSlot {` wrapper around `chapterImage(chapter:)` (so
    /// every row unconditionally reserves the artwork slot again — the
    /// exact Important-2 layout regression) left all other tests in this
    /// class green.
    func test_chapterListSheet_gatesArtworkSlotOnShowsArtSlot() throws {
        let source = try chapterListSheetSource()

        XCTAssertTrue(source.contains("if showsArtSlot"),
                      "the artwork slot must be conditionally reserved, or an all-art-less chapter list gains a permanent blank margin")
        // Pinning the CONSUMER alone left the regression fully reachable
        // (review finding): `let showsArtSlot = true` keeps the `if
        // showsArtSlot` substring, keeps all five `anyChapterHasArt` unit
        // tests green — they call the helper directly and never touch this
        // call site — and silently restores the permanent blank leading
        // margin on every all-art-less chapter list. The PRODUCER has to be
        // pinned too, or the gate is decorative.
        XCTAssertTrue(source.contains("anyChapterHasArt(in: chapters)"),
                      "showsArtSlot must actually be computed from anyChapterHasArt — a hardcoded `true` keeps the `if showsArtSlot` gate present while reintroducing the blank-margin regression")
    }

    /// Asserts both directions — the collision-safe id is present *and* the
    /// colliding one is absent. A presence-only check would pass on the
    /// buggy `id: \.element.id`; an absence-only check (the original shape
    /// of this test) is satisfiable by any other substitute, including
    /// `id: \.element.startTime`, which reintroduces the identical
    /// collision `Chapter.id` already has and would pass silently.
    func test_chapterListSheet_forEachUsesCollisionSafeId() throws {
        let source = try chapterListSheetSource()

        XCTAssertTrue(source.contains("id: \\.offset"),
                      "ChapterListSheet's ForEach must key off the array index")
        XCTAssertFalse(source.contains("id: \\.element.id"),
                       "Chapter.id is startTime; two chapters can share a start time and collide as ForEach identities")
    }

    // MARK: - ChapterListSheet.anyChapterHasArt (art-less row layout)
    //
    // The previous `chapterImage(chapter:)` contributed zero width when
    // `chapter.img` was nil — no reserved slot at all. `ChapterArtworkView`
    // always reserves `size` × `size`, even for `.none`, so it can keep
    // title alignment consistent across a *mixed* chapter list. Left
    // unconditional, that would give every all-art-less chapter list (the
    // common case today, since the feature is new) a permanent blank
    // leading margin nothing used to have. `anyChapterHasArt` gates the
    // reservation on the whole list, restoring the original zero-width
    // layout when no chapter in the list could ever show art. These tests
    // exercise that gate directly, since rendering `ChapterListSheet`
    // itself needs `PodcastManager`/`PlayerManager` injected (see the
    // wiring tests' doc comment above) and isn't worth that cost for a
    // pure `[Chapter] -> Bool` decision.

    func test_anyChapterHasArt_falseWhenNoChapterHasAnySource() {
        XCTAssertFalse(ChapterListSheet.anyChapterHasArt(in: [Chapter(startTime: 0, title: "A"),
                                                              Chapter(startTime: 10, title: "B")]))
    }

    func test_anyChapterHasArt_trueWhenOneChapterHasEmbeddedKey() {
        XCTAssertTrue(ChapterListSheet.anyChapterHasArt(in: [Chapter(startTime: 0, title: "A"),
                                                             Chapter(startTime: 10, title: "B",
                                                                    embeddedImageKey: "chapterart:x:0")]))
    }

    func test_anyChapterHasArt_trueWhenOneChapterHasRemoteImg() {
        XCTAssertTrue(ChapterListSheet.anyChapterHasArt(in: [Chapter(startTime: 0, title: "A", img: "https://e.g/x.jpg"),
                                                             Chapter(startTime: 10, title: "B")]))
    }

    func test_anyChapterHasArt_falseForEmptyChapterList() {
        XCTAssertFalse(ChapterListSheet.anyChapterHasArt(in: []))
    }

    /// An empty-string `img` (distinct from nil) must not count as art — it
    /// wouldn't resolve to a URL in `ChapterArtworkView.source(for:)`
    /// either (`!img.isEmpty` guards that branch too).
    func test_anyChapterHasArt_falseWhenImgIsEmptyString() {
        XCTAssertFalse(ChapterListSheet.anyChapterHasArt(in: [Chapter(startTime: 0, title: "A", img: "")]))
    }

    // MARK: - Helpers

    /// See the note above the `test_body_*` render tests: `size` must
    /// differ between call sites in this file, or `ImageRenderer` can
    /// return a stale buffer from an unrelated prior render.
    @MainActor
    private func renderedCenterPixel<V: View>(of view: V) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage, "view must render")
        let cgImage = try XCTUnwrap(rendered.cgImage)
        return try XCTUnwrap(pixelColor(in: cgImage, x: cgImage.width / 2, y: cgImage.height / 2))
    }

    private func pixelColor(in cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Shift the source so the requested pixel lands at the context's
        // single (0,0) origin; CG's coordinate space is flipped relative to
        // the pixel row/column we want.
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y),
                                          width: cgImage.width, height: cgImage.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    /// `ChapterListSheet.swift` with whole-line `//` comments removed, so the
    /// scans below match real CODE and never explanatory prose.
    ///
    /// Not optional hygiene — a false negative caught in review, and the
    /// second time this exact class of bug has bitten this feature (see
    /// `ChapterServiceTests.reintroducesPartialChapterChain`, which added the
    /// same stripping after flagging a doc comment as a
    /// violation; this reuses that approach rather than inventing a second
    /// one). `id: \.offset` occurs TWICE in `ChapterListSheet.swift`: once as
    /// the real `ForEach` key, and once inside the comment above it that
    /// explains why that key was chosen. Without stripping, mutating the real
    /// line to the colliding `id: \.element.startTime` left BOTH assertions
    /// in `test_chapterListSheet_forEachUsesCollisionSafeId` green — the
    /// presence check still found the string in the comment, and the absence
    /// check never named `startTime`. That is precisely the substitution that
    /// test's own doc comment says it exists to catch.
    ///
    /// Same known, accepted gap as the two scanners it mirrors: a trailing
    /// `//` on an otherwise-real code line, and `/* … */` block comments, are
    /// not handled. A line-PREFIX check is used rather than splitting on the
    /// first `//` anywhere, so a `https://` inside a string literal can never
    /// truncate a real violation away.
    private func chapterListSheetSource() throws -> String {
        // <repo>/YourPodsTests/ChapterArtworkViewTests.swift → <repo>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = repoRoot.appendingPathComponent("YourPods/YourPods/Views/Components/ChapterListSheet.swift")
        return try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

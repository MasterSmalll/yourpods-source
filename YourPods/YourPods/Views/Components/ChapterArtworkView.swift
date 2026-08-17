import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders chapter artwork from either source — art embedded in the audio file
/// (cached locally under a `chapterart:` key) or a remote URL supplied by the
/// feed — so call sites never branch on which one a chapter has.
struct ChapterArtworkView: View {

    enum Source: Equatable {
        case embedded(String)   // ChapterArtworkStore cache key
        case remote(String)     // URL string
        case none
    }

    let chapter: Chapter
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 4

    /// Classifies which source *would* render, for callers that need to
    /// decide whether to show chapter art at all (the player artwork
    /// swap: `source(for:) != .none`) without instantiating the view. Embedded
    /// art wins when it still resolves in the store; falls back to the remote
    /// URL when the key has been evicted — an evicted key must never fall
    /// straight to "nothing" while a remote URL still exists.
    ///
    /// This is an independent lookup from `body`'s rendering path below —
    /// they do not share a call. `source(for:)` is a synchronous,
    /// on-demand classifier for external callers; `body` defers its own
    /// store lookup into `.task(id:)` (see `loadEmbeddedImage()`) so a
    /// `List` row doesn't repeat a blocking disk read on every
    /// scroll-triggered re-evaluation. Two independent single-lookup call
    /// sites, not one lookup done twice.
    ///
    /// **Caller warning:** this function itself is synchronous and can hit
    /// disk (see `loadEmbeddedImage()`'s doc comment for the exact cost —
    /// a blocking file read, a 900px decode, and an LRU-touch filesystem
    /// write on a cache miss). Calling it from a `body` that re-evaluates
    /// on every state tick (a player view driven by playback position is
    /// the textbook case) reintroduces on this call site exactly the cost
    /// `body` below was rewritten to avoid. Cache/debounce the result
    /// rather than calling this on every re-evaluation.
    static func source(for chapter: Chapter) -> Source {
        if let key = chapter.embeddedImageKey, ChapterArtworkStore.image(forKey: key) != nil {
            return .embedded(key)
        }
        if let img = chapter.img, !img.isEmpty {
            return .remote(img)
        }
        return .none
    }

    /// The non-IO subset of `source(for:) != .none`: does this chapter
    /// declare ANY artwork source at all, without paying `source(for:)`'s
    /// disk cost (see its doc comment — a blocking file read, a 900px
    /// decode, and an LRU-touch write on a cache miss).
    ///
    /// **This is the answer to `source(for:)`'s own caller warning** — the
    /// player artwork swap needs a gate that's safe to call from a
    /// `body` re-evaluated on every position tick (~1/s), and `source(for:)`
    /// itself is explicitly NOT that. This predicate only decides whether to
    /// route to `ChapterArtworkView` at all; `body` still resolves the real
    /// image asynchronously via `.task(id:)` and falls back correctly.
    ///
    /// Deliberately optimistic about the embedded case: it cannot confirm
    /// the key still resolves in `ChapterArtworkStore` without exactly the
    /// disk read this predicate exists to skip, so a key that has since been
    /// evicted (with no remote `img` fallback) answers `true` here even
    /// though `source(for:)` would say `.none` for the same chapter — the
    /// caller sees `ChapterArtworkView` render its empty `Color.clear`
    /// branch rather than falling back to episode artwork. Accepted
    /// trade-off: a real disk check on every re-evaluation is the bug this
    /// predicate exists to prevent, and an evicted key with no remote
    /// fallback is the rare case, not the common one.
    static func hasAnyDeclaredSource(for chapter: Chapter) -> Bool {
        chapter.embeddedImageKey != nil || !(chapter.img?.isEmpty ?? true)
    }

    /// Which artwork a chapter-aware surface should render for the current
    /// chapter: the chapter's own art when it declares a source, otherwise the
    /// episode's own artwork. Centralizes the swap gate that the full-screen
    /// player (`PlayerView`) and the mini-player (`NowPlayingBar`) share, so the
    /// two surfaces decide identically and can never drift — the multi-call-site
    /// divergence `ChapterCoordinator` exists to prevent. Composes the body-safe
    /// `hasAnyDeclaredSource(for:)`, so it inherits its no-disk-IO guarantee and
    /// is safe to call from a `body` re-evaluated on every position tick.
    enum Selection: Equatable {
        case chapter(Chapter)
        case episode
    }

    static func selection(forCurrentChapter chapter: Chapter?) -> Selection {
        if let chapter, hasAnyDeclaredSource(for: chapter) {
            return .chapter(chapter)
        }
        return .episode
    }

    /// Set once `loadEmbeddedImage()` resolves — `nil` both before
    /// resolution and (permanently, for `resolvedForKey`) if the key
    /// doesn't resolve to an image.
    @State private var embeddedImage: PlatformImage?
    /// Which `chapter.embeddedImageKey` `embeddedImage` (or a confirmed nil
    /// result) belongs to. `content` below cross-checks this against
    /// `chapter.embeddedImageKey` on every read rather than trusting
    /// `embeddedImage != nil` alone.
    ///
    /// Rationale is structural, not an observed failure: `ChapterListSheet`'s
    /// `ForEach` keys rows by array index (`id: \.offset`, the fix for the
    /// `Chapter.id` collision), not by chapter identity — so if
    /// SwiftUI ever recycles a row's `@State` when `chapters` reloads with
    /// different data at the same index, `resolvedForKey` could hold a
    /// *different* chapter's key. (A cross-chapter render test appeared to
    /// demonstrate this directly, but that same test also reproduced a
    /// separate, confirmed `ImageRenderer` buffer-reuse artifact — see the
    /// test file — so it isn't reliable evidence either way. This comment
    /// claims only the code-level argument above, which is sufficient on
    /// its own.) Worst case of the check below being unnecessary is one
    /// extra frame of the loading placeholder while `.task(id:)`'s restart
    /// catches up; worst case of skipping it is genuinely wrong art
    /// rendering, so it stays.
    @State private var resolvedForKey: String?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: chapter.embeddedImageKey) {
                await loadEmbeddedImage()
            }
    }

    /// True once a lookup has completed *for the chapter currently being
    /// rendered*. `resolvedForKey == chapter.embeddedImageKey` alone is
    /// sufficient — no separate "has a lookup run at all" flag is needed:
    /// when neither this chapter nor any prior one had a key, both sides
    /// are `nil` and the check trivially holds, but every branch below that
    /// depends on this also independently requires `chapter.
    /// embeddedImageKey != nil`, so that coincidental-nil-match case never
    /// changes which branch renders.
    private var hasResolvedCurrentChapter: Bool {
        resolvedForKey == chapter.embeddedImageKey
    }

    @ViewBuilder
    private var content: some View {
        if hasResolvedCurrentChapter, let embeddedImage {
            #if canImport(UIKit)
            Image(uiImage: embeddedImage).resizable().aspectRatio(contentMode: .fill)
            #elseif canImport(AppKit)
            Image(nsImage: embeddedImage).resizable().aspectRatio(contentMode: .fill)
            #endif
        } else if chapter.embeddedImageKey != nil && !hasResolvedCurrentChapter {
            // An embedded key exists and its lookup hasn't resolved yet for
            // *this* chapter (see loadEmbeddedImage() and
            // hasResolvedCurrentChapter). Show the neutral placeholder
            // rather than starting the remote branch here: falling to
            // remote before the check completes would race an unnecessary
            // network fetch against a lookup embedded art is expected to
            // win.
            placeholder
        } else if let img = chapter.img, !img.isEmpty {
            // Reached both when there is no embedded key at all, and when
            // an embedded key exists but no longer resolves (evicted from
            // both cache layers) — the remote URL is the correct fallback
            // in both cases. Never fall to `placeholder`-only here: a
            // chapter with a live remote URL must still show art.
            CachedAsyncImage(url: URL(string: img)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholder
            }
        } else {
            // No source at all. Still occupies `size` (the frame in `body`
            // applies regardless of branch) rather than contributing zero
            // width: a chapter list mixing chapters with and without art
            // needs every row's title to start at the same x-offset.
            // `ChapterListSheet` only reserves this slot at all when at
            // least one chapter in the list has art, so an all-art-less
            // list (the common case today) keeps its original zero-width
            // layout — see `ChapterListSheet.anyChapterHasArt`.
            Color.clear
        }
    }

    /// `ChapterArtworkStore.image(forKey:)` is cheap on a memory-cache hit,
    /// but on a disk-cache miss it is a blocking file read, a 900px ImageIO
    /// decode, and (via `ImageCacheStore.loadFromDisk`'s LRU touch) a
    /// filesystem write — all synchronous. Calling it directly from
    /// `content` (i.e. from `body`) would repeat that cost on every `body`
    /// re-evaluation, including scroll-triggered `List` row diffs that
    /// don't change which chapter this row represents. Deferring it into
    /// `.task(id: chapter.embeddedImageKey)` — cached in `@State`
    /// afterward — means the lookup runs once per row per chapter, not once
    /// per re-evaluation. This still executes on the calling task's actor
    /// (no explicit background-thread hop, e.g. `Task.detached`): that
    /// matches `CachedAsyncImage.loadImage()`'s own disk-cache-hit path
    /// immediately above in `content`, which makes the same trade for the
    /// same reason, and keeps this view's output deterministically
    /// observable by `ImageRenderer`-based tests (confirmed empirically: a
    /// `Task.detached` hop does not reliably complete within
    /// `ImageRenderer`'s synchronous snapshot window, which would make the
    /// embedded-path pixel tests un-writable).
    private func loadEmbeddedImage() async {
        let key = chapter.embeddedImageKey
        guard let key else {
            embeddedImage = nil
            resolvedForKey = nil
            return
        }
        embeddedImage = ChapterArtworkStore.image(forKey: key)
        resolvedForKey = key
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary)
    }
}

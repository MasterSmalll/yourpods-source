import Foundation
@preconcurrency import AVFoundation
import os

/// Chapter-list builders for `EmbeddedChapterExtractor` — the ID3 (raw CHAP
/// items) and MP4/M4A (groups API) paths, plus the locale-union helper the
/// MP4 path depends on.
///
/// Split out of `EmbeddedChapterExtractor.swift` during review: that file was
/// ~555 lines with CTOC parsing still to land on top
/// of it. All three members here are `static` and touch no actor-isolated
/// state — `chaptersFromID3Items` and `chaptersFromGroups` are deliberately
/// `nonisolated static func`s so their blocking `ChapterArtworkStore.store`
/// work (ImageIO decode + JPEG encode + disk write, no internal `await`)
/// never occupies `EmbeddedChapterExtractor`'s actor executor — see each
/// function's own doc comment for the full SE-0338 reasoning. Since static
/// members of an actor are nonisolated regardless of which file or extension
/// declares them, moving these here is a pure code-organization change: no
/// call-site changes were needed in `EmbeddedChapterExtractor.swift` (`Self
/// .chaptersFromID3Items(...)`/`Self.chaptersFromGroups(...)` still resolve
/// via ordinary static member lookup), and `EmbeddedChapterExtractor`'s
/// `logger` and `withTimeout` were widened from `private` to `internal`
/// (Swift's `private` is same-FILE scoped even across extensions of one
/// type) specifically so this file could keep using them — see their
/// declarations' doc comments in the primary file for that reasoning.
extension EmbeddedChapterExtractor {

    /// Build chapters from raw CHAP metadata items.
    ///
    /// This bypasses BOTH failure modes of `loadChapterMetadataGroups`: the
    /// locale filter (ID3 chapters carry no language, so they file under
    /// "und") and the CTOC dependency (AVFoundation builds its chapter list
    /// from CTOC, so a file with no CTOC — or a CTOC without the top-level
    /// bit — returns zero chapters even though the CHAP frames are all
    /// present). Measured: auphonic.mp3 9 vs 9, lexfull.mp3 0 vs 15,
    /// noctoc.mp3 0 vs 9 (groups API vs raw items). Do not "simplify" this
    /// back to `loadChapterMetadataGroups` — that regression is exactly what
    /// this function exists to route around.
    ///
    /// AVFoundation ships no identifier constant for CHAP; match the literal.
    /// `keySpace == .id3` is checked too, defensively — every item this is
    /// actually called with already comes from
    /// `asset.loadMetadata(for: .id3Metadata)`, but the check keeps this
    /// function's own filtering contract correct independent of caller
    /// discipline, in case a future caller ever hands it a mixed-format
    /// metadata array.
    ///
    /// Per-item loads are SEQUENTIAL, not fanned out over a `TaskGroup` —
    /// measured directly against the real fixture (`chapters-id3.mp3`), not
    /// assumed: `loadMetadata(for: .id3Metadata)` already reads the entire
    /// ID3 tag to enumerate its frames (778 KB, 25 items, took under 1ms
    /// locally), and every subsequent `item.load(.dataValue)` — including
    /// the largest embedded image, ~104 KB — resolved in well under a tenth
    /// of a millisecond, indistinguishable from a pure async-scheduling
    /// baseline. The payload is already resident by the time `AVMetadataItem`
    /// values exist; there is no per-item I/O left to overlap. A concurrent
    /// fan-out would not just be unnecessary complexity here — on a
    /// bandwidth-limited-but-working link it would actively make things
    /// worse: N simultaneous fetches share the same throughput, so every
    /// item slows in lockstep and all N trip a shared deadline together,
    /// where a sequential loop lets early items finish inside their own
    /// budget. `payloadLoadTimeout` on the one real payload load
    /// (`loadMetadata`, in `extract(from:audioUrl:)`) is what actually
    /// bounds this path; the per-item loads below are still individually
    /// wrapped in `withTimeout` as a defensive net for a pathological
    /// AVFoundation implementation this fixture can't exercise, not because
    /// they're expected to ever need it.
    ///
    /// `static` (no actor `self`) is deliberate, not incidental. It keeps
    /// this function's SYNCHRONOUS work — the `ChapterArtworkStore.store`
    /// calls below (ImageIO decode + JPEG encode + disk write, per chapter,
    /// with no internal `await`) — off `EmbeddedChapterExtractor`'s actor:
    /// per SE-0338, a nonisolated async function's body runs on the global
    /// concurrent executor, never the caller's actor, so this function
    /// (including its fully-synchronous tail) never occupies the actor's
    /// executor at all. Caveat for whoever eventually bumps this project's
    /// `SWIFT_VERSION` past 5.10 (an iOS 26/27 adoption plan already exists
    /// in-tree, so this is foreseeable): under `NonisolatedNonsendingByDefault`
    /// (SE-0461, default in Swift 7), a nonisolated async function instead
    /// runs on the CALLER's executor by default, which would silently put
    /// this exact synchronous work back on the actor with no diagnostic —
    /// re-verify this function still runs off-actor after that bump.
    static func chaptersFromID3Items(_ items: [AVMetadataItem], audioUrl: String) async -> [Chapter] {
        let chapItems: [(originalIndex: Int, item: AVMetadataItem)] = items.enumerated().compactMap { offset, item in
            guard item.keySpace == .id3, let key = item.key as? String, key == "CHAP" else { return nil }
            return (offset, item)
        }
        guard !chapItems.isEmpty else { return [] }

        var parsed: [(originalIndex: Int, frame: ParsedChapterFrame)] = []
        for (originalIndex, item) in chapItems {
            let loaded = await withTimeout(seconds: payloadLoadTimeout) {
                try await item.load(.dataValue)
            }
            // `loaded` is `Data??`: the outer optional is withTimeout's
            // "errored or timed out," the inner is AVFoundation's own "this
            // item genuinely has no data." Both mean the same thing here —
            // skip this item.
            guard let frame = (loaded ?? nil).flatMap(ID3ChapterFrameParser.parse(payload:)) else { continue }
            parsed.append((originalIndex, frame))
        }

        // CHAP frames are NOT stored in time order. Sort by start time, with
        // `originalIndex` as an EXPLICIT tie-break for equal start times —
        // deliberately not relying on `sort`'s current stable behavior:
        // the standard library documents "the sorting algorithm is not
        // guaranteed to be stable," and chapter art cache keys are derived
        // from this sort's final position, so re-extraction key stability
        // must not rest on an implementation detail the stdlib explicitly
        // reserves the right to change.
        let frames = parsed
            .sorted { a, b in
                a.frame.startTimeMs != b.frame.startTimeMs
                    ? a.frame.startTimeMs < b.frame.startTimeMs
                    : a.originalIndex < b.originalIndex
            }
            .map(\.frame)

        let chapters = frames.enumerated().map { index, frame -> Chapter in
            // Downsample and cache immediately; raw bytes are discarded here.
            // `index` is the post-sort (time-ordered) position, matching
            // `ChapterArtworkStore`'s own key derivation and stable across
            // re-extractions of the same file per the explicit tie-break above.
            let key = frame.imageData.flatMap {
                ChapterArtworkStore.store(imageData: $0, audioUrl: audioUrl, index: index)
            }
            // An empty-but-present TIT2 (encoding byte with no text) must
            // fall back exactly like a missing TIT2 — `frame.title ?? …`
            // alone only catches nil, not "".
            let rawTitle = frame.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty ?? true) ? "Chapter \(index + 1)" : rawTitle!
            return Chapter(startTime: Double(frame.startTimeMs) / 1000.0,
                           title: title,
                           img: nil,
                           url: frame.link,
                           embeddedImageKey: key,
                           isHidden: false)
        }

        // CTOC hidden-chapter semantics, applied AFTER the sort so
        // `elementIDs` stays parallel to `chapters` in the exact same
        // (post-sort) order `applyCTOCVisibility` requires. This is
        // deliberately the LAST step: nothing after this point re-derives
        // artwork indices or titles, so it cannot disturb them.
        let tocElementIDs = await ctocElementIDs(in: items)
        return applyCTOCVisibility(chapters,
                                   elementIDs: frames.map(\.elementID),
                                   tocElementIDs: tocElementIDs)
    }

    /// Apply ID3 CTOC hidden-chapter semantics: a CHAP frame not referenced
    /// by the table of contents is hidden. The spec permits this explicitly,
    /// "to provide images that can be presented in synchronisation with the
    /// audio."
    ///
    /// Hidden chapters stay in the array so time lookups resolve; they are
    /// filtered for display only.
    ///
    /// `chapters` and `elementIDs` are parallel arrays in the same order —
    /// true at this function's one call site because both are derived from
    /// the same post-sort `frames` array in `chaptersFromID3Items`.
    ///
    /// Fails OPEN on every ambiguity: an empty TOC, a mismatched count, an
    /// unrecognized reference, or an all-hidden result all leave everything
    /// visible. The all-hidden case is the MANDATORY safety valve, not
    /// defensive coding — files ship with a CTOC lacking the top-level bit,
    /// or with a stale one that references none of the file's current CHAP
    /// elements, and without this fallback every chapter would be marked
    /// hidden and the list would render empty: worse than not extracting
    /// chapters at all, because it regresses files that work today.
    /// `lexfull.mp3` (15 chapters) is exactly this case — proven causally:
    /// two copies of that file differing at exactly one byte (offset 1533,
    /// `0x01` -> `0x03`, the CTOC flags byte) return 0 vs 15 chapters via
    /// the groups API.
    static func applyCTOCVisibility(_ chapters: [Chapter],
                                    elementIDs: [String],
                                    tocElementIDs: [String]) -> [Chapter] {
        guard !tocElementIDs.isEmpty,
              chapters.count == elementIDs.count else { return chapters }

        let referenced = Set(tocElementIDs)

        // Chapter is a value type, so rebuild rather than mutate in place.
        var result = zip(chapters, elementIDs).map { chapter, elementID in
            referenced.contains(elementID)
                ? chapter.unhidden()
                : Chapter(startTime: chapter.startTime, title: chapter.title,
                          img: chapter.img, url: chapter.url,
                          embeddedImageKey: chapter.embeddedImageKey, isHidden: true)
        }

        // MANDATORY safety valve — see the doc comment above. `unhidden()`
        // rebuilds through `Chapter`'s own initializer with every other
        // field carried forward unchanged, exactly like the visible branch
        // above, so `embeddedImageKey` survives this fallback too: losing it
        // here would silently drop artwork for every chapter in precisely
        // the Lex-class files this valve exists to rescue.
        if result.allSatisfy(\.isHidden) {
            result = result.map { $0.unhidden() }
        }

        return result
    }

    /// Element IDs referenced by the file's top-level CTOC frame, if any.
    /// Used ONLY for hidden-chapter semantics — never to decide which
    /// chapters exist. Deciding existence from CTOC is precisely the mistake
    /// that makes `loadChapterMetadataGroups` return zero chapters for
    /// CTOC-less files (`chaptersFromID3Items`'s own doc comment above:
    /// `lexfull.mp3` 0 vs 15, `noctoc.mp3` 0 vs 9, groups API vs raw items).
    /// CHAP frames alone are always the source of truth for which chapters
    /// exist; this function only ever narrows their VISIBILITY.
    ///
    /// `keySpace == .id3` is checked alongside the key string, mirroring
    /// `chaptersFromID3Items`'s own CHAP filter above exactly (`item.keySpace
    /// == .id3, let key = item.key as? String, key == "CHAP"`) so the two
    /// filters cannot silently drift apart if one is ever loosened without
    /// the other.
    ///
    /// Multiple CTOC frames are legal (nested tables of contents — a CTOC's
    /// own child-ID list can reference another CTOC's element ID as a
    /// sub-tree). Per the ID3v2 chapter-frame addendum, at most one CTOC
    /// frame in the tag has its flags byte's top-level bit (`0x02`) set —
    /// the single root of that tree — so this reads whichever payload has
    /// that bit set, falling back to the first CTOC frame only if none is
    /// explicitly flagged top-level. Blindly taking `.first` would risk
    /// picking a nested sub-table if it happens to be stored before the root
    /// frame, silently hiding top-level chapters that sub-table doesn't
    /// reference.
    static func ctocElementIDs(in items: [AVMetadataItem]) async -> [String] {
        let ctocItems = items.filter { $0.keySpace == .id3 && ($0.key as? String) == "CTOC" }
        guard !ctocItems.isEmpty else { return [] }

        var payloads: [Data] = []
        for item in ctocItems {
            guard let loaded = await withTimeout(seconds: payloadLoadTimeout, operation: {
                try await item.load(.dataValue)
            }), let data = loaded else { continue }
            payloads.append(data)
        }
        guard !payloads.isEmpty else { return [] }

        let topLevel = payloads.first { isTopLevelCTOCPayload($0) } ?? payloads[0]
        return ctocChildElementIDs(in: topLevel)
    }

    /// True iff a CTOC payload's flags byte has the top-level bit (`0x02`)
    /// set. Malformed or too-short payloads read as false rather than
    /// trapping — `ctocElementIDs`'s `?? payloads[0]` fallback covers that
    /// case.
    private static func isTopLevelCTOCPayload(_ payload: Data) -> Bool {
        let bytes = [UInt8](payload)
        guard let idEnd = bytes.firstIndex(of: 0x00), bytes.count > idEnd + 1 else { return false }
        return bytes[idEnd + 1] & 0x02 != 0
    }

    /// Parses one CTOC payload's child element IDs. Layout: element ID
    /// (NUL-terminated) · flags byte · entry-count byte · then that many
    /// NUL-terminated child element IDs — verified byte-for-byte against the
    /// real fixture (`chapters-id3.mp3`), not just the spec text: its CTOC
    /// body is `74 6f 63 00 03 09 63 68 70 30 00 …` — `"toc\0"` (element ID)
    /// · `03` (flags: top-level + ordered) · `09` (nine entries) · nine
    /// `"chpN\0"` child IDs — with the entry-count byte landing exactly on
    /// the actual chapter count (9) and the child-ID walk landing exactly on
    /// the following `TIT2` sub-frame with zero leftover/overrun bytes.
    private static func ctocChildElementIDs(in payload: Data) -> [String] {
        let bytes = [UInt8](payload)
        guard let idEnd = bytes.firstIndex(of: 0x00), bytes.count > idEnd + 2 else { return [] }

        var cursor = idEnd + 3          // skip flags + entry-count bytes
        let entryCount = Int(bytes[idEnd + 2])
        var ids: [String] = []

        while ids.count < entryCount, cursor < bytes.count {
            guard let end = bytes[cursor...].firstIndex(of: 0x00) else { break }
            if let id = String(bytes: bytes[cursor..<end], encoding: .isoLatin1) {
                ids.append(id)
            }
            cursor = end + 1
        }

        return ids
    }

    /// Locale identifiers to query for chapter groups.
    ///
    /// HARD RULE — never pass `Locale.preferredLanguages` alone, and never
    /// hardcode "und". ID3 chapters carry no language so AVFoundation files
    /// them under "und": asking for "en-US" returns zero chapters with no
    /// error. But M4A files under "en", so asking only for "und" returns zero
    /// there. A third value ("mis") appears in the wild. Only the union works.
    /// Measured on this machine: `auphonic.mp3` — 0 preferred-only vs. 9
    /// union; `atp.mp3` — 0 vs. 17; `auphonic.m4a` — 9 vs. 9 (both non-zero
    /// there, but nothing about M4A guarantees that in general, so the union
    /// is still the only safe query).
    ///
    /// This is undocumented folk knowledge: Stack Overflow has zero questions
    /// mentioning `chapterMetadataGroups`, and Apple's developer forums
    /// return nothing. It survives only in source comments and issue
    /// threads — keep this comment.
    ///
    /// File-declared locales come first so the file's own answer wins.
    static func chapterLocaleIdentifiers(preferred: [String], available: [Locale]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for identifier in available.map(\.identifier) + preferred where seen.insert(identifier).inserted {
            result.append(identifier)
        }

        return result.isEmpty ? ["und"] : result
    }

    /// MP4/M4A chapters via the groups API — the only path these containers
    /// support (raw CHAP items, `chaptersFromID3Items`'s approach, are an
    /// ID3-only concept and return zero here).
    ///
    /// Unlike the ID3 path, AVFoundation strips the APIC-style header for us
    /// on this path: `.commonKeyArtwork`'s `.dataValue` is ALREADY bare image
    /// bytes. Do NOT run this through `ID3ChapterFrameParser.decodeAPIC` —
    /// that parser expects an APIC header (text-encoding byte, MIME type,
    /// picture type, description) in front of the image bytes; feeding it
    /// bare image data would treat the image's own leading bytes as that
    /// header and corrupt the decode.
    ///
    /// `static` (no actor `self`), matching `chaptersFromID3Items`: this
    /// function does the same kind of synchronous, blocking work per chapter
    /// (`ChapterArtworkStore.store`'s ImageIO decode + JPEG encode + disk
    /// write, with no internal `await`), so it must stay off
    /// `EmbeddedChapterExtractor`'s actor executor for the same SE-0338
    /// reason — see that function's doc comment for the full mechanism and
    /// the Swift-7 `NonisolatedNonsendingByDefault` caveat, which applies
    /// here identically.
    ///
    /// `preferredLanguages` defaults to the real `Locale.preferredLanguages`
    /// for the one production call site (`extract(from:audioUrl:)`, which
    /// passes nothing and gets the default) — the parameter exists so a test
    /// can inject a preferred locale the fixture does NOT declare and observe
    /// the union rescue it *through this exact function*, not just through
    /// `chapterLocaleIdentifiers` in isolation. Reviewer-caught: an earlier
    /// version hardcoded `Locale.preferredLanguages` inline here with no seam
    /// to inject through, so every test — including one written specifically
    /// to catch this — exercised `chapterLocaleIdentifiers` and
    /// `loadChapterMetadataGroups` directly instead of this function, and
    /// stayed green even with the union stripped out of this call site.
    /// Verified directly: with the union removed here (`languages =
    /// preferredLanguages` instead of the line below), the real device's
    /// `Locale.preferredLanguages` still resolves this fixture's chapters
    /// (it files under "en", which any English-language locale list already
    /// matches) — the regression is invisible unless the test supplies a
    /// preferred locale the fixture does NOT declare, which is exactly what
    /// this parameter makes possible.
    static func chaptersFromGroups(_ asset: AVURLAsset, audioUrl: String,
                                    preferredLanguages: [String] = Locale.preferredLanguages) async -> [Chapter] {
        // Header-ish read: a short list of locale identifiers the file
        // declares chapter metadata under — comparable in size/shape to
        // `availableMetadataFormats` above (also `headerLoadTimeout`-bounded),
        // not a payload. Failure/timeout degrades to "no file-declared
        // locales," not to skipping extraction: `chapterLocaleIdentifiers`
        // still produces a usable ["und"]-inclusive query from `preferred`
        // alone.
        let available = await Self.withTimeout(seconds: Self.headerLoadTimeout) {
            try await asset.load(.availableChapterLocales)
        } ?? []

        let languages = Self.chapterLocaleIdentifiers(preferred: preferredLanguages,
                                                       available: available)

        // Payload-ish: this is the actual chapter data — every group's start
        // time plus its attached title/artwork items — analogous to
        // `loadMetadata(for:)` on the ID3 path above, so it gets the same
        // `payloadLoadTimeout` budget rather than the header one.
        guard let groups = await Self.withTimeout(seconds: Self.payloadLoadTimeout, operation: {
            try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
        }) else {
            Self.logger.debug("⟦CHAPTERS⟧ chapter groups load failed or timed out: \(audioUrl)")
            return []
        }

        // Collect (start, title, raw artwork bytes) per group WITHOUT
        // assigning any artwork cache index yet. The index has to be the
        // POST-SORT position, not this loop's enumeration order — exactly
        // the bug already found and fixed for the ID3 path (see
        // `chaptersFromID3Items`'s artwork-index comment above): assigning
        // the cache key before the final sort attaches art to the wrong
        // chapter whenever enumeration order and time order disagree.
        // AVFoundation does not document `loadChapterMetadataGroups` as
        // guaranteed time-ordered, so this loop cannot assume group N is
        // chapter N.
        var parsed: [(originalIndex: Int, start: Double, title: String?, imageData: Data?)] = []
        for (originalIndex, group) in groups.enumerated() {
            // Mirrors `isPlayableDuration`'s guard: `.seconds` on an invalid
            // or indefinite `CMTime` is NaN, and on ±infinity is ±infinity —
            // checking `isNumeric` BEFORE reading `.seconds` rejects all of
            // those in one shot rather than hand-checking flags (the exact
            // gap that let `positiveInfinity` slip through the naive
            // `isValid && !isIndefinite` check `isPlayableDuration`'s own
            // doc comment warns about).
            guard group.timeRange.start.isNumeric else { continue }
            let start = group.timeRange.start.seconds

            var title: String?
            var imageData: Data?

            // Sequential, not fanned out over a `TaskGroup` — mirrors
            // `chaptersFromID3Items`'s precedent, but UNLIKE that path this
            // is NOT independently measured for MP4: measurement on the ID3
            // path showed its per-item `dataValue` loads were already resident
            // (a few hundredths of a millisecond, no size correlation) once
            // `loadMetadata` had returned. Whether `loadChapterMetadataGroups`
            // resolves MP4 chapter title/artwork the same way is unverified —
            // no M4A fixture exists in this repo to measure
            // against. Kept sequential anyway: per
            // `chaptersFromID3Items`'s reasoning, a concurrent fan-out would
            // be actively worse on a bandwidth-limited-but-working link (N
            // simultaneous loads share the same throughput, so every item
            // slows in lockstep and all N trip a shared deadline together,
            // where a sequential loop lets early items finish inside their
            // own budget) — and each item load below is still individually
            // bounded by `payloadLoadTimeout` as a defensive net either way,
            // exactly as the per-item CHAP loads are.
            for item in group.items {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = await Self.withTimeout(seconds: Self.payloadLoadTimeout) {
                        try await item.load(.stringValue)
                    } ?? nil
                case .commonKeyArtwork:
                    imageData = await Self.withTimeout(seconds: Self.payloadLoadTimeout) {
                        try await item.load(.dataValue)
                    } ?? nil
                default:
                    break
                }
            }

            parsed.append((originalIndex, start, title, imageData))
        }

        // Sort BEFORE assigning artwork indices/keys — see the loop comment
        // above. `originalIndex` is an explicit tie-break for equal start
        // times, matching `chaptersFromID3Items`'s stdlib-stability
        // reasoning (not relying on `sort`'s undocumented current stability).
        let sortedGroups = parsed.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.originalIndex < b.originalIndex
        }

        return sortedGroups.enumerated().map { index, entry in
            // `index` here is the post-sort (time-ordered) position, matching
            // `ChapterArtworkStore`'s own key derivation.
            let key = entry.imageData.flatMap {
                ChapterArtworkStore.store(imageData: $0, audioUrl: audioUrl, index: index)
            }
            // An empty-but-present title item (loads to "" rather than nil)
            // must fall back exactly like a missing one — `title ?? …` alone
            // only catches nil, not "".
            let rawTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty ?? true) ? "Chapter \(index + 1)" : rawTitle!
            return Chapter(startTime: entry.start,
                           title: title,
                           img: nil,
                           url: nil,
                           embeddedImageKey: key,
                           isHidden: false)
        }
    }
}

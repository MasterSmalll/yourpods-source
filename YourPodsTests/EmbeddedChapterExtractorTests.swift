import XCTest
import AVFoundation
@testable import YourPods

final class EmbeddedChapterExtractorTests: XCTestCase {

    private func makeItem(audioUrl: String,
                          localFileUrl: URL? = nil,
                          authHeaders: [String: String]? = nil) -> QueueItem {
        var item = QueueItem(id: "guid-1", title: "Ep", podcastTitle: "Pod",
                             audioUrl: audioUrl, artworkUrl: nil,
                             durationSeconds: 1800, podcastUrl: "https://e.g/feed",
                             pubDate: nil)
        item.localFileUrl = localFileUrl
        item.authHeaders = authHeaders
        return item
    }

    // MARK: - Format pre-filter (optimization only — NOT the hang guard)

    func test_mayContainChapters_acrossFormats() {
        let cases: [(url: String, expected: Bool, why: String)] = [
            ("https://e.g/ep.mp3",            true,  "mp3 carries ID3 CHAP"),
            ("https://e.g/ep.m4a",            true,  "m4a carries MP4 chapters"),
            ("https://e.g/ep.m4b",            true,  "audiobook container"),
            ("https://e.g/ep.mp4",            true,  "mp4 container"),
            ("https://e.g/ep.MP3",            true,  "extension match is case-insensitive"),
            ("https://e.g/ep.mp3?token=abc",  true,  "query string must not defeat the match"),
            ("https://e.g/ep.ogg",            false, "ogg cannot carry ID3 CHAP"),
            ("https://e.g/ep.wav",            false, "wav cannot carry ID3 CHAP"),
            ("https://e.g/ep.opus",           false, "opus cannot carry ID3 CHAP"),
            // Permissive fallback: DAI/tracking prefixes routinely strip the
            // extension. Rejecting these would silently disable chapters for the
            // mainstream shows most likely to embed them.
            ("https://dai.e.g/redirect/12345", true, "unknown extension must be allowed"),
            ("https://e.g/download/episode",   true, "extensionless URL must be allowed"),
        ]

        for c in cases {
            XCTAssertEqual(EmbeddedChapterExtractor.mayContainChapters(audioUrl: c.url),
                           c.expected, "\(c.url): \(c.why)")
        }
    }

    // MARK: - Asset construction

    func test_makeAsset_prefersLocalFile_whenDownloaded() {
        let local = URL(fileURLWithPath: "/tmp/ep.mp3")
        let item = makeItem(audioUrl: "https://e.g/ep.mp3", localFileUrl: local)

        let asset = EmbeddedChapterExtractor.makeAsset(for: item)

        XCTAssertEqual(asset?.url, local, "downloaded episodes must parse from disk, not the network")
    }

    func test_makeAsset_usesRemoteUrl_whenNotDownloaded() {
        let item = makeItem(audioUrl: "https://e.g/ep.mp3")

        let asset = EmbeddedChapterExtractor.makeAsset(for: item)

        XCTAssertEqual(asset?.url.absoluteString, "https://e.g/ep.mp3")
    }

    /// `AVURLAsset` exposes no public getter for the options it was
    /// constructed with, so this can only assert on URL selection — it would
    /// still pass with auth-header attachment deleted entirely. Real coverage
    /// for header attachment is `test_assetOptions_acrossHeaderInputs` below,
    /// against the pure helper that builds the options dictionary and asserts
    /// the actual key and value.
    func test_makeAsset_usesRemoteUrl_whenAuthHeadersPresent() {
        let item = makeItem(audioUrl: "https://e.g/ep.mp3",
                            authHeaders: ["Authorization": "Bearer tok"])

        let asset = EmbeddedChapterExtractor.makeAsset(for: item)

        XCTAssertEqual(asset?.url.absoluteString, "https://e.g/ep.mp3")
    }

    /// EDGE: no local file and an unparseable `audioUrl`: must return nil
    /// rather than fabricate a placeholder asset (e.g. pointed at a fixed
    /// local path) that a caller could mistake for a real, loadable asset.
    func test_makeAsset_returnsNil_forUnparseableUrlWithNoLocalFile() {
        let item = makeItem(audioUrl: "")

        XCTAssertNil(EmbeddedChapterExtractor.makeAsset(for: item),
                    "no local file and no parseable URL must not fabricate a bogus asset")
    }

    /// A downloaded episode with an empty `audioUrl` (e.g. a locally-added
    /// file with no feed URL) must still resolve — `localFileUrl` alone is
    /// sufficient, independent of `audioUrl`.
    func test_makeAsset_prefersLocalFile_whenAudioUrlEmpty() {
        let local = URL(fileURLWithPath: "/tmp/ep.mp3")
        let item = makeItem(audioUrl: "", localFileUrl: local)

        XCTAssertEqual(EmbeddedChapterExtractor.makeAsset(for: item)?.url, local)
    }

    // MARK: - Auth header options (the real coverage for usesRemoteUrl_whenAuthHeadersPresent)

    // Literal, not the named `AVURLAssetHTTPHeaderFieldsKey` symbol — current
    // SDKs export it from the AVFoundation binary for ABI compatibility but no
    // longer declare it in public headers, so the name does not resolve at
    // compile time (verified directly: `swiftc -typecheck` against this SDK
    // fails on the bare symbol). Matches AudioManager.swift:711's identical key.
    func test_assetOptions_acrossHeaderInputs() {
        let cases: [(name: String, headers: [String: String]?, expected: [String: String]?)] = [
            ("headers present",           ["Authorization": "Bearer tok"], ["Authorization": "Bearer tok"]),
            ("nil headers",                nil,                             nil),
            ("EDGE: empty headers dict",   [:],                             nil),
        ]

        for c in cases {
            let options = EmbeddedChapterExtractor.assetOptions(for: c.headers)
            if let expected = c.expected {
                XCTAssertEqual(options["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String],
                               expected, c.name)
            } else {
                XCTAssertTrue(options.isEmpty, c.name)
            }
        }
    }

    // MARK: - Duration guard — the actual iOS 26 hang-safety mechanism

    func test_isPlayableDuration_acrossDurations() {
        let cases: [(name: String, duration: CMTime, expected: Bool)] = [
            ("EDGE: invalid time",                     .invalid,          false),
            ("indefinite (live stream) — the iOS 26 trigger condition", .indefinite, false),
            ("EDGE: positive infinity — isValid && !isIndefinite alone would wrongly accept this", .positiveInfinity, false),
            ("EDGE: negative infinity",                 .negativeInfinity, false),
            ("EDGE: exactly zero",                      CMTime(value: 0, timescale: 1), false),
            ("a normal 30-minute episode",               CMTime(seconds: 1800, preferredTimescale: 600), true),
        ]

        for c in cases {
            XCTAssertEqual(EmbeddedChapterExtractor.isPlayableDuration(c.duration), c.expected, c.name)
        }
    }

    // MARK: - Gate
    //
    // `extract(from:audioUrl:)` now does real ID3 work (proved above by the
    // fixture-backed tests and the `chaptersFromID3Items` unit tests: they
    // fail with a genuine `0 != 9` when extraction is broken, so `extract`
    // is no longer a `[]`-only stub). That resolved the ORIGINAL problem
    // this section's placeholder notice described.
    //
    // It did NOT make the three tests below individually pin the one guard
    // each is named after — verified by actually deleting each guard in turn
    // and rerunning its test, not by reasoning about it:
    //   - format pre-filter removed → test_returnsEmpty_forUnsupportedFormat
    //     still passed: the fake "https://e.g/ep.ogg" host fails DNS
    //     resolution, so the duration load downstream fails closed on its
    //     own regardless of the pre-filter.
    //   - duration guard removed → test_returnsEmpty_forUnreadableAsset
    //     still passed: `extract`'s own `availableMetadataFormats` load
    //     fails fast for a nonexistent local file, independent of the
    //     duration check that used to gate the call to `extract` at all.
    //   - empty-audioUrl guard removed → test_returnsEmpty_forMalformedUrl
    //     still passed: `URL(string: "")` is nil, so `mayContainChapters`
    //     independently rejects the same input right after.
    // Each of these three tests exercises TWO OR MORE guards at once for its
    // chosen input, so removing any single one leaves another standing.
    // That is defense-in-depth working as intended, not a bug — but it does
    // mean these three no longer serve (and, on reflection, structurally
    // never really could serve — see each test's updated comment) as
    // single-guard regression tests. The genuinely single-guard-discriminating
    // coverage lives elsewhere in this file, against the pure functions
    // directly: `test_mayContainChapters_acrossFormats` (format pre-filter)
    // and `test_isPlayableDuration_acrossDurations` (the hang guard). These
    // three stay for what they legitimately do prove: the full `chapters(for:)`
    // pipeline fails closed, fast, and without trapping for degenerate input,
    // end to end.

    /// The format pre-filter is documented as "cheap pre-filter, NOT a safety
    /// mechanism" — its only effect is skipping asset construction for a
    /// known-incapable extension, a perf optimization the empty-result
    /// assertion here cannot observe either way, since an unsupported format
    /// also legitimately produces `[]` via `extract`'s own format dispatch.
    /// Real coverage for the pre-filter itself: `test_mayContainChapters_acrossFormats`.
    func test_returnsEmpty_forUnsupportedFormat() async {
        let chapters = await EmbeddedChapterExtractor.shared
            .chapters(for: makeItem(audioUrl: "https://e.g/ep.ogg"))

        XCTAssertTrue(chapters.isEmpty)
    }

    /// A nonexistent local file must fail closed and fast, not hang or trap.
    /// Real coverage for the hang-guard logic itself (the reason this file's
    /// top-of-file comment calls it the single most safety-critical line):
    /// `test_isPlayableDuration_acrossDurations`, which exercises `.indefinite`
    /// and `.positiveInfinity` directly — this end-to-end test's missing-file
    /// scenario fails fast either way and was never actually a live-stream
    /// (indefinite-duration) case.
    func test_returnsEmpty_forUnreadableAsset() async {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp3")
        let item = makeItem(audioUrl: "https://e.g/ep.mp3", localFileUrl: missing)

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        XCTAssertTrue(chapters.isEmpty)
    }

    /// EDGE: neither a URL nor a local file at all.
    func test_returnsEmpty_forMalformedUrl() async {
        let chapters = await EmbeddedChapterExtractor.shared
            .chapters(for: makeItem(audioUrl: ""))

        XCTAssertTrue(chapters.isEmpty)
    }

    // MARK: - ID3 extraction (fixture-backed)

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chapters-id3", withExtension: "mp3") else {
            throw XCTSkip("chapters-id3.mp3 fixture unavailable")
        }
        return url
    }

    func test_extractsChaptersFromID3File() async throws {
        let item = makeItem(audioUrl: "https://e.g/ep.mp3", localFileUrl: try fixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        XCTAssertEqual(chapters.count, 9)
        // The count assertion above CANNOT catch a broken CTOC parse:
        // `applyCTOCVisibility` only ever flips `isHidden`, it never removes
        // array entries, so `count` stays 9 no matter how badly CTOC parsing
        // goes wrong (even a swapped-field-order CTOC parse, where 6 of 9
        // real chapters would wrongly come back hidden, still yields
        // count == 9). This fixture's real CTOC references all 9 chp0–chp8
        // elements (verified byte-for-byte against the file's raw CTOC
        // bytes), so none should be hidden — this is the one
        // regression guard in the suite tied to CTOC-driven visibility
        // against real file bytes rather than synthesized in-memory payloads.
        XCTAssertTrue(chapters.allSatisfy { !$0.isHidden },
                      "fixture's CTOC references all 9 chp0–chp8 elements, so none should be hidden")
    }

    func test_extractedChaptersAreSortedByStartTime() async throws {
        // CHAP frames are stored out of order: chp6, chp7, chp8, chp0, chp2, …
        let item = makeItem(audioUrl: "https://e.g/ep.mp3", localFileUrl: try fixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        XCTAssertEqual(chapters.map(\.startTime), chapters.map(\.startTime).sorted())
        XCTAssertEqual(chapters.first?.startTime, 0)
    }

    func test_extractedChaptersHaveTitles() async throws {
        let item = makeItem(audioUrl: "https://e.g/ep.mp3", localFileUrl: try fixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        // `allSatisfy` on `[]` is vacuously true — an empty result (extraction
        // silently broken) would pass this assertion alone. Reviewer-caught:
        // the eighth can't-fail test on this feature; this ran green in the
        // RED state before implementation for exactly that reason.
        XCTAssertFalse(chapters.isEmpty)
        XCTAssertTrue(chapters.allSatisfy { !$0.title.isEmpty })
    }

    /// The whole point of this work.
    func test_extractedChaptersCarryEmbeddedArtworkKeys() async throws {
        let item = makeItem(audioUrl: "https://e.g/art.mp3", localFileUrl: try fixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        let withArt = chapters.filter { $0.embeddedImageKey != nil }
        XCTAssertFalse(withArt.isEmpty, "fixture has APIC art in every chapter")

        let key = try XCTUnwrap(withArt.first?.embeddedImageKey)
        XCTAssertNotNil(ChapterArtworkStore.image(forKey: key), "key must resolve to a cached image")
    }

    // MARK: - chaptersFromID3Items (synthesized items — no fixture, no network)
    //
    // These target `chaptersFromID3Items` directly with hand-built
    // `AVMutableMetadataItem`s, so they discriminate independently of
    // whether the fixture download succeeded, and pin the three specific
    // defect candidates in this code path: the `item.key as? String`
    // cast, the post-sort artwork index, and the empty-vs-missing title
    // fallback.

    /// A locally-constructed item never touches an asset or the network, so
    /// `.load(.dataValue)` resolves synchronously against the in-memory
    /// `value` — no fixture or timeout involved.
    private func makeID3Item(key: String, payload: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .id3
        item.key = key as NSString
        item.value = payload as NSData
        return item
    }

    private func chapPayload(id: String, start: UInt32, end: UInt32,
                             title: String? = nil, imageData: Data? = nil) -> Data {
        var payload = ID3ChapterFrameParserTests.chapHeader(id: id, start: start, end: end)
        if let title {
            payload.append(ID3ChapterFrameParserTests.subFramePlain(
                id: "TIT2", body: Data([0x03]) + Data(title.utf8)))
        }
        if let imageData {
            payload.append(ID3ChapterFrameParserTests.subFramePlain(
                id: "APIC", body: ID3ChapterFrameParserTests.apicBody(image: imageData)))
        }
        return payload
    }

    /// The lone item's key is "TIT2", but its PAYLOAD is a well-formed CHAP
    /// frame body (`chapPayload`) — the same bytes a real CHAP item would
    /// carry. If the `keySpace == .id3 && key == "CHAP"` check were deleted,
    /// this item would parse cleanly and produce a chapter; a malformed,
    /// non-CHAP-shaped payload would fail at the parse step regardless of
    /// the key check and silently make this test pass for the wrong reason
    /// (verified: an earlier version of this test using a genuinely
    /// non-CHAP-shaped payload for the "wrong key" case kept passing even
    /// with the key filter deleted entirely, because `ID3ChapterFrameParser`
    /// rejected the malformed bytes on its own).
    func test_chaptersFromID3Items_returnsEmpty_whenNoChapItems() async {
        let items = [makeID3Item(key: "TIT2",
                                 payload: chapPayload(id: "chp0", start: 0, end: 1000, title: "Intro"))]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertTrue(chapters.isEmpty)
    }

    /// Discriminates the `item.key as? String`/`keySpace` filter: the "TIT2"
    /// item's payload is a well-formed CHAP frame body (see the comment on
    /// `test_chaptersFromID3Items_returnsEmpty_whenNoChapItems` for why that
    /// matters) sitting alongside two real CHAP items — it must not leak
    /// through as a bogus third chapter.
    func test_chaptersFromID3Items_filtersOutNonChapKeys() async {
        let items = [
            makeID3Item(key: "TIT2", payload: chapPayload(id: "chpX", start: 500, end: 900, title: "Bogus")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp0", start: 0, end: 1000, title: "Intro")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp1", start: 1000, end: 2000, title: "Middle")),
        ]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertEqual(chapters.count, 2)
        XCTAssertFalse(chapters.map(\.title).contains("Bogus"))
    }

    /// Frames are stored out of order in real files; this mirrors that shape
    /// with three chapters submitted out of time order.
    func test_chaptersFromID3Items_sortsByStartTimeRegardlessOfInputOrder() async {
        let items = [
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp2", start: 20_000, end: 30_000, title: "Third")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp0", start: 0, end: 10_000, title: "First")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp1", start: 10_000, end: 20_000, title: "Second")),
        ]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertEqual(chapters.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 10, 20])
    }

    func test_chaptersFromID3Items_fallsBackTitle_whenNoTIT2() async {
        let items = [makeID3Item(key: "CHAP", payload: chapPayload(id: "chp0", start: 0, end: 1000))]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertEqual(chapters.first?.title, "Chapter 1")
    }

    /// EDGE: a TIT2 sub-frame that IS present but decodes to an empty string
    /// (just the encoding byte, no text) must fall back exactly like a
    /// missing TIT2 — `frame.title ?? fallback` alone only catches nil, not
    /// "", and would produce a chapter with an empty, unreadable title.
    func test_chaptersFromID3Items_fallsBackTitle_whenTIT2PresentButEmpty() async {
        var payload = ID3ChapterFrameParserTests.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(ID3ChapterFrameParserTests.subFramePlain(id: "TIT2", body: Data([0x03])))  // encoding byte only
        let items = [makeID3Item(key: "CHAP", payload: payload)]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertEqual(chapters.first?.title, "Chapter 1")
    }

    /// The post-sort index (not the file's on-disk order) drives the artwork
    /// cache key. Submit the CHAP items out of time order and confirm the
    /// key reflects the sorted position, matching `ChapterArtworkStore`'s
    /// own key derivation exactly.
    func test_chaptersFromID3Items_artworkIndexMatchesSortedPosition() async {
        // Real, decodable PNGs — ChapterArtworkStore.store() legitimately
        // returns nil for undecodable bytes (see its doc comment), so a
        // synthetic all-0xAA blob would make this test fail for the wrong
        // reason (decode failure) instead of testing the index assignment.
        let laterImage = TestImageFactory.makePNG(size: 8)
        let earlierImage = TestImageFactory.makePNG(size: 8)
        let items = [
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp1", start: 10_000, end: 20_000,
                                                           title: "Later", imageData: laterImage)),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp0", start: 0, end: 10_000,
                                                           title: "Earlier", imageData: earlierImage)),
        ]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://audio-index.e.g/ep.mp3")

        XCTAssertEqual(chapters.map(\.title), ["Earlier", "Later"])
        XCTAssertEqual(chapters[0].embeddedImageKey,
                       ChapterArtworkStore.cacheKey(audioUrl: "https://audio-index.e.g/ep.mp3", index: 0))
        XCTAssertEqual(chapters[1].embeddedImageKey,
                       ChapterArtworkStore.cacheKey(audioUrl: "https://audio-index.e.g/ep.mp3", index: 1))
    }

    /// Chapter art keys must stay stable across re-extractions of the same
    /// file. `chaptersFromID3Items` loads each CHAP item's `.dataValue`
    /// SEQUENTIALLY, not concurrently (measured against the real fixture:
    /// `.dataValue` is already resident once `loadMetadata` returns, so a
    /// concurrent fan-out would have been complexity for nothing — see that
    /// function's doc comment) — so there is no concurrent-completion-order
    /// hazard here to guard against. What this test actually verifies is
    /// narrower and still real: the tie-break for equal start times is
    /// `originalIndex`, an EXPLICIT comparator term, not a reliance on
    /// `Array.sort`'s current (undocumented, not-guaranteed) stability.
    ///
    /// Be honest about what this does NOT prove: NEITHER assertion below
    /// currently discriminates the tie-break. Both still pass with the
    /// comparator reverted to naive stable-sort reliance, because the
    /// stdlib's sort happens to be stable at this array size today. The
    /// tie-break is correct-by-construction, not test-enforced. A genuinely
    /// discriminating test would need ~30-50 equal-start-time frames in an
    /// adversarial order, past the size threshold where `Array.sort` switches
    /// away from insertion sort. The second assertion (call twice,
    /// compare) is a weak, non-discriminating sanity check on its own —
    /// flagged as such by review — since with no concurrency in this
    /// function anymore, and Swift's current sort empirically stable
    /// regardless, no experiment against today's toolchain can show it
    /// failing even with the explicit tie-break removed; kept as a cheap
    /// regression guard, not as evidence for the tie-break claim.
    func test_chaptersFromID3Items_isDeterministicAcrossRepeatedCalls_forEqualStartTimes() async {
        let items = [
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chpA", start: 5_000, end: 5_000, title: "Alpha")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chpB", start: 5_000, end: 5_000, title: "Bravo")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chpC", start: 5_000, end: 5_000, title: "Charlie")),
        ]

        let first = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")
        let second = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        // Ties break on original (file) order via the explicit comparator.
        XCTAssertEqual(first.map(\.title), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(first.map(\.title), second.map(\.title))
    }

    // MARK: - Locale union (the trap)

    func test_localeIdentifiers_unionsPreferredAndAvailable() {
        let ids = EmbeddedChapterExtractor.chapterLocaleIdentifiers(
            preferred: ["en-US"],
            available: [Locale(identifier: "und")])

        XCTAssertTrue(ids.contains("en-US"))
        XCTAssertTrue(ids.contains("und"), "ID3 chapters file under \"und\" — omitting it returns zero")
    }

    func test_localeIdentifiers_includesAvailableFirst() {
        let ids = EmbeddedChapterExtractor.chapterLocaleIdentifiers(
            preferred: ["en-US", "fr-FR"],
            available: [Locale(identifier: "und"), Locale(identifier: "mis")])

        XCTAssertEqual(Array(ids.prefix(2)), ["und", "mis"],
                       "file-declared locales must be tried before user preferences")
    }

    func test_localeIdentifiers_deduplicates() {
        let ids = EmbeddedChapterExtractor.chapterLocaleIdentifiers(
            preferred: ["en-US", "en-US"],
            available: [Locale(identifier: "en-US")])

        XCTAssertEqual(ids.filter { $0 == "en-US" }.count, 1)
    }

    /// EDGE: no locales anywhere must still produce a usable query, not [].
    func test_localeIdentifiers_fallsBackToUnd_whenBothEmpty() {
        let ids = EmbeddedChapterExtractor.chapterLocaleIdentifiers(preferred: [], available: [])

        XCTAssertEqual(ids, ["und"])
    }

    /// Regression guard for the bug shipped by PodcastClient and others.
    func test_localeIdentifiers_neverReturnsPreferredAlone() {
        let ids = EmbeddedChapterExtractor.chapterLocaleIdentifiers(
            preferred: ["en-US"],
            available: [Locale(identifier: "und")])

        XCTAssertNotEqual(ids, ["en-US"])
    }

    // MARK: - MP4 extraction (fixture-backed)
    //
    // `chapters-mp4.m4a` is a trimmed copy of Auphonic's public chapters demo
    // (https://auphonic.com/media/blog/auphonic_chapters_demo.m4a, 2,135,448
    // bytes). MP4 is an atom container, not a stream: naively truncating the
    // tail can destroy the `moov` atom's structure if `moov` sits at the end
    // of the file. Here it does not — `ftyp`+`free`+`moov` occupy bytes
    // [0, 238130), entirely before `mdat` — so the trim keeps that whole
    // region untouched and only shortens `mdat`'s payload, with its 4-byte
    // size field corrected to match. The three chapter-bearing tracks (two
    // `tx3g` text tracks — titles and, per Auphonic's export, an unused
    // second text track — and one `vide`/`jpeg` track for chapter images)
    // were confirmed via their exact `stco`/`stsc`/`stsz` chunk-to-byte-range
    // math to have every sample fully contained within the first 982,714
    // bytes of `mdat`; the trim keeps through byte 1,100,000 of the file
    // (~117 KB of margin) and drops only trailing samples belonging to the
    // long-lived main audio track. Verified byte-for-byte identical chapter
    // output (count, start times, titles, and artwork byte-for-byte,
    // including exact byte counts) between the original 2.1 MB file and this
    // 1.1 MB trim before committing, via a throwaway command-line probe using
    // the same `AVURLAsset`/`loadChapterMetadataGroups` calls this file's
    // production code uses — not by inspection.
    private func mp4FixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chapters-mp4", withExtension: "m4a") else {
            throw XCTSkip("chapters-mp4.m4a fixture unavailable")
        }
        return url
    }

    func test_extractsChaptersFromMP4File() async throws {
        let item = makeItem(audioUrl: "https://e.g/ep.m4a", localFileUrl: try mp4FixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        XCTAssertEqual(chapters.count, 9)
    }

    func test_mp4ChaptersAreSortedByStartTime() async throws {
        let item = makeItem(audioUrl: "https://e.g/ep.m4a", localFileUrl: try mp4FixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        XCTAssertEqual(chapters.map(\.startTime), chapters.map(\.startTime).sorted())
        XCTAssertEqual(chapters.first?.startTime, 0)
    }

    /// Pins all 9 titles, not just the first — `allSatisfy { !title.isEmpty }`
    /// alone is not fixture-discriminating: production *guarantees*
    /// non-empty titles via the `"Chapter \(index + 1)"` fallback in
    /// `chaptersFromGroups`, so a bad trim that destroyed the `tx3g` title
    /// samples for, say, chapters 5–9 would still read back as "Chapter
    /// 6"…"Chapter 9" and pass an `allSatisfy`/first-only check. Pinning the
    /// full array makes this test (and, by extension, the fixture itself)
    /// self-validating without needing to re-run the verification probe used
    /// while trimming.
    func test_mp4ChaptersHaveTitles() async throws {
        let item = makeItem(audioUrl: "https://e.g/ep.m4a", localFileUrl: try mp4FixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        XCTAssertEqual(chapters.map(\.title), [
            "Intro",
            "Creating a new production",
            "Creating a new production",
            "Adaptive leveler",
            "Global loudness normalization",
            "Audio restoration algorithms",
            "Output file formats",
            "External services",
            "Get a free account!",
        ])
    }

    func test_mp4ChaptersCarryEmbeddedArtworkKeys() async throws {
        let item = makeItem(audioUrl: "https://e.g/art.m4a", localFileUrl: try mp4FixtureURL())

        let chapters = await EmbeddedChapterExtractor.shared.chapters(for: item)

        let withArt = chapters.filter { $0.embeddedImageKey != nil }
        XCTAssertEqual(withArt.count, chapters.count, "fixture has a JPEG image in every chapter")

        let key = try XCTUnwrap(withArt.first?.embeddedImageKey)
        XCTAssertNotNil(ChapterArtworkStore.image(forKey: key), "key must resolve to a cached image")
    }

    /// THE load-bearing claim here: on the groups path,
    /// AVFoundation hands back bare image bytes, not an ID3-style APIC frame
    /// (text-encoding byte + MIME-type string + picture-type byte +
    /// description before the image data). Verified directly against the raw
    /// `.dataValue`, independent of `chaptersFromGroups` (which decodes and
    /// discards the raw bytes immediately, so it cannot itself prove this) —
    /// this test drives the same `AVURLAsset` → `availableChapterLocales` →
    /// `loadChapterMetadataGroups` → `item.load(.dataValue)` chain the
    /// production code uses, and inspects what comes back.
    ///
    /// A JPEG starts with the SOI marker `FF D8 FF`; an ID3 APIC frame body
    /// starts with a one-byte text encoding (`00`–`03`) followed by an ASCII
    /// MIME string like `image/jpeg\0` — nothing resembling `FF D8 FF`. If
    /// this ever starts failing because the bytes are APIC-wrapped after all,
    /// `chaptersFromGroups` needs `ID3ChapterFrameParser.decodeAPIC` inserted
    /// before the `ChapterArtworkStore.store` call, exactly the fix this test
    /// exists to make sure nobody has to discover the hard way (corrupted
    /// chapter art, no crash, no error).
    func test_mp4ChapterArtwork_isBareImageBytes_notApicWrapped() async throws {
        let asset = AVURLAsset(url: try mp4FixtureURL())
        let available = try await asset.load(.availableChapterLocales)
        let languages = EmbeddedChapterExtractor.chapterLocaleIdentifiers(
            preferred: Locale.preferredLanguages, available: available)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
        let firstGroup = try XCTUnwrap(groups.first)

        let artworkItem = try XCTUnwrap(firstGroup.items.first { $0.commonKey == .commonKeyArtwork })
        let loaded = try await artworkItem.load(.dataValue)
        let data = try XCTUnwrap(loaded)

        let jpegSOI: [UInt8] = [0xFF, 0xD8, 0xFF]
        XCTAssertEqual(Array(data.prefix(3)), jpegSOI,
                       "leading bytes must be a bare JPEG SOI marker, not an APIC text-encoding/MIME header")
    }

    /// Proves the "never hardcode und" half of the locale trap against a real
    /// file: this M4A's chapters file under "en" (confirmed via
    /// `availableChapterLocales` during fixture verification), so querying
    /// only "und" — the ID3 path's filing locale — returns zero here, the
    /// mirror image of the MP3 fixtures returning zero for "en-US".
    func test_mp4_hardcodedUndAlone_returnsZeroGroups() async throws {
        let asset = AVURLAsset(url: try mp4FixtureURL())

        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und"])

        XCTAssertTrue(groups.isEmpty)
    }

    /// Proves the union MECHANISM works end-to-end against real
    /// `loadChapterMetadataGroups` results, with a preferred locale ("de-DE")
    /// the fixture does NOT declare — so this is locale-independent (doesn't
    /// rely on the test runner's own system language), unlike the dropped
    /// `test_mp4_preferredLanguagesAlone_alreadySucceeds_unlikeID3` it
    /// supersedes: bare `bestMatchingPreferredLanguages: ["de-DE"]` finds
    /// nothing, while the union (file-declared "en" merged with "de-DE")
    /// still finds all 9.
    ///
    /// EDGE — what this test does NOT prove, caught on review: it drives
    /// `chapterLocaleIdentifiers` and `loadChapterMetadataGroups` directly,
    /// never `chaptersFromGroups` itself, so it cannot detect a regression
    /// where `chaptersFromGroups`'s internal call site stops using the union.
    /// Verified directly: reverting that call site to bare
    /// `Locale.preferredLanguages` leaves EVERY test in this file green,
    /// including this one — the real device's `Locale.preferredLanguages`
    /// already contains "en", which matches this fixture regardless of the
    /// union. `test_chaptersFromGroups_unionRescuesANonMatchingPreferredLocale`
    /// below is the test that actually pins the call site, via the
    /// `preferredLanguages` injection parameter added to `chaptersFromGroups`
    /// for exactly this reason.
    func test_mp4_unionRescuesANonMatchingPreferredLocale() async throws {
        let asset = AVURLAsset(url: try mp4FixtureURL())
        let available = try await asset.load(.availableChapterLocales)

        let alone = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["de-DE"])
        XCTAssertTrue(alone.isEmpty, "a non-declared preferred locale alone finds nothing")

        let union = EmbeddedChapterExtractor.chapterLocaleIdentifiers(preferred: ["de-DE"], available: available)
        let viaUnion = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: union)
        XCTAssertEqual(viaUnion.count, 9, "the union with the file's own locales still finds all 9")
    }

    /// THE test that actually pins the union at the `chaptersFromGroups` call
    /// site — drives the production function itself, not a re-derivation of
    /// its pieces. `chaptersFromGroups` takes `preferredLanguages` as an
    /// injectable parameter defaulting to the real `Locale.preferredLanguages`
    /// (see its doc comment) specifically so this test can hand it "de-DE",
    /// a locale the fixture does not declare, and observe whether the
    /// function's OWN internal union call rescues it.
    ///
    /// Verified directly: with the union stripped from
    /// `chaptersFromGroups`'s body (`languages = preferredLanguages` instead
    /// of `chapterLocaleIdentifiers(preferred: preferredLanguages,
    /// available:)`), this test goes red — `chapters.count == 0`, not 9 —
    /// while every other test in this file, including
    /// `test_mp4_unionRescuesANonMatchingPreferredLocale` above, stays green.
    func test_chaptersFromGroups_unionRescuesANonMatchingPreferredLocale() async throws {
        let asset = AVURLAsset(url: try mp4FixtureURL())

        let chapters = await EmbeddedChapterExtractor.chaptersFromGroups(
            asset, audioUrl: "https://e.g/ep.m4a", preferredLanguages: ["de-DE"])

        XCTAssertEqual(chapters.count, 9,
                       "chaptersFromGroups must union \"de-DE\" with the file's own declared locale internally")
    }

    // MARK: - CTOC visibility

    private func chapter(_ title: String, _ start: Double) -> Chapter {
        Chapter(startTime: start, title: title)
    }

    func test_ctoc_marksUnreferencedChaptersHidden() {
        let chapters = [chapter("A", 0), chapter("B", 10), chapter("C", 20)]

        let result = EmbeddedChapterExtractor.applyCTOCVisibility(
            chapters, elementIDs: ["chp0", "chp1", "chp2"], tocElementIDs: ["chp0", "chp2"])

        XCTAssertEqual(result.map(\.isHidden), [false, true, false])
    }

    func test_ctoc_keepsHiddenChaptersInArray() {
        let chapters = [chapter("A", 0), chapter("B", 10)]

        let result = EmbeddedChapterExtractor.applyCTOCVisibility(
            chapters, elementIDs: ["chp0", "chp1"], tocElementIDs: ["chp0"])

        XCTAssertEqual(result.count, 2, "hidden chapters stay so time lookups resolve")
    }

    /// THE safety valve. A CTOC without the top-level bit, or a stale one, would
    /// otherwise hide every chapter and render an empty list — worse than today.
    func test_ctoc_allHiddenFallsBackToAllVisible() {
        let chapters = [chapter("A", 0), chapter("B", 10), chapter("C", 20)]

        let result = EmbeddedChapterExtractor.applyCTOCVisibility(
            chapters, elementIDs: ["chp0", "chp1", "chp2"], tocElementIDs: [])

        XCTAssertTrue(result.allSatisfy { !$0.isHidden },
                      "all-hidden must fall back to all-visible")
    }

    func test_ctoc_noTocLeavesEverythingVisible() {
        let chapters = [chapter("A", 0), chapter("B", 10)]

        let result = EmbeddedChapterExtractor.applyCTOCVisibility(
            chapters, elementIDs: ["chp0", "chp1"], tocElementIDs: [])

        XCTAssertTrue(result.allSatisfy { !$0.isHidden })
    }

    /// EDGE: a CTOC referencing IDs that no CHAP frame declares must not hide
    /// the real chapters.
    func test_ctoc_unknownReferencesDoNotHideRealChapters() {
        let chapters = [chapter("A", 0), chapter("B", 10)]

        let result = EmbeddedChapterExtractor.applyCTOCVisibility(
            chapters, elementIDs: ["chp0", "chp1"], tocElementIDs: ["ghost1", "ghost2"])

        XCTAssertTrue(result.allSatisfy { !$0.isHidden })
    }

    func test_ctoc_countMismatchLeavesEverythingVisible() {
        let chapters = [chapter("A", 0), chapter("B", 10)]

        let result = EmbeddedChapterExtractor.applyCTOCVisibility(
            chapters, elementIDs: ["chp0"], tocElementIDs: ["chp0"])

        // Count first: `applyCTOCVisibility` `zip`s chapters against
        // elementIDs, so a naive implementation that dropped the count-mismatch
        // fail-open guard would silently truncate to the shorter array (1
        // chapter) — and `allSatisfy` over a 1-element result would still be
        // green. Pinning the count catches that; the visibility check then
        // pins fail-OPEN specifically.
        XCTAssertEqual(result.count, 2, "a count mismatch must not drop any chapter — every input chapter must survive")
        XCTAssertTrue(result.allSatisfy { !$0.isHidden }, "mismatched arrays must fail open")
    }

    // MARK: - CTOC wiring (production call site, not just the pure function)
    //
    // The six tests above all target `applyCTOCVisibility` directly. None of
    // them fail if the wiring into `chaptersFromID3Items` is deleted — a
    // pattern that has bitten this feature before (the locale-union helper had
    // five good tests and a bare fallback swap left all of them green). The
    // two tests below drive `chaptersFromID3Items` itself with a synthesized
    // CTOC item alongside CHAP items, so they fail if the
    // `ctocElementIDs`/`applyCTOCVisibility` call is ever removed from that
    // function's body. Verified directly: deleting the
    // wiring line turns `test_ctoc_wiredIntoChaptersFromID3Items_hidesUnreferencedChapters`
    // red while all six direct `applyCTOCVisibility` tests above stay green.

    /// Builds a raw CTOC frame payload byte-for-byte: element ID (NUL-terminated)
    /// · flags byte (bit 0x02 top-level, bit 0x01 ordered) · entry-count byte ·
    /// that many NUL-terminated child element IDs. Verified against the real
    /// fixture (`chapters-id3.mp3`)'s actual CTOC bytes before trusting this
    /// layout.
    private func ctocPayload(elementID: String = "toc", childIDs: [String],
                             topLevel: Bool = true, ordered: Bool = true) -> Data {
        var payload = Data(elementID.utf8)
        payload.append(0x00)
        var flags: UInt8 = 0
        if topLevel { flags |= 0x02 }
        if ordered { flags |= 0x01 }
        payload.append(flags)
        payload.append(UInt8(childIDs.count))
        for id in childIDs {
            payload.append(Data(id.utf8))
            payload.append(0x00)
        }
        return payload
    }

    /// Pins the wiring: `chaptersFromID3Items` must itself call
    /// `applyCTOCVisibility` with the CTOC's referenced element IDs, not just
    /// expose a pure function nobody calls.
    func test_ctoc_wiredIntoChaptersFromID3Items_hidesUnreferencedChapters() async {
        let items = [
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp0", start: 0, end: 1000, title: "First")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp1", start: 1000, end: 2000, title: "Hidden")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp2", start: 2000, end: 3000, title: "Third")),
            makeID3Item(key: "CTOC", payload: ctocPayload(childIDs: ["chp0", "chp2"])),
        ]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertEqual(chapters.count, 3, "hidden chapters still stay in the array so time lookups resolve")
        XCTAssertEqual(chapters.map(\.isHidden), [false, true, false])
    }

    /// EDGE: multiple CTOC frames are legal (nested tables of contents).
    /// Deliberately orders the nested (non-top-level) CTOC item BEFORE the
    /// top-level one in the metadata array, so a naive `.first` would pick
    /// the wrong one and produce the exact opposite hidden/visible pattern.
    func test_ctoc_wiredIntoChaptersFromID3Items_prefersTopLevelCTOC() async {
        let items = [
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp0", start: 0, end: 1000, title: "First")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp1", start: 1000, end: 2000, title: "Second")),
            makeID3Item(key: "CHAP", payload: chapPayload(id: "chp2", start: 2000, end: 3000, title: "Third")),
            makeID3Item(key: "CTOC", payload: ctocPayload(elementID: "nested", childIDs: ["chp1"], topLevel: false)),
            makeID3Item(key: "CTOC", payload: ctocPayload(elementID: "toc", childIDs: ["chp0", "chp2"], topLevel: true)),
        ]

        let chapters = await EmbeddedChapterExtractor.chaptersFromID3Items(items, audioUrl: "https://e.g/ep.mp3")

        XCTAssertEqual(chapters.map(\.isHidden), [false, true, false],
                       "must resolve to the top-level CTOC's references, not whichever CTOC frame appears first")
    }
}

import XCTest
@testable import YourPods

/// WatchQueueMerger extracts WatchSessionManager.handleQueueUpdate's
/// hand-rolled parse+merge into a pure, testable unit that decodes via
/// WatchWireFormat.decodeQueueItem (the single source of truth for the wire
/// format) instead of duplicating field-by-field parsing. These tests exercise the
/// merge/preservation rules directly, plus the decode-asymmetry regression the
/// extraction closes: WatchWireFormat.encodeQueueItem's output must round-trip
/// through the merger unchanged.
final class WatchQueueMergerTests: XCTestCase {

    // MARK: - Helpers

    private func rawItem(
        id: String = "ep-1", title: String = "Title", album: String = "Album",
        artist: String = "Artist", duration: Int = 100, position: Int = 0,
        url: String? = "https://example.com/ep.mp3", artUri: String? = "https://example.com/art.jpg",
        autoDownload: Bool = false, isAvailableOnPhone: Bool = false,
        chapters: [[String: Any]]? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id, "title": title, "album": album, "artist": artist,
            "duration": duration, "position": position,
            "isAvailableOnPhone": isAvailableOnPhone, "autoDownload": autoDownload,
        ]
        if let url { dict["url"] = url }
        if let artUri { dict["artUri"] = artUri }
        if let chapters { dict["chapters"] = chapters }
        return dict
    }

    private func episode(
        id: String, localPath: String? = nil, position: Int = 0,
        artUri: String? = nil, chapters: [WatchChapter]? = nil
    ) -> WatchEpisode {
        WatchEpisode(id: id, title: "T", album: "A", artist: "Ar", duration: 100,
                     localPath: localPath, streamUrl: nil, artUri: artUri,
                     isAvailableOnPhone: false, chapters: chapters, position: position)
    }

    // MARK: - Required coverage

    func test_idBasedMerge_preservesExistingLocalPath() {
        let existing = [episode(id: "ep-1", localPath: "ep1.mp3")]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1")], existing: existing)

        XCTAssertEqual(merged.first?.localPath, "ep1.mp3",
                       "localPath must be preserved from the existing list for a known id")
    }

    func test_newItemsAppendedInPayloadOrder() {
        let raw = [rawItem(id: "ep-2"), rawItem(id: "ep-1"), rawItem(id: "ep-3")]

        let merged = WatchQueueMerger.merge(rawQueue: raw, existing: [])

        XCTAssertEqual(merged.map(\.id), ["ep-2", "ep-1", "ep-3"],
                       "merge must preserve payload order, not sort or reorder")
    }

    func test_itemMissingId_droppedWithoutCrashing() {
        var noId = rawItem(id: "ep-1")
        noId.removeValue(forKey: "id")

        let merged = WatchQueueMerger.merge(rawQueue: [noId, rawItem(id: "ep-2")], existing: [])

        XCTAssertEqual(merged.map(\.id), ["ep-2"],
                       "an item with no id must be dropped, not crash the merge")
    }

    func test_emptyRawQueue_returnsEmptyResult() {
        let merged = WatchQueueMerger.merge(rawQueue: [], existing: [episode(id: "ep-1")])

        XCTAssertTrue(merged.isEmpty)
    }

    /// The decode-asymmetry regression: WatchWireFormat.encodeQueueItem's output
    /// (the actual producer shape used by WatchService.buildQueuePayload) must
    /// survive WatchQueueMerger's decode path unchanged. Before this extraction,
    /// WatchSessionManager hand-parsed the raw dict instead of using
    /// WatchWireFormat.decodeQueueItem — producer and parser could drift.
    func test_roundTrip_withWireFormatEncoder_decodesSymmetrically() {
        let payload = WatchWireFormat.QueueItemPayload(
            id: "ep-1", title: "Round Trip", album: "Album", artist: "Artist",
            duration: 1800, position: 42, url: "https://example.com/rt.mp3",
            artUri: "https://example.com/rt.jpg", autoDownload: true,
            isAvailableOnPhone: true, chapters: nil)
        let encoded = WatchWireFormat.encodeQueueItem(payload)

        let merged = WatchQueueMerger.merge(rawQueue: [encoded], existing: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "ep-1")
        XCTAssertEqual(merged.first?.title, "Round Trip")
        XCTAssertEqual(merged.first?.album, "Album")
        XCTAssertEqual(merged.first?.artist, "Artist")
        XCTAssertEqual(merged.first?.duration, 1800)
        XCTAssertEqual(merged.first?.position, 42)
        XCTAssertEqual(merged.first?.streamUrl, "https://example.com/rt.mp3")
        XCTAssertEqual(merged.first?.artUri, "https://example.com/rt.jpg")
        XCTAssertEqual(merged.first?.isAvailableOnPhone, true)
    }

    // MARK: - Additional parity coverage (position rule + chapters + artUri fallback)

    func test_serverPosition_winsWhenAheadOfLocal() {
        let existing = [episode(id: "ep-1", position: 10)]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1", position: 50)], existing: existing)

        XCTAssertEqual(merged.first?.position, 50)
    }

    func test_localPosition_winsWhenAheadOfServer() {
        // e.g. the watch was actively playing this episode past the last synced position.
        let existing = [episode(id: "ep-1", position: 90)]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1", position: 50)], existing: existing)

        XCTAssertEqual(merged.first?.position, 90)
    }

    func test_chapters_parsedFromRawDicts() {
        let chapters: [[String: Any]] = [
            ["startTime": 0.0, "title": "Intro"],
            ["startTime": 120.0, "title": "Segment 1", "img": "https://example.com/c.jpg", "url": "https://example.com/c"],
        ]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1", chapters: chapters)], existing: [])

        XCTAssertEqual(merged.first?.chapters?.count, 2)
        XCTAssertEqual(merged.first?.chapters?.first?.title, "Intro")
        XCTAssertEqual(merged.first?.chapters?.last?.title, "Segment 1")
        XCTAssertEqual(merged.first?.chapters?.last?.img, "https://example.com/c.jpg")
    }

    func test_chapters_entryMissingRequiredFields_isFiltered_emptyResultBecomesNil() {
        let chapters: [[String: Any]] = [["title": "Missing startTime"]]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1", chapters: chapters)], existing: [])

        XCTAssertNil(merged.first?.chapters,
                    "an all-invalid chapters array must collapse to nil, not an empty array")
    }

    func test_missingChapters_preservesExistingChapters() {
        let existingChapters = [WatchChapter(startTime: 0, title: "Old", img: nil, url: nil)]
        let existing = [episode(id: "ep-1", chapters: existingChapters)]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1", chapters: nil)], existing: existing)

        XCTAssertEqual(merged.first?.chapters?.first?.title, "Old")
    }

    func test_artUri_fallsBackToExisting_whenMissingFromPayload() {
        let existing = [episode(id: "ep-1", artUri: "https://example.com/old.jpg")]

        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "ep-1", artUri: nil)], existing: existing)

        XCTAssertEqual(merged.first?.artUri, "https://example.com/old.jpg")
    }

    func test_newEpisode_notInExisting_hasNilLocalPath() {
        let merged = WatchQueueMerger.merge(rawQueue: [rawItem(id: "brand-new")], existing: [])

        XCTAssertNil(merged.first?.localPath)
    }
}

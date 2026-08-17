// YourPodsTests/WatchWireFormatTests.swift
import XCTest
@testable import YourPods

final class WatchWireFormatTests: XCTestCase {

    // MARK: - Episode list items (the guid/imageUrl regression)

    func test_episodeListItem_roundTrip() {
        let item = WatchWireFormat.EpisodeListItem(
            guid: "ep-guid-1", title: "Episode One", duration: 1800,
            audioUrl: "https://example.com/1.mp3", imageUrl: "https://example.com/1.jpg")
        let dict = WatchWireFormat.encodeEpisodeListItem(item)
        // Wire keys are locked — the watch parses exactly these.
        XCTAssertEqual(dict["guid"] as? String, "ep-guid-1")
        XCTAssertEqual(dict["imageUrl"] as? String, "https://example.com/1.jpg")
        let decoded = WatchWireFormat.decodeEpisodeListItem(dict)
        XCTAssertEqual(decoded?.guid, "ep-guid-1")
        XCTAssertEqual(decoded?.title, "Episode One")
        XCTAssertEqual(decoded?.duration, 1800)
        XCTAssertEqual(decoded?.audioUrl, "https://example.com/1.mp3")
        XCTAssertEqual(decoded?.imageUrl, "https://example.com/1.jpg")
    }

    func test_episodeListItem_decodesLegacyKeys() {
        // EDGE: an old iOS build sends "id" + "artUri" — decoder must still work.
        let legacy: [String: Any] = ["id": "ep-guid-2", "title": "Old", "duration": 60,
                                     "audioUrl": "https://example.com/2.mp3",
                                     "artUri": "https://example.com/2.jpg"]
        let decoded = WatchWireFormat.decodeEpisodeListItem(legacy)
        XCTAssertEqual(decoded?.guid, "ep-guid-2")
        XCTAssertEqual(decoded?.imageUrl, "https://example.com/2.jpg")
    }

    func test_episodeListItem_missingGuid_returnsNil() {
        XCTAssertNil(WatchWireFormat.decodeEpisodeListItem(["title": "No id"]))
    }

    // MARK: - Queue items

    func test_queueItem_roundTrip_preservesChapters() {
        let payload = WatchWireFormat.QueueItemPayload(
            id: "q1", title: "T", album: "Pod", artist: "Pod", duration: 100,
            position: 42, url: "https://example.com/a.mp3", artUri: "https://example.com/a.jpg",
            autoDownload: true, isAvailableOnPhone: true,
            chapters: [["startTime": 0.0, "title": "Intro"]])
        let dict = WatchWireFormat.encodeQueueItem(payload)
        let decoded = WatchWireFormat.decodeQueueItem(dict)
        XCTAssertEqual(decoded?.id, "q1")
        XCTAssertEqual(decoded?.position, 42)
        XCTAssertEqual(decoded?.autoDownload, true)
        XCTAssertEqual(decoded?.chapters?.first?["title"] as? String, "Intro")
    }

    // MARK: - Actions

    func test_action_roundTrip() {
        let dict = WatchWireFormat.encodeAction(.updateProgress, episodeId: "e1",
                                                position: 90, sentAt: 1_700_000_000)
        XCTAssertEqual(dict["command"] as? String, "update_progress")
        let decoded = WatchWireFormat.decodeAction(dict)
        XCTAssertEqual(decoded?.action, .updateProgress)
        XCTAssertEqual(decoded?.episodeId, "e1")
        XCTAssertEqual(decoded?.position, 90)
        XCTAssertEqual(decoded?.sentAt, 1_700_000_000)
    }

    func test_action_commandStrings_matchLegacyProtocol() {
        // These strings are the live protocol — never change them.
        XCTAssertEqual(WatchWireFormat.encodeAction(.markAsPlayed, episodeId: "e", position: nil, sentAt: 0)["command"] as? String, "mark_as_played")
        XCTAssertEqual(WatchWireFormat.encodeAction(.removeFromQueue, episodeId: "e", position: nil, sentAt: 0)["command"] as? String, "remove_from_queue")
    }
}

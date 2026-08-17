// YourPodsTests/WatchEpisodeListBridgeTests.swift
import XCTest
@testable import YourPods

/// Locks the request_episodes payload to the shared wire format.
/// Regression: iOS sent "id"/"artUri" while the watch parsed "guid"/"imageUrl",
/// so watch library browsing silently returned zero episodes.
final class WatchEpisodeListBridgeTests: XCTestCase {

    func test_requestEpisodesPayload_decodesWithSharedParser() {
        let payload = WatchWireFormat.encodeEpisodeListItem(.init(
            guid: "g-1", title: "Ep", duration: 120,
            audioUrl: "https://example.com/e.mp3", imageUrl: "https://example.com/e.jpg"))
        let decoded = WatchWireFormat.decodeEpisodeListItem(payload)
        XCTAssertEqual(decoded?.guid, "g-1")
        XCTAssertEqual(decoded?.imageUrl, "https://example.com/e.jpg")
    }
}

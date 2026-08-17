import XCTest
@testable import YourPods

/// Wire-format tests for the `/annotations/sync` push body.
///
/// The annotations API speaks a **camelCase** contract — unlike every other
/// endpoint on `YourPodsProClient`, which uses snake_case. The server handler,
/// the web client, and the canonical wire fixture all agree on
/// `episodeUrl`/`podcastUrl`/`noteText`. Encoding snake_case made the
/// server's required-field guard drop every item (`synced: 0`), so iOS creates
/// and deletes silently never reached the web.
final class YourPodsProClientAnnotationsTests: XCTestCase {

    private func firstAnnotation(_ data: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let annotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        return try XCTUnwrap(annotations.first)
    }

    func test_encodeAnnotationSyncBody_usesCamelCaseKeys() throws {
        let item = SyncAnnotationItem(
            id: "11111111-1111-1111-1111-111111111111",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            podcastUrl: "https://feeds.example.com/rss",
            episodeGuid: "guid-1",
            timestampSec: 125.5,
            noteText: "Great point about retention.",
            chapterTitle: nil,
            chapterStartSec: nil,
            transcriptText: nil,
            transcriptStartSec: nil,
            transcriptEndSec: nil,
            color: "blue",
            tags: ["idea"],
            deleted: false
        )

        let first = try firstAnnotation(YourPodsProClient.encodeAnnotationSyncBody([item]))

        // camelCase keys — must match the server contract
        XCTAssertEqual(first["episodeUrl"] as? String, "https://cdn.example.com/ep1.mp3")
        XCTAssertEqual(first["podcastUrl"] as? String, "https://feeds.example.com/rss")
        XCTAssertEqual(first["noteText"] as? String, "Great point about retention.")
        XCTAssertEqual(first["timestampSec"] as? Double, 125.5)
        XCTAssertEqual(first["episodeGuid"] as? String, "guid-1")

        // snake_case keys must be ABSENT — these made the server drop the item
        XCTAssertNil(first["episode_url"], "snake_case leak → server's required-field guard skips the item")
        XCTAssertNil(first["podcast_url"])
        XCTAssertNil(first["note_text"])
        XCTAssertNil(first["timestamp_sec"])
        XCTAssertNil(first["episode_guid"])
    }

    func test_encodeAnnotationSyncBody_deletion_keepsCamelCaseEpisodeKeysAndDeletedFlag() throws {
        // A soft-deleted note pushes deleted=true. The server checks
        // episodeUrl/podcastUrl BEFORE the delete branch, so the tombstone must
        // still carry camelCase episode keys or the delete is dropped.
        let item = SyncAnnotationItem(
            id: "22222222-2222-2222-2222-222222222222",
            episodeUrl: "https://cdn.example.com/ep2.mp3",
            podcastUrl: "https://feeds.example.com/rss",
            episodeGuid: nil,
            timestampSec: 0,
            noteText: "",
            chapterTitle: nil,
            chapterStartSec: nil,
            transcriptText: nil,
            transcriptStartSec: nil,
            transcriptEndSec: nil,
            color: nil,
            tags: [],
            deleted: true
        )

        let first = try firstAnnotation(YourPodsProClient.encodeAnnotationSyncBody([item]))

        XCTAssertEqual(first["deleted"] as? Bool, true)
        XCTAssertEqual(first["episodeUrl"] as? String, "https://cdn.example.com/ep2.mp3")
        XCTAssertEqual(first["podcastUrl"] as? String, "https://feeds.example.com/rss")
        XCTAssertNil(first["episode_url"], "snake_case leak → server drops the delete before the delete branch")
    }
}


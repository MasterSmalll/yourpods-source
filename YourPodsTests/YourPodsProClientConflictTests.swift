import XCTest
@testable import YourPods

/// Tests for the sync-conflict API DTOs and encoding contracts.
/// These test the wire-format round-trip without hitting a server.
final class YourPodsProClientConflictTests: XCTestCase {

    // MARK: - DTO Decoding

    /// The two arrays carry DIFFERENT shapes. This previously asserted the raw
    /// `sync_conflicts` ROW convention — `episodeUrl: "url_rewrite:<old>"` with
    /// `duration: -1` — but the endpoint resolves that convention itself and emits
    /// `{oldUrl, newUrl}`. Asserting the storage format rather than the wire format is
    /// how a response the app could not decode went unnoticed.
    func test_syncConflictsResponse_decodesPositionAndUrlRewriteConflicts() throws {
        let json = """
        {
            "conflicts": [
                {"episodeUrl": "https://e.test/ep1.mp3", "podcastUrl": "https://f.test/feed.xml",
                 "localPosition": 120, "serverPosition": 300, "duration": 3600,
                 "deviceId": "yourpods-iPhone-a1b2c3d4",
                 "occurrenceCount": 1, "updatedAt": "2026-06-12T10:00:00Z"}
            ],
            "urlRewrites": [
                {"oldUrl": "https://old.cdn/ep.mp3", "newUrl": "https://new.cdn/ep.mp3",
                 "occurrenceCount": 1, "updatedAt": "2026-06-12T10:00:00Z"}
            ],
            "total": 2
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ProSyncConflictsResponse.self, from: json)
        XCTAssertEqual(response.conflicts.count, 1)
        XCTAssertEqual(response.urlRewrites.count, 1)
        XCTAssertEqual(response.total, 2)
        XCTAssertEqual(response.conflicts[0].episodeUrl, "https://e.test/ep1.mp3")
        XCTAssertEqual(response.conflicts[0].localPosition, 120)
        XCTAssertEqual(response.conflicts[0].serverPosition, 300)
        XCTAssertEqual(response.conflicts[0].duration, 3600)
        XCTAssertEqual(response.conflicts[0].deviceId, "yourpods-iPhone-a1b2c3d4")
        XCTAssertEqual(response.urlRewrites[0].oldUrl, "https://old.cdn/ep.mp3")
        XCTAssertEqual(response.urlRewrites[0].newUrl, "https://new.cdn/ep.mp3")
    }

    func test_syncConflictsResponse_decodesEmptyLists() throws {
        let json = """
        {"conflicts": [], "urlRewrites": [], "total": 0}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ProSyncConflictsResponse.self, from: json)
        XCTAssertTrue(response.conflicts.isEmpty)
        XCTAssertTrue(response.urlRewrites.isEmpty)
        XCTAssertEqual(response.total, 0)
    }

    /// Only `episodeUrl` is required. Everything else is absent until the server's RSS
    /// enrichment lands, so the DTO must tolerate a bare row.
    ///
    /// This previously decoded `{"id": 5, ...}` and asserted `devicePosition` — a payload
    /// the server has never sent, through a bare `JSONDecoder()` the client does not use.
    /// It passed for months while the real response could not be decoded at all. The
    /// end-to-end shape is pinned through the production client in
    /// `SyncConflictFetchWireTests`; this stays as the narrow optionality check.
    func test_serverConflict_decodesWithOptionalFieldsMissing() throws {
        let json = """
        {"episodeUrl": "https://e.test/ep.mp3"}
        """.data(using: .utf8)!
        let conflict = try JSONDecoder().decode(ProServerConflict.self, from: json)
        XCTAssertEqual(conflict.episodeUrl, "https://e.test/ep.mp3")
        XCTAssertNil(conflict.podcastUrl)
        XCTAssertNil(conflict.localPosition)
        XCTAssertNil(conflict.serverPosition)
        XCTAssertNil(conflict.duration)
        XCTAssertNil(conflict.deviceId)
        XCTAssertNil(conflict.occurrenceCount)
        XCTAssertNil(conflict.updatedAt)
    }

    // MARK: - Request Encoding

    // NOTE: the resolve-conflict request is asserted in `ConflictResolutionWireTests`,
    // which drives the real client. A test here would build its own `JSONEncoder` and so
    // would assert `episodeUrl` while the client's encoder carries `.convertToSnakeCase`
    // and sends `episode_url` — a green test for bytes we never put on the wire.


    func test_resolveAllConflictsRequest_encodesCorrectly() throws {
        let request = ProResolveAllConflictsRequest(resolution: "local")
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(dict["resolution"], "local")
    }

    func test_resolveUrlRewriteRequest_encodesCorrectly() throws {
        let request = ProResolveUrlRewriteRequest(
            oldUrl: "https://old.cdn/feed.xml",
            newUrl: "https://new.cdn/feed.xml",
            accept: true
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["oldUrl"] as? String, "https://old.cdn/feed.xml")
        XCTAssertEqual(dict["newUrl"] as? String, "https://new.cdn/feed.xml")
        // The handler renames only when this is true, and Go decodes an absent bool to
        // false — so omitting it (as iOS did) turns the user's Accept into a Reject.
        XCTAssertEqual(dict["accept"] as? Bool, true)
    }

    /// Decodes the **actual** response body current server releases send, copied from
    /// the server's conflict handler `writeJSON(... map[string]any{"message", "updated", "counts"})`.
    ///
    /// The version this replaces decoded `{"message": "Updated 3 playback records",
    /// "affected": 3}` — a body invented by the test author that no deployment has ever
    /// sent. It passed forever while the production decode of a required `affected` threw
    /// on every real response, turning successful renames into logged failures. A decode
    /// test written against an imagined payload cannot fail; only one written against the
    /// server's own output can.
    func test_resolveUrlRewriteResponse_decodesTheRealServerShape() throws {
        let json = Data("""
        {"message":"url rewrite accepted","updated":3,"counts":{"subscriptions":1,"settings":1,"groups":1}}
        """.utf8)
        let response = try JSONDecoder().decode(ProResolveUrlRewriteResponse.self, from: json)
        XCTAssertEqual(response.updated, 3)
        XCTAssertEqual(response.message, "url rewrite accepted")
    }

    /// Older deployments return `message` alone. Nothing in this body is
    /// load-bearing — the success signal is the HTTP status — so an older server must not
    /// make a successful resolve look like a failure.
    func test_resolveUrlRewriteResponse_toleratesAPreBuild281Body() throws {
        let json = Data(#"{"message":"url rewrite accepted"}"#.utf8)
        let response = try JSONDecoder().decode(ProResolveUrlRewriteResponse.self, from: json)
        XCTAssertNil(response.updated)
    }
}

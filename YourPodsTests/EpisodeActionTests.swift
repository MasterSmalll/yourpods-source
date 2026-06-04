import XCTest
@testable import YourPods

// MARK: - Episode Action Tests

/// Tests EpisodeAction JSON parsing and encoding.
final class EpisodeActionTests: XCTestCase {
    
    func test_from_validJSON_parsesAllFields() {
        let json: [String: Any] = [
            "podcast": "https://example.com/feed",
            "episode": "https://example.com/ep1.mp3",
            "guid": "ep-1",
            "action": "play",
            "timestamp": 1700000000,
            "position": 300,
            "started": 0,
            "total": 3600,
            "device": "swift-client"
        ]
        
        let action = EpisodeAction.from(json: json)
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.podcast, "https://example.com/feed")
        XCTAssertEqual(action?.guid, "ep-1")
        XCTAssertEqual(action?.position, 300)
        XCTAssertEqual(action?.total, 3600)
    }
    
    func test_from_missingRequiredFields_returnsNil() {
        let json: [String: Any] = [
            "podcast": "https://example.com/feed",
            // Missing "episode" and "action"
        ]
        
        XCTAssertNil(EpisodeAction.from(json: json),
                     "Should return nil when required fields are missing")
    }
    
    func test_from_isoTimestamp_parsesCorrectly() {
        let json: [String: Any] = [
            "podcast": "https://example.com/feed",
            "episode": "https://example.com/ep1.mp3",
            "action": "play",
            "timestamp": "2023-11-14T22:13:20Z"
        ]
        
        let action = EpisodeAction.from(json: json)
        XCTAssertNotNil(action)
        // ISO 8601 timestamp "2023-11-14T22:13:20Z" = 1700000000
        XCTAssertEqual(action?.timestamp, 1700000000)
    }
    
    func test_toUploadJSON_includesRequiredFields() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: 1700000000,
            position: 300,
            started: 0,
            total: 3600,
            device: "swift-client"
        )
        
        let json = action.toUploadJSON()
        XCTAssertEqual(json["podcast"] as? String, "https://example.com/feed")
        XCTAssertEqual(json["action"] as? String, "play")
        XCTAssertEqual(json["position"] as? Int, 300)
        XCTAssertEqual(json["guid"] as? String, "ep-1")
        // timestamp should be ISO formatted string
        XCTAssertNotNil(json["timestamp"] as? String)
    }
    
    func test_toUploadJSON_omitsNilOptionals() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: nil,
            action: "play",
            timestamp: 1700000000,
            position: nil,
            started: nil,
            total: nil,
            device: nil
        )
        
        let json = action.toUploadJSON()
        XCTAssertNil(json["guid"], "Nil guid should not be in upload JSON")
        XCTAssertNil(json["position"], "Nil position should not be in upload JSON")
        XCTAssertNil(json["device"], "Nil device should not be in upload JSON")
    }
    
    func test_codable_roundTrip() {
        let original = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: 1700000000,
            position: 300,
            started: 0,
            total: 3600,
            device: "swift-client"
        )
        
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(EpisodeAction.self, from: data)
        
        XCTAssertEqual(decoded.podcast, original.podcast)
        XCTAssertEqual(decoded.guid, original.guid)
        XCTAssertEqual(decoded.position, original.position)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }
}

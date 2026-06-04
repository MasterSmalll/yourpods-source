import XCTest
@testable import YourPods

// MARK: - ProStatsEvent Schema Tests

/// Tests for the updated ProStatsEvent schema (id + timestamp fields).
/// Phase 1 (Red): These will fail until id/timestamp are added to the model.
final class ProStatsEventSchemaTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func makeEvent() -> ProStatsEvent {
        ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: .listen,
            fromPosSec: 0,
            toPosSec: 120.5,
            durationSec: 60.25,
            contentSec: 120.5,
            speed: 2.0,
            deviceId: "yourpods-ios"
        )
    }

    func test_proStatsEvent_encodesIdField() throws {
        let event = makeEvent()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["id"] as? String,
                        "Event JSON must include an 'id' field")
    }

    func test_proStatsEvent_encodesTimestampField() throws {
        let event = makeEvent()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["timestamp"] as? String,
                        "Event JSON must include a 'timestamp' field")
    }

    func test_proStatsEvent_idIsUUIDBetweenEvents() throws {
        let event1 = makeEvent()
        let event2 = makeEvent()

        XCTAssertNotEqual(event1.id, event2.id,
                          "Each event must have a unique UUID")
    }

    func test_proStatsEvent_timestampIsISO8601() throws {
        let event = makeEvent()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Try with fractional seconds first, then without
        var parsed = formatter.date(from: event.timestamp)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsed = formatter.date(from: event.timestamp)
        }

        XCTAssertNotNil(parsed,
                        "Event timestamp '\(event.timestamp)' must be valid ISO 8601")
    }

    func test_proStatsEvent_idSurvivesRoundTrip() throws {
        let event = makeEvent()
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ProStatsEvent.self, from: data)

        XCTAssertEqual(decoded.id, event.id,
                       "id must survive encoding/decoding round-trip")
    }

    func test_proStatsEvent_timestampSurvivesRoundTrip() throws {
        let event = makeEvent()
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ProStatsEvent.self, from: data)

        XCTAssertEqual(decoded.timestamp, event.timestamp,
                       "timestamp must survive encoding/decoding round-trip")
    }
}

// MARK: - Minimum Segment Filter Tests

/// Tests for the minimum recordable segment constraint.
/// Events with contentSec ≤ 1.0 or durationSec ≤ 0.5 must be dropped.
final class MinimumSegmentFilterTests: XCTestCase {

    func test_belowMinimumContentSec_dropsEvent() async {
        let buffer = StatsEventBuffer()

        // contentSec = 0.5 (below 1.0 threshold)
        let event = ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: .listen,
            fromPosSec: 10.0,
            toPosSec: 10.5,
            durationSec: 0.25,
            contentSec: 0.5,
            speed: 1.0,
            deviceId: "yourpods-ios"
        )

        await buffer.recordIfMeetsThreshold(event)

        let pending = await buffer.pending
        XCTAssertTrue(pending.isEmpty,
                      "Event with contentSec=0.5 must be dropped (threshold > 1.0)")
    }

    func test_belowMinimumDurationSec_dropsEvent() async {
        let buffer = StatsEventBuffer()

        // durationSec = 0.3 (below 0.5 threshold)
        let event = ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: .listen,
            fromPosSec: 10.0,
            toPosSec: 12.0,
            durationSec: 0.3,
            contentSec: 2.0,
            speed: 1.0,
            deviceId: "yourpods-ios"
        )

        await buffer.recordIfMeetsThreshold(event)

        let pending = await buffer.pending
        XCTAssertTrue(pending.isEmpty,
                      "Event with durationSec=0.3 must be dropped (threshold > 0.5)")
    }

    func test_atMinimumThreshold_recordsEvent() async {
        let buffer = StatsEventBuffer()

        // contentSec = 1.1 and durationSec = 0.6 (both above thresholds)
        let event = ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: .listen,
            fromPosSec: 10.0,
            toPosSec: 11.1,
            durationSec: 0.6,
            contentSec: 1.1,
            speed: 1.0,
            deviceId: "yourpods-ios"
        )

        await buffer.recordIfMeetsThreshold(event)

        let pending = await buffer.pending
        XCTAssertEqual(pending.count, 1,
                       "Event with contentSec=1.1 and durationSec=0.6 must be recorded")
    }

    func test_skipEvents_bypassMinimumFilter() async {
        let buffer = StatsEventBuffer()

        // Skip events have contentSec=0 and durationSec=0 — they must always be recorded
        let event = ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: .skipManual,
            fromPosSec: 120.0,
            toPosSec: 120.0,
            durationSec: 0,
            contentSec: 0,
            speed: 1.0,
            deviceId: "yourpods-ios"
        )

        await buffer.recordIfMeetsThreshold(event)

        let pending = await buffer.pending
        XCTAssertEqual(pending.count, 1,
                       "Skip events must bypass the minimum segment filter")
    }
}

// MARK: - Buffer Auto-Flush Tests

/// Tests for buffer-limit and periodic timer auto-flush triggers.
final class BufferAutoFlushTests: XCTestCase {

    private func makeEvent(type: ProStatsEventType = .listen) -> ProStatsEvent {
        ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: type,
            fromPosSec: 0,
            toPosSec: 60,
            durationSec: 30,
            contentSec: 60,
            speed: 1.0,
            deviceId: "yourpods-ios"
        )
    }

    func test_bufferLimit_triggersFlush_at50Events() async {
        let buffer = StatsEventBuffer()
        let expectation = XCTestExpectation(description: "onFlushNeeded called at buffer limit")

        await buffer.setFlushHandler {
            expectation.fulfill()
        }

        // Record exactly 50 events
        for _ in 0..<50 {
            await buffer.record(makeEvent())
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_bufferLimit_doesNotFlush_below50() async {
        let buffer = StatsEventBuffer()
        let expectation = XCTestExpectation(description: "onFlushNeeded should NOT be called")
        expectation.isInverted = true

        await buffer.setFlushHandler {
            expectation.fulfill()
        }

        // Record 49 events — should not trigger flush
        for _ in 0..<49 {
            await buffer.record(makeEvent())
        }

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}

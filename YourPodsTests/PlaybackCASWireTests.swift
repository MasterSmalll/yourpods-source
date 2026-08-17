/// Wire format for the playback CAS exchange — per the sync contract (iOS side).
///
/// `PlaybackReconcilerTests` covers the *decision*; this covers the *bytes*. Both halves
/// are needed and neither substitutes for the other: a correct ladder fed a `version` the
/// decoder dropped resolves confidently and wrongly.
///
/// Every test drives the real `YourPodsProClient.syncPlayback(...)` through `any SyncClient`
/// rather than encoding a DTO in isolation. Two shipped regressions say a test that builds
/// its own `JSONEncoder` proves nothing about the call path: the shared encoder carries
/// `.convertToSnakeCase` (silent 400s on camelCase endpoints), and a signature that stops
/// witnessing a `SyncClient` requirement dispatches to the no-op default with no error.
import XCTest
@testable import YourPods

@MainActor
final class PlaybackCASWireTests: XCTestCase {

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestBodies: [Data] = []
        /// Body the stub answers with. Defaults to the current shape.
        nonisolated(unsafe) static var responseBody = Data(#"{"message":"synced","count":0,"accepted":[],"conflicts":[]}"#.utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read > 0 { data.append(buffer, count: read) }
                }
                stream.close()
                Self.requestBodies.append(data)
            } else if let body = request.httpBody {
                Self.requestBodies.append(body)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class StubAuthProvider: AuthProvider, @unchecked Sendable {
        var isAuthenticated: Bool { true }
        var currentUserEmail: String? { "test@example.com" }
        func signIn(email: String, password: String) async throws -> String { "stub-token" }
        func createUser(email: String, password: String) async throws -> String { "stub-token" }
        func getValidToken() async throws -> String { "stub-token" }
        func signOut() async {}
    }

    private var session: URLSession!
    private var client: YourPodsProClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestBodies = []
        MockURLProtocol.responseBody = Data(#"{"message":"synced","count":0,"accepted":[],"conflicts":[]}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: StubAuthProvider(),
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.requestBodies = []
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func push(
        baseVersion: Int64?,
        positionSec: Double = 100,
        completed: Bool? = nil,
        clientUpdatedAt: Date? = nil,
        episodeUrl: String = "https://example.com/ep1.mp3"
    ) async throws -> ProPlaybackSyncResponse? {
        let syncClient: any SyncClient = client
        return try await syncClient.syncPlayback(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: episodeUrl,
            episodeGuid: "guid-1",
            positionSec: positionSec,
            durationSec: 3600,
            nowPlaying: nil,
            completed: completed,
            deviceId: "device-a",
            clientUpdatedAt: clientUpdatedAt,
            baseVersion: baseVersion
        )
    }

    private func sentBody() throws -> [String: Any] {
        guard let data = MockURLProtocol.requestBodies.first,
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("no request body captured")
        }
        return dict
    }

    /// The server decodes the item from a generic map and reads `baseVersion` or
    /// `base_version` from it, so either spelling is on-contract. The shared encoder
    /// emits snake_case; assert on whichever is present rather than pinning a spelling
    /// the server does not care about.
    private func baseVersionOnWire(_ body: [String: Any]) -> Any? {
        body["baseVersion"] ?? body["base_version"]
    }

    // MARK: - baseVersion is tri-state on the wire

    /// `nil` ⇒ the key is **absent**, not `null` and not `0`. Absent is the legacy
    /// last-write-wins path (gPodder bridge, older releases); `0` is a positive claim that no
    /// row exists. Collapsing them turns every legacy push into a fresh-install claim, so
    /// the distinction has to survive encoding — Go reads it as `*int64` for this reason.
    func test_baseVersion_nil_isOmittedEntirely_notNullAndNotZero() async throws {
        try await push(baseVersion: nil)
        let body = try sentBody()
        XCTAssertNil(
            baseVersionOnWire(body),
            "a nil baseVersion must not appear on the wire at all — the server distinguishes absent from 0"
        )
    }

    /// The `0` sentinel must survive as the number `0`. Encoded as absent, a fresh
    /// install silently rejoins the legacy path and its first push clobbers the server.
    func test_baseVersion_zeroSentinel_isEncodedAsZero_notDropped() async throws {
        try await push(baseVersion: 0)
        let body = try sentBody()
        guard let value = baseVersionOnWire(body) else {
            return XCTFail("baseVersion 0 must be present on the wire, not dropped as a falsy value")
        }
        XCTAssertEqual((value as? NSNumber)?.int64Value, 0)
    }

    func test_baseVersion_knownVersion_isEncodedAsANumber() async throws {
        try await push(baseVersion: 41)
        let body = try sentBody()
        XCTAssertEqual((baseVersionOnWire(body) as? NSNumber)?.int64Value, 41)
    }

    // MARK: - clientUpdatedAt must be an RFC3339 string (false-completion Cause B)

    /// The server parses `clientUpdatedAt` as RFC3339 **text**. The shared encoder has no
    /// `dateEncodingStrategy`, so a `Date` goes out as a bare number, the server stores
    /// nil, and every iOS push then looks gPodder-origin — which makes it eligible for the
    /// `ClientUpdatedAt == nil`-gated `position >= duration` auto-complete. That is the
    /// paused-mid-episode-marked-played bug, and it is a wire-format bug, not a logic one.
    func test_clientUpdatedAt_isEncodedAsAnRFC3339String_notANumber() async throws {
        try await push(baseVersion: 7, clientUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try sentBody()
        let value = body["clientUpdatedAt"] ?? body["client_updated_at"]
        guard let text = value as? String else {
            return XCTFail("clientUpdatedAt must be a string — got \(String(describing: value)); a number is dropped to nil server-side and re-opens the false-completion path")
        }
        XCTAssertTrue(
            text.hasPrefix("2023-11-14T22:13:20"),
            "expected an RFC3339 instant, got \(text)"
        )
        XCTAssertNotNil(
            ISO8601DateFormatter().date(from: text)
                ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }().date(from: text),
            "the server calls time.Parse(time.RFC3339, …) — an unparseable string is dropped exactly like a number"
        )
    }

    // MARK: - Response decode

    /// The push has to come back as data. Both call sites discard the response today
    /// (`performPOST` is `@discardableResult`), so `accepted[]`/`conflicts[]` is entirely
    /// new plumbing — a conflict the client never reads is a conflict it never resolves.
    func test_response_decodesAcceptedAndConflicts() async throws {
        MockURLProtocol.responseBody = Data(#"""
        {"message":"synced","count":1,
         "accepted":[{"episodeUrl":"https://example.com/ep1.mp3","version":42}],
         "conflicts":[{"episodeUrl":"https://example.com/ep2.mp3",
                       "server":{"positionSec":2167.4,"completed":true,"nowPlaying":false,"version":12}}]}
        """#.utf8)

        let response = try await push(baseVersion: 41)
        guard let response else { return XCTFail("syncPlayback must return the decoded response") }

        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.accepted.count, 1)
        XCTAssertEqual(response.accepted.first?.episodeUrl, "https://example.com/ep1.mp3")
        XCTAssertEqual(response.accepted.first?.version, 42)

        XCTAssertEqual(response.conflicts.count, 1)
        XCTAssertEqual(response.conflicts.first?.episodeUrl, "https://example.com/ep2.mp3")
        XCTAssertEqual(response.conflicts.first?.server.positionSec, 2167.4)
        XCTAssertEqual(response.conflicts.first?.server.completed, true)
        XCTAssertEqual(response.conflicts.first?.server.nowPlaying, false)
        XCTAssertEqual(response.conflicts.first?.server.version, 12)
    }

    /// A conflict entry must reach the reconciler without losing a field — `nowPlaying`
    /// in particular, since ladder steps (b) and (c) cannot be evaluated without it and a
    /// dropped `false` would look exactly like a dropped `true`.
    func test_conflict_mapsIntoTheReconcilersInputType() async throws {
        MockURLProtocol.responseBody = Data(#"""
        {"message":"synced","count":0,"accepted":[],
         "conflicts":[{"episodeUrl":"https://example.com/ep2.mp3",
                       "server":{"positionSec":2167.4,"completed":false,"nowPlaying":true,"version":12}}]}
        """#.utf8)

        let response = try await push(baseVersion: 41)
        XCTAssertEqual(
            response?.conflicts.first?.server.asPlaybackConflict,
            ServerPlaybackConflict(positionSec: 2167.4, completed: false, nowPlaying: true, version: 12)
        )
    }

    /// EDGE: an older server answers `{"message":"synced","count":1}` with
    /// no arrays at all. That must decode as empty, not throw — a hard failure here would
    /// break every push against an un-migrated deployment, turning a rollout ordering
    /// problem into total sync loss.
    func test_response_legacyShapeWithoutArrays_decodesAsEmpty_ratherThanThrowing() async throws {
        MockURLProtocol.responseBody = Data(#"{"message":"synced","count":1}"#.utf8)

        let response = try await push(baseVersion: nil)
        XCTAssertEqual(response?.count, 1)
        XCTAssertEqual(response?.accepted, [])
        XCTAssertEqual(response?.conflicts, [])
    }

    /// EDGE: an empty body (a proxy stripping it, or a 204-shaped answer) must not throw
    /// either. The push itself succeeded; there is simply nothing to act on.
    func test_response_emptyBody_isNotAnError() async throws {
        MockURLProtocol.responseBody = Data()
        let response = try await push(baseVersion: nil)
        XCTAssertNil(response, "an unparseable body means no CAS answer, not a failed push")
    }

    // MARK: - The batch path must carry an event time too

    /// `uploadEpisodeActions` posts to the same `/playback/sync` endpoint, and it dropped
    /// the event time it already had: `EpisodeAction.timestamp` is a Unix instant, and
    /// every batched item went out with no `clientUpdatedAt` at all.
    ///
    /// Server-side that is indistinguishable from a gPodder-origin write, which is the
    /// exact gate on the `position >= duration` auto-complete. Paired with a frozen or
    /// short `QueueItem` duration, an episode paused near the end satisfies
    /// `position >= duration` and comes back marked played. Same false-completion class
    /// the single-push path was fixed for — this is the route that stayed open.
    func test_batchUpload_carriesTheActionsEventTime_notNil() async throws {
        let syncClient: any SyncClient = client
        let eventTime = 1_700_000_000

        _ = try await syncClient.uploadEpisodeActions([
            EpisodeAction(
                podcast: "https://feeds.example.com/podcast",
                episode: "https://example.com/ep1.mp3",
                guid: "guid-1",
                action: "play",
                timestamp: eventTime,
                position: 2100,
                started: 0,
                total: 2167,
                device: "device-a"
            )
        ])

        guard let data = MockURLProtocol.requestBodies.first,
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let item = items.first else {
            return XCTFail("expected a JSON array body")
        }
        let value = item["clientUpdatedAt"] ?? item["client_updated_at"]
        guard let text = value as? String else {
            return XCTFail("batched play actions must carry their own event time — got \(String(describing: value)); nil makes an iOS push look gPodder-origin and eligible for the position>=duration auto-complete")
        }
        XCTAssertTrue(
            text.hasPrefix("2023-11-14T22:13:20"),
            "must be the action's own timestamp, not now() — a re-sent outbox entry would otherwise win against newer server state. Got \(text)"
        )
    }

    /// EDGE: an action with no usable timestamp must omit the field rather than send the
    /// epoch. `1970-01-01` is not "unknown" to the server — it is a very old event time
    /// that loses every ordering comparison, which silently discards the push.
    func test_batchUpload_omitsEventTime_whenTheActionHasNone() async throws {
        let syncClient: any SyncClient = client

        _ = try await syncClient.uploadEpisodeActions([
            EpisodeAction(
                podcast: "https://feeds.example.com/podcast",
                episode: "https://example.com/ep1.mp3",
                guid: nil,
                action: "play",
                timestamp: 0,
                position: 10,
                started: nil,
                total: nil,
                device: nil
            )
        ])

        guard let data = MockURLProtocol.requestBodies.first,
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let item = items.first else {
            return XCTFail("expected a JSON array body")
        }
        XCTAssertNil(
            item["clientUpdatedAt"] ?? item["client_updated_at"],
            "a zero timestamp must be omitted, not sent as 1970 — the epoch loses every event-time comparison"
        )
    }

    /// `episodeUrl` is echoed byte-for-byte in both arrays (per the sync contract) and the
    /// client maps outcomes back by that exact string. Anything that normalizes it —
    /// percent-decoding, case-folding the host, dropping a query — leaves the ack
    /// unmatched and the episode permanently dirty.
    func test_episodeUrl_isMatchedByteForByte_notNormalized() async throws {
        let awkward = "https://CDN.Example.com/ep%20one+two.mp3?token=a%2Bb&t=1"
        MockURLProtocol.responseBody = Data(#"""
        {"message":"synced","count":1,
         "accepted":[{"episodeUrl":"https://CDN.Example.com/ep%20one+two.mp3?token=a%2Bb&t=1","version":9}],
         "conflicts":[]}
        """#.utf8)

        let response = try await push(baseVersion: 8, episodeUrl: awkward)
        XCTAssertEqual(
            response?.accepted.first?.episodeUrl, awkward,
            "the echoed URL must survive decoding unchanged — the client has no other key to map the ack by"
        )
    }
}

/// Wire format for FETCHING conflicts — GET /api/yourpods/sync-conflicts.
///
/// `ConflictResolutionWireTests` pins the push direction and states the rule this file
/// applies to the pull direction: *a DTO test that skips the client's decoder is not a
/// wire test*. `YourPodsProClientConflictTests` decodes `{"id": 5, "episodeUrl": ...}`
/// through a bare `JSONDecoder()` — a payload the server has never sent, through a
/// decoder the client does not use. It passed for months while the feature was dead.
///
/// The real response could not be decoded at all, four ways at once:
///   1. `id` was a non-optional `Int`; the server sends no `id` (it keys by episodeUrl).
///   2. `devicePosition` — the server's field is `localPosition`.
///   3. positions and duration were `Int?`; the server sends floats (`2167.4`).
///   4. `urlRewrites` reused `ProServerConflict`, requiring `episodeUrl`, but the server
///      emits `{oldUrl, newUrl, ...}` for that array.
///
/// Any of the four throws, and step 5f swallows it into `logger.error(...)`, so the
/// symptom is silence: a Pro subscriber's conflict sheet never appears and nothing in
/// the app says why. That is the whole of "the user is never prompted to choose".
///
/// The fixtures below are the literal shape of `positionConflict` / `urlRewrite` as
/// emitted by the server's conflict handler — camelCase, floats, and a `deviceId`
/// added later for the sheet labels.
import XCTest
@testable import YourPods

@MainActor
final class SyncConflictFetchWireTests: XCTestCase {

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responseBody = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
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
        MockURLProtocol.responseBody = Data()
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
        MockURLProtocol.responseBody = Data()
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - The real server payload

    /// Exactly what the Go handler serialises for one position conflict: no `id`,
    /// `localPosition` (not `devicePosition`), and floats for every position.
    private static let realPositionConflictResponse = """
    {
      "conflicts": [
        {
          "episodeUrl": "https://cdn.example.com/ep1.mp3",
          "podcastUrl": "https://feeds.example.com/show.xml",
          "localPosition": 828,
          "serverPosition": 2167.4,
          "duration": 3600,
          "deviceId": "yourpods-iPhone-a1b2c3d4",
          "occurrenceCount": 2,
          "updatedAt": "2026-07-31T02:00:00Z",
          "episodeTitle": "Episode One",
          "podcastTitle": "Test Show",
          "artUrl": "https://cdn.example.com/art.jpg"
        }
      ],
      "urlRewrites": [],
      "total": 1
    }
    """

    func test_getSyncConflicts_decodesTheRealServerPayload() async throws {
        MockURLProtocol.responseBody = Data(Self.realPositionConflictResponse.utf8)

        let response = try await client.getSyncConflicts()

        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.conflicts.count, 1,
                       "The conflict list must decode — step 5f swallows a throw into a log line, so a decode failure presents as a sheet that never appears")

        let conflict = try XCTUnwrap(response.conflicts.first)
        XCTAssertEqual(conflict.episodeUrl, "https://cdn.example.com/ep1.mp3")
        XCTAssertEqual(conflict.podcastUrl, "https://feeds.example.com/show.xml")
        XCTAssertEqual(conflict.localPosition ?? 0, 828, accuracy: 0.001,
                       "The server's field is localPosition; devicePosition never existed on the wire")
        XCTAssertEqual(conflict.serverPosition ?? 0, 2167.4, accuracy: 0.001,
                       "Positions are floats server-side — an Int? property throws on 2167.4")
        XCTAssertEqual(conflict.duration ?? 0, 3600, accuracy: 0.001)
        XCTAssertEqual(conflict.deviceId, "yourpods-iPhone-a1b2c3d4",
                       "Needed to label the sheet correctly")
        XCTAssertEqual(conflict.occurrenceCount, 2)
        XCTAssertEqual(conflict.episodeTitle, "Episode One")
        XCTAssertEqual(conflict.podcastTitle, "Test Show")
        XCTAssertEqual(conflict.artUrl, "https://cdn.example.com/art.jpg")
    }

    /// The URL-rewrite array has a different shape from the position array. Decoding it
    /// as the same type made one rewrite poison the entire response, taking the position
    /// conflicts down with it.
    func test_getSyncConflicts_decodesUrlRewrites_withTheirOwnShape() async throws {
        MockURLProtocol.responseBody = Data("""
        {
          "conflicts": [],
          "urlRewrites": [
            {
              "oldUrl": "https://cdn.example.com/old.mp3",
              "newUrl": "https://cdn.example.com/new.mp3",
              "occurrenceCount": 1,
              "updatedAt": "2026-07-31T02:00:00Z"
            }
          ],
          "total": 1
        }
        """.utf8)

        let response = try await client.getSyncConflicts()

        XCTAssertEqual(response.urlRewrites.count, 1)
        let rewrite = try XCTUnwrap(response.urlRewrites.first)
        XCTAssertEqual(rewrite.oldUrl, "https://cdn.example.com/old.mp3",
                       "The server strips the url_rewrite: prefix itself and emits oldUrl")
        XCTAssertEqual(rewrite.newUrl, "https://cdn.example.com/new.mp3")
    }

    /// A rewrite and a position conflict in the same response — the case that proves the
    /// two arrays are decoded independently.
    func test_getSyncConflicts_bothArraysPopulated_neitherPoisonsTheOther() async throws {
        MockURLProtocol.responseBody = Data("""
        {
          "conflicts": [
            {
              "episodeUrl": "https://cdn.example.com/ep1.mp3",
              "podcastUrl": "https://feeds.example.com/show.xml",
              "localPosition": 12.5,
              "serverPosition": 900,
              "duration": 1800,
              "occurrenceCount": 1,
              "updatedAt": "2026-07-31T02:00:00Z"
            }
          ],
          "urlRewrites": [
            {
              "oldUrl": "https://cdn.example.com/old.mp3",
              "newUrl": "https://cdn.example.com/new.mp3",
              "occurrenceCount": 1,
              "updatedAt": "2026-07-31T02:00:00Z"
            }
          ],
          "total": 2
        }
        """.utf8)

        let response = try await client.getSyncConflicts()
        XCTAssertEqual(response.conflicts.count, 1)
        XCTAssertEqual(response.urlRewrites.count, 1)
    }

    /// Metadata is optional: `enrichSyncConflict` backfills titles and art from RSS on
    /// the GET, but a row read before that fetch succeeds carries none of it.
    func test_getSyncConflicts_decodesWithMetadataAbsent() async throws {
        MockURLProtocol.responseBody = Data("""
        {
          "conflicts": [
            {
              "episodeUrl": "https://cdn.example.com/ep1.mp3",
              "podcastUrl": "https://feeds.example.com/show.xml",
              "localPosition": 100,
              "serverPosition": 200,
              "duration": 0,
              "occurrenceCount": 1,
              "updatedAt": "2026-07-31T02:00:00Z"
            }
          ],
          "urlRewrites": [],
          "total": 1
        }
        """.utf8)

        let response = try await client.getSyncConflicts()
        let conflict = try XCTUnwrap(response.conflicts.first)
        XCTAssertNil(conflict.episodeTitle)
        XCTAssertNil(conflict.artUrl)
        XCTAssertNil(conflict.deviceId, "Bridge-written rows carry no device")
    }

    /// `serverCompleted` (added by the corresponding server change) is what lets the sheet say **Played**
    /// instead of rendering a completed row's `position_sec = duration` as `1:00:00`.
    func test_getSyncConflicts_decodesServerCompleted() async throws {
        MockURLProtocol.responseBody = Data("""
        {
          "conflicts": [
            {
              "episodeUrl": "https://cdn.example.com/ep1.mp3",
              "podcastUrl": "https://feeds.example.com/show.xml",
              "localPosition": 828,
              "serverPosition": 3600,
              "duration": 3600,
              "serverCompleted": true,
              "occurrenceCount": 1,
              "updatedAt": "2026-08-01T02:00:00Z"
            }
          ],
          "urlRewrites": [],
          "total": 1
        }
        """.utf8)

        let response = try await client.getSyncConflicts()
        let conflict = try XCTUnwrap(response.conflicts.first)
        XCTAssertEqual(conflict.serverCompleted, true)
    }

    /// The deployed server predates the field. Absent must decode — not throw, which
    /// would take the whole list down again — and must not read as played.
    func test_getSyncConflicts_serverCompletedAbsent_decodesAsNil() async throws {
        MockURLProtocol.responseBody = Data(Self.realPositionConflictResponse.utf8)

        let response = try await client.getSyncConflicts()
        let conflict = try XCTUnwrap(response.conflicts.first)
        XCTAssertNil(conflict.serverCompleted,
                     "a required Bool here would throw on every response the live server sends")
    }
}

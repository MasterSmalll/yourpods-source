/// Delta-cursor tests for `GET /playback/recent`, per the sync contract.
///
/// Two defects, one fix. The server parses `?since=` as **RFC3339 only** and silently
/// serves a full sync for anything else, so iOS — which sent a Unix integer — has never
/// received a real delta (≈194 KB per poll observed in the field). And on the Pro path
/// `getEpisodeActionsWithHiddenChanges` discarded the response's `timestamp`, leaving
/// `EpisodeActionSyncService` to advance its cursor from `max(action.timestamp)` —
/// values stamped by whichever *client* wrote the action. The moment the server's parser
/// accepts our cursor, a device whose clock runs ahead would starve itself of changes.
///
/// The sync contract: "Clients get a real delta today by passing back the RFC3339
/// `timestamp` from the previous response." So the cursor is the server's own token,
/// round-tripped verbatim and never derived from a client clock.
///
/// These drive the real `YourPodsProClient` through a stubbed session, because
/// `EpisodeActionSyncService` branches on the concrete Pro type — a protocol mock would
/// silently take the gPodder path and prove nothing.
import SwiftData
import XCTest
@testable import YourPods

@MainActor
final class PlaybackDeltaCursorTests: XCTestCase {

    /// The token the server hands back. Deliberately carries fractional seconds and a
    /// `Z` offset — the shape the cursor must survive intact.
    private static let serverToken = "2026-07-30T01:28:30.674Z"

    /// An action stamped by a client whose clock runs years fast. Today's cursor logic
    /// adopts this; a server-token cursor must ignore it entirely.
    private static let skewedClientStamp = "2030-01-01T00:00:00Z"

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestedURLs: [URL] = []
        nonisolated(unsafe) static var body = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let url = request.url { Self.requestedURLs.append(url) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
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

    private var container: ModelContainer!
    private var context: ModelContext!
    private var client: YourPodsProClient!
    private var service: EpisodeActionSyncService!
    private let profileId = "test-profile-cursor"

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestedURLs = []
        MockURLProtocol.body = Self.recentResponseJSON()
        UserDefaults.standard.removeObject(forKey: "lastEpisodeActionSync_\(profileId)")
        UserDefaults.standard.removeObject(forKey: "lastEpisodeActionSyncToken_\(profileId)")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: StubAuthProvider(),
            session: URLSession(configuration: sessionConfig)
        )

        let proClient = client!
        let pid = profileId
        service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { proClient },
            profileIdProvider: { pid },
            deviceIdProvider: { "test-device" },
            outboxFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cursor-outbox-\(UUID().uuidString).json"),
            completionOutboxFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cursor-completions-\(UUID().uuidString).json")
        )
        service.setSyncStore(nil)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "lastEpisodeActionSync_\(profileId)")
        UserDefaults.standard.removeObject(forKey: "lastEpisodeActionSyncToken_\(profileId)")
        MockURLProtocol.requestedURLs = []
        service = nil
        client = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func recentResponseJSON() -> Data {
        let json = """
        {
          "states": [
            {
              "podcastUrl": "https://example.com/feed.xml",
              "episodeUrl": "https://example.com/ep-1.mp3",
              "episodeGuid": "ep-1",
              "positionSec": 100,
              "durationSec": 3600,
              "updatedAt": "\(skewedClientStamp)",
              "completed": false,
              "hidden": false
            }
          ],
          "timestamp": "\(serverToken)"
        }
        """
        return Data(json.utf8)
    }

    private var recentRequests: [URL] {
        MockURLProtocol.requestedURLs.filter { $0.path.hasSuffix("/playback/recent") }
    }

    // MARK: - Parse

    /// The response's `timestamp` is the cursor. It was being decoded and thrown away.
    func test_parseRecentResponse_extractsServerTimestampToken() throws {
        let parsed = try YourPodsProClient.parseRecentResponse(Self.recentResponseJSON())

        XCTAssertEqual(parsed.serverToken, Self.serverToken,
                       "The server's RFC3339 timestamp must be surfaced — it is the only cursor that is not derived from a client clock")
    }

    // MARK: - Round trip

    /// THE REGRESSION. After one sync, the next request must carry the server's
    /// own token — not a value derived from `max(action.timestamp)`, which is stamped by
    /// whichever client wrote the action and can sit arbitrarily far in the future.
    func test_pull_sendsServerToken_notClientStampedActionTimestamp() async throws {
        _ = try await service.syncEpisodeActions(force: false)
        // A pull holds the token; the orchestrator commits it once the window's changes
        // have been applied. Without this the cursor never advances — which is the point
        // of DeltaCursorCommitTests, and would make the assertion below untestable here.
        service.commitCursorToken()
        _ = try await service.syncEpisodeActions(force: false)

        XCTAssertEqual(recentRequests.count, 2, "Both syncs must have hit /playback/recent")

        let secondQuery = recentRequests[1].query ?? ""
        XCTAssertTrue(secondQuery.contains("since="),
                      "The second sync must send a cursor, not request a full sync forever")
        let sent = URLComponents(url: recentRequests[1], resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "since" })?.value

        XCTAssertEqual(sent, Self.serverToken,
                       "The cursor must be the server's RFC3339 token round-tripped verbatim — the server parses ?since= as RFC3339 only and silently full-syncs anything else")
        XCTAssertFalse(secondQuery.contains("1893456000"),
                       "The cursor must not be derived from a client-stamped action timestamp (2030 skew)")
    }

    /// EDGE: with no stored token the first request must omit `since` entirely rather
    /// than invent one — a fabricated cursor could skip changes the server still holds.
    func test_pull_omitsSince_onFirstSyncWithNoStoredToken() async throws {
        _ = try await service.syncEpisodeActions(force: false)

        XCTAssertEqual(recentRequests.count, 1)
        let query = recentRequests[0].query ?? ""
        XCTAssertFalse(query.contains("since="),
                       "A first sync has no cursor to pass back — it must request a full sync by omitting ?since=")
    }

    /// `force` means "re-pull all history", so it must discard a stored cursor.
    func test_pull_omitsSince_whenForced_evenWithStoredToken() async throws {
        _ = try await service.syncEpisodeActions(force: false)
        // The commit is what stores it. Without it this test passes for the wrong reason:
        // there would be no stored cursor for the forced pull to ignore.
        service.commitCursorToken()
        _ = try await service.syncEpisodeActions(force: true)

        XCTAssertEqual(recentRequests.count, 2)
        let forcedQuery = recentRequests[1].query ?? ""
        XCTAssertFalse(forcedQuery.contains("since="),
                       "A forced sync must ignore the stored cursor and pull all history")
    }
}

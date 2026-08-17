import XCTest
@testable import YourPods

/// Regression: `getCurrentPlayback()` must dispatch to the REAL networked
/// implementation when called through the `any SyncClient` protocol.
///
/// The bug: `YourPodsProClient.getCurrentPlayback(episodeUrl: String? = nil)`
/// carried an extra defaulted parameter, so its declaration name was
/// `getCurrentPlayback(episodeUrl:)` — which does NOT witness the protocol
/// requirement `getCurrentPlayback()`. A defaulted argument lets you *call* the
/// method as `getCurrentPlayback()` on the CONCRETE type, but it does not
/// satisfy the protocol requirement. Every production call site holds the
/// client as `any SyncClient` (`ProSyncOrchestrator.client`,
/// `PlayerManager.syncClient`), so the call dispatched to the protocol
/// extension's default no-op (`SyncClient.getCurrentPlayback()` → `return nil`)
/// and the now-playing read was silently dropped on every sync — web→iOS
/// handoff never delivered the playing episode.
///
/// These tests pin the dispatch by upcasting to `any SyncClient` BEFORE the
/// call. Do not "simplify" the upcast away — calling on the concrete type
/// would mask the regression.
@MainActor
final class GetCurrentPlaybackDispatchTests: XCTestCase {

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?
        nonisolated(unsafe) static var requestedPaths: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestedPaths.append(request.url?.path ?? "<none>")
            guard let handler = Self.handler else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let (data, response) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
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

    /// The exact shape the server returns for GET /api/yourpods/playback/current
    /// (camelCase keys, `{ "state": { ... } }` wrapper) — captured from a real
    /// web session playing an in-progress, non-completed episode.
    private let activeStateBody = #"""
    {
        "state": {
            "artUrl": "https://example.com/art.jpg",
            "completed": false,
            "durationSec": 1871.255425,
            "episodeGuid": "5f605634-bfe5-11f0-8a48-3fbebc80a7c1",
            "episodeUrl": "https://traffic.megaphone.fm/VMP5240459148.mp3",
            "nowPlaying": true,
            "podcastTitle": "Prof G Markets",
            "podcastUrl": "https://feeds.megaphone.fm/profgmarkets",
            "positionSec": 975.752997,
            "title": "Snap's Crucible Moment Flops On Wall Street",
            "updatedAt": "2026-06-19T16:27:11.734393Z"
        }
    }
    """#

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestedPaths = []
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
        MockURLProtocol.handler = nil
        MockURLProtocol.requestedPaths = []
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Calling through `any SyncClient` must hit the network and decode the
    /// server's state — not silently return the protocol-default no-op nil.
    func test_getCurrentPlayback_throughSyncClientProtocol_returnsDecodedState() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (self.activeStateBody.data(using: .utf8)!, response)
        }

        // Upcast to the protocol — this is how every production call site holds
        // the client. The bug only manifests through the witness table.
        let syncClient: any SyncClient = client

        let state = try await syncClient.getCurrentPlayback()

        // The no-op default makes NO network request and returns nil. The real
        // implementation requests /playback/current and decodes the body.
        XCTAssertTrue(
            MockURLProtocol.requestedPaths.contains("/api/yourpods/playback/current"),
            "getCurrentPlayback() through the protocol must reach the network — got requests: \(MockURLProtocol.requestedPaths)"
        )
        let unwrapped = try XCTUnwrap(
            state,
            "getCurrentPlayback() through `any SyncClient` returned nil — it dispatched to the no-op default instead of the real implementation"
        )
        XCTAssertEqual(unwrapped.episodeUrl, "https://traffic.megaphone.fm/VMP5240459148.mp3")
        XCTAssertEqual(unwrapped.podcastUrl, "https://feeds.megaphone.fm/profgmarkets")
        XCTAssertEqual(unwrapped.nowPlaying, true)
        XCTAssertEqual(unwrapped.completed, false)
        XCTAssertEqual(Int(unwrapped.positionSec), 975)
    }
}

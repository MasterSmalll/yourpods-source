import XCTest
@testable import YourPods

/// Regression pin: `YourPodsProClient.addToQueue` must witness the `SyncClient`
/// protocol requirement. Calling through `any SyncClient` must POST to
/// /api/yourpods/queue/add (additive re-add), not dispatch to the no-op default.
@MainActor
final class AddToQueueClientTests: XCTestCase {

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestedPaths: [String] = []
        nonisolated(unsafe) static var requestedMethods: [String] = []
        nonisolated(unsafe) static var requestBodies: [Data] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestedPaths.append(request.url?.path ?? "<none>")
            Self.requestedMethods.append(request.httpMethod ?? "<none>")
            if let body = request.httpBodyStream {
                body.open()
                var data = Data()
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while body.hasBytesAvailable {
                    let bytesRead = body.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 { data.append(buffer, count: bytesRead) }
                }
                body.close()
                Self.requestBodies.append(data)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
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
        MockURLProtocol.requestedPaths = []
        MockURLProtocol.requestedMethods = []
        MockURLProtocol.requestBodies = []
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
        MockURLProtocol.requestedPaths = []
        MockURLProtocol.requestedMethods = []
        MockURLProtocol.requestBodies = []
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Calling through `any SyncClient` must POST to the additive queue/add endpoint.
    func test_addToQueue_throughSyncClientProtocol_postsToCorrectPath() async throws {
        let syncClient: any SyncClient = client
        let item = QueueSyncItem(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "guid-1",
            sortOrder: 0,
            positionSec: nil,
            title: "Episode 1",
            podcastTitle: "Example Podcast",
            artworkUrl: nil
        )

        try await syncClient.addToQueue(item: item, addToTop: false)

        XCTAssertTrue(
            MockURLProtocol.requestedPaths.contains("/api/yourpods/queue/add"),
            "addToQueue() through the protocol must POST to /api/yourpods/queue/add — got: \(MockURLProtocol.requestedPaths)"
        )
        XCTAssertTrue(
            MockURLProtocol.requestedMethods.contains("POST"),
            "addToQueue() must use POST — got: \(MockURLProtocol.requestedMethods)"
        )
    }

    /// The request body must use camelCase keys matching the server's Go struct tags
    /// (json:"episodeUrl", json:"addToTop"). The shared encoder uses .convertToSnakeCase
    /// which would produce episode_url/add_to_top — those silently 400 on the server.
    func test_addToQueue_encodesEpisodeUrlAndAddToTop() async throws {
        let syncClient: any SyncClient = client
        let episodeUrl = "https://example.com/ep42.mp3"
        let item = QueueSyncItem(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: episodeUrl,
            episodeGuid: nil,
            sortOrder: 0,
            positionSec: nil,
            title: "Episode 42",
            podcastTitle: "Example Podcast",
            artworkUrl: "https://example.com/art.jpg"
        )

        try await syncClient.addToQueue(item: item, addToTop: true)

        guard let bodyData = MockURLProtocol.requestBodies.first,
              let bodyDict = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("No request body captured")
            return
        }
        // addToQueue uses a plain JSONEncoder (camelCase) to match the server's Go struct tags
        XCTAssertEqual(bodyDict["episodeUrl"] as? String, episodeUrl,
                       "episodeUrl must be camelCase on the wire (server decodes json:\"episodeUrl\")")
        XCTAssertEqual(bodyDict["addToTop"] as? Bool, true,
                       "addToTop must be camelCase on the wire (server decodes json:\"addToTop\")")
        // Confirm the snake_case variants are NOT present
        XCTAssertNil(bodyDict["episode_url"], "snake_case episode_url must not appear — server would 400")
        XCTAssertNil(bodyDict["add_to_top"], "snake_case add_to_top must not appear — server would 400")
    }

    /// addToTop: false must be encoded explicitly (not omitted) so the server places at bottom.
    func test_addToQueue_encodesAddToTopFalse() async throws {
        let syncClient: any SyncClient = client
        let item = QueueSyncItem(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil,
            sortOrder: 0,
            positionSec: nil,
            title: nil,
            podcastTitle: nil,
            artworkUrl: nil
        )

        try await syncClient.addToQueue(item: item, addToTop: false)

        guard let bodyData = MockURLProtocol.requestBodies.first,
              let bodyDict = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("No request body captured")
            return
        }
        // addToTop: false must be explicitly encoded in camelCase
        XCTAssertEqual(bodyDict["addToTop"] as? Bool, false,
                       "addToTop: false must be explicitly encoded in camelCase")
        XCTAssertNil(bodyDict["add_to_top"], "snake_case add_to_top must not appear — server would 400")
    }
}

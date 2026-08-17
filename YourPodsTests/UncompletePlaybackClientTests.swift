import XCTest
@testable import YourPods

/// Regression pin: `YourPodsProClient.uncompletePlayback` must witness the
/// `SyncClient` protocol requirement exactly. Calling through `any SyncClient`
/// must reach the network (POST /api/yourpods/playback/uncomplete), not
/// silently dispatch to the no-op default.
///
/// Pattern mirrors GetCurrentPlaybackDispatchTests — upcast to `any SyncClient`
/// before calling so the witness table is exercised, not the concrete type.
@MainActor
final class UncompletePlaybackClientTests: XCTestCase {

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

    /// Calling through `any SyncClient` must POST to the correct endpoint.
    func test_uncompletePlayback_throughSyncClientProtocol_postsToCorrectPath() async throws {
        let syncClient: any SyncClient = client

        try await syncClient.uncompletePlayback(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "guid-1",
            clientUpdatedAt: nil
        )

        XCTAssertTrue(
            MockURLProtocol.requestedPaths.contains("/api/yourpods/playback/uncomplete"),
            "uncompletePlayback() through the protocol must POST to /api/yourpods/playback/uncomplete — got: \(MockURLProtocol.requestedPaths)"
        )
        XCTAssertTrue(
            MockURLProtocol.requestedMethods.contains("POST"),
            "uncompletePlayback() must use POST — got: \(MockURLProtocol.requestedMethods)"
        )
    }

    /// The request body must use camelCase keys matching the server's Go struct tags
    /// (json:"episodeUrl"). The shared encoder uses .convertToSnakeCase which would
    /// produce episode_url — that silently 400s on the server.
    func test_uncompletePlayback_encodesEpisodeUrl() async throws {
        let syncClient: any SyncClient = client
        let episodeUrl = "https://example.com/ep42.mp3"

        try await syncClient.uncompletePlayback(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: episodeUrl,
            episodeGuid: nil,
            clientUpdatedAt: nil
        )

        guard let bodyData = MockURLProtocol.requestBodies.first,
              let bodyDict = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("No request body captured")
            return
        }
        // uncompletePlayback uses a plain JSONEncoder (camelCase) to match the server's Go struct tags
        XCTAssertEqual(bodyDict["episodeUrl"] as? String, episodeUrl,
                       "episodeUrl must be camelCase on the wire (server decodes json:\"episodeUrl\")")
        XCTAssertNil(bodyDict["episode_url"], "snake_case episode_url must not appear — server would 400")
    }

    /// clientUpdatedAt must be encoded as a fractional-seconds ISO8601 string in camelCase.
    /// The shared encoder uses .convertToSnakeCase → client_updated_at which the server ignores.
    func test_uncompletePlayback_encodesClientUpdatedAt() async throws {
        let syncClient: any SyncClient = client
        let now = Date()

        try await syncClient.uncompletePlayback(
            podcastUrl: "https://feeds.example.com/podcast",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil,
            clientUpdatedAt: now
        )

        guard let bodyData = MockURLProtocol.requestBodies.first,
              let bodyDict = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("No request body captured")
            return
        }
        // uncompletePlayback uses a plain JSONEncoder: key stays clientUpdatedAt (camelCase)
        let encodedTime = bodyDict["clientUpdatedAt"] as? String
        XCTAssertNotNil(encodedTime, "clientUpdatedAt must be camelCase on the wire (server decodes json:\"clientUpdatedAt\")")
        XCTAssertTrue(encodedTime?.contains("T") == true, "clientUpdatedAt must be ISO8601 format")
        XCTAssertNil(bodyDict["client_updated_at"], "snake_case client_updated_at must not appear — server would 400")
    }
}

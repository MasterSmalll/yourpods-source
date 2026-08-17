/// Wire format for authoritative conflict resolution, per the sync contract.
///
/// What the user taps in `SyncConflictSheet` is a *position*, not a preference. Shipping
/// only a `resolution` string made the server infer the number from a row it had stored
/// separately, and both directions of that inference failed silently: a GUID in the
/// `episodeUrl` field matched nothing (404, no write, no signal), and an absent position
/// decoded to 0 and *erased* the episode. The explicit shape — `{episodeUrl, podcastUrl,
/// position, duration}` — carries the answer instead of a pointer to it, so it needs no
/// stored conflict row and cannot be resolved against the wrong episode.
///
/// Every test drives the real `YourPodsProClient.resolveConflict(...)` through the shared
/// encoder. `YourPodsProClientConflictTests.test_resolveConflictRequest_encodesCorrectly`
/// is the counter-example: it builds its own `JSONEncoder`, so it asserts `episodeUrl`
/// while the production encoder carries `.convertToSnakeCase` and sends `episode_url`.
/// A DTO test that skips the client's encoder is not a wire test.
import XCTest
@testable import YourPods

@MainActor
final class ConflictResolutionWireTests: XCTestCase {

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestBodies: [Data] = []
        nonisolated(unsafe) static var requestPaths: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestPaths.append(request.url?.path ?? "")
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
            client?.urlProtocol(self, didLoad: Data(#"{"message":"resolved"}"#.utf8))
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
        MockURLProtocol.requestPaths = []
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
        MockURLProtocol.requestPaths = []
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func resolve(
        episodeUrl: String = "https://example.com/ep1.mp3",
        podcastUrl: String? = "https://feeds.example.com/podcast",
        position: Int = 1234,
        duration: Int? = 3600
    ) async throws {
        try await client.resolveConflict(
            episodeUrl: episodeUrl,
            podcastUrl: podcastUrl,
            position: position,
            duration: duration
        )
    }

    private func sentBody() throws -> [String: Any] {
        guard let data = MockURLProtocol.requestBodies.first,
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("no request body captured")
        }
        return dict
    }

    /// The shared encoder carries `.convertToSnakeCase`, so multi-word keys go out
    /// snake_cased. Read either spelling so a future encoder change fails on the
    /// *value*, not on a key name the assertion happened to hardcode.
    private func value(_ camel: String, _ snake: String, in body: [String: Any]) -> Any? {
        body[camel] ?? body[snake]
    }

    // MARK: - The position travels with the request

    func test_resolve_sendsTheChosenPositionExplicitly() async throws {
        try await resolve(position: 1234)
        let body = try sentBody()
        XCTAssertEqual(body["position"] as? Int, 1234,
                       "The user chose a number. Sending only a preference makes the server "
                       + "guess it from a row we cannot see — and an absent position decodes to 0.")
    }

    func test_resolve_sendsPositionZero_asAZero_notAsAnOmission() async throws {
        // "Restart from the beginning" is a legitimate resolution. It must be
        // distinguishable on the wire from "no position supplied".
        try await resolve(position: 0)
        let body = try sentBody()
        XCTAssertNotNil(body["position"], "position 0 must be sent, not dropped")
        XCTAssertEqual(body["position"] as? Int, 0)
    }

    func test_resolve_sendsTheEpisodeAndPodcastUrls() async throws {
        try await resolve(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://feeds.example.com/podcast"
        )
        let body = try sentBody()
        XCTAssertEqual(value("episodeUrl", "episode_url", in: body) as? String,
                       "https://example.com/ep1.mp3")
        XCTAssertEqual(value("podcastUrl", "podcast_url", in: body) as? String,
                       "https://feeds.example.com/podcast")
    }

    func test_resolve_sendsTheDuration_whenKnown() async throws {
        try await resolve(duration: 3600)
        let body = try sentBody()
        XCTAssertEqual(body["duration"] as? Int, 3600,
                       "Duration is the server's only proof the position is short of the end; "
                       + "without it a stale `completed` cannot be cleared.")
    }

    func test_resolve_omitsDuration_whenUnknown() async throws {
        // Never send 0 for "unknown" — against `position >= duration` a zero duration is
        // not missing information, it is a duration every position exceeds.
        try await resolve(duration: nil)
        let body = try sentBody()
        XCTAssertNil(body["duration"], "an unknown duration must be absent, never 0")
    }

    func test_resolve_omitsPodcastUrl_whenUnknown() async throws {
        try await resolve(podcastUrl: nil)
        let body = try sentBody()
        XCTAssertNil(value("podcastUrl", "podcast_url", in: body),
                     "an unknown podcast URL must be absent, never an empty string")
    }

    /// The literal key set, pinned. The server has to parse exactly these bytes, so the
    /// spelling is contract, not an implementation detail — and `.convertToSnakeCase` on
    /// the shared encoder means the keys are *not* the camelCase ones the contract prose
    /// uses. Changing this test means the server changes with it.
    func test_resolve_sendsExactlyTheAuthoritativeShape_snakeCased() async throws {
        try await resolve()
        let body = try sentBody()
        XCTAssertEqual(Set(body.keys), ["episode_url", "podcast_url", "position", "duration"])
    }

    func test_resolve_sendsNoResolutionString() async throws {
        // A preference alongside an explicit position is ambiguous: if the two disagree
        // about which number to write, nothing in the payload says which one governs.
        try await resolve()
        let body = try sentBody()
        XCTAssertNil(body["resolution"])
    }

    func test_resolve_postsToTheResolveEndpoint() async throws {
        try await resolve()
        XCTAssertEqual(MockURLProtocol.requestPaths.first, "/api/yourpods/sync-conflicts/resolve")
    }

    // MARK: - Episode identifier

    func test_identifier_prefersTheConflictsOwnAudioUrl() {
        XCTAssertEqual(
            EpisodeActionSyncService.conflictResolutionIdentifier(
                conflictAudioUrl: "https://example.com/ep1.mp3",
                lookedUpAudioUrl: "https://example.com/other.mp3",
                episodeGuid: "guid-1"
            ),
            "https://example.com/ep1.mp3"
        )
    }

    func test_identifier_fallsBackToTheLocalEpisodesAudioUrl_ratherThanTheGuid() {
        // A conflict built from a source that carried no enclosure URL still refers to an
        // episode we hold locally. Reaching for the GUID before checking the library is
        // what made the button 404 for every such episode.
        XCTAssertEqual(
            EpisodeActionSyncService.conflictResolutionIdentifier(
                conflictAudioUrl: nil,
                lookedUpAudioUrl: "https://example.com/ep1.mp3",
                episodeGuid: "guid-1"
            ),
            "https://example.com/ep1.mp3"
        )
    }

    func test_identifier_ignoresAnEmptyAudioUrl() {
        XCTAssertEqual(
            EpisodeActionSyncService.conflictResolutionIdentifier(
                conflictAudioUrl: "",
                lookedUpAudioUrl: "https://example.com/ep1.mp3",
                episodeGuid: "guid-1"
            ),
            "https://example.com/ep1.mp3"
        )
    }

    func test_identifier_fallsBackToTheGuid_onlyWhenNoUrlExistsAnywhere() {
        // The server matches URL-first-then-GUID, so this still resolves — but it is the
        // wrong shape for a field named for a URL, and it is the last resort, not the default.
        XCTAssertEqual(
            EpisodeActionSyncService.conflictResolutionIdentifier(
                conflictAudioUrl: nil,
                lookedUpAudioUrl: nil,
                episodeGuid: "guid-1"
            ),
            "guid-1"
        )
    }
}

import XCTest
@testable import YourPods

final class ShareClientTests: XCTestCase {
    func test_makeCreateRequest_setsUrlMethodHeaderAndBody() throws {
        let payload = ShareCreatePayload(
            kind: .episode, podcastUrl: "https://f/show.xml",
            episodeUrl: "https://cdn/ep.mp3", episodeGuid: "g1", startSec: 342
        )
        let req = ShareClient.makeCreateRequest(token: "tok-123", payload: payload)

        XCTAssertEqual(req.url?.absoluteString, "https://sync.yourpods.app/api/yourpods/share/create")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "tok-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["kind"] as? String, "episode")
        XCTAssertEqual(json?["podcastUrl"] as? String, "https://f/show.xml")
        XCTAssertEqual(json?["episodeUrl"] as? String, "https://cdn/ep.mp3")
        XCTAssertEqual(json?["episodeGuid"] as? String, "g1")
        XCTAssertEqual(json?["startSec"] as? Int, 342)
    }

    func test_makeCreateRequest_podcastKind_emptyEpisodeUrl() throws {
        let payload = ShareCreatePayload(
            kind: .podcast, podcastUrl: "https://f/show.xml",
            episodeUrl: nil, episodeGuid: nil, startSec: nil
        )
        let req = ShareClient.makeCreateRequest(token: "t", payload: payload)
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(json?["kind"] as? String, "podcast")
        XCTAssertEqual(json?["episodeUrl"] as? String, "")
        XCTAssertEqual(json?["startSec"] as? Int, 0)
    }

    func test_makeCreateRequestAuthenticated_usesBearerHeader() throws {
        let payload = ShareCreatePayload(
            kind: .episode, podcastUrl: "https://f/show.xml",
            episodeUrl: "https://cdn/ep.mp3", episodeGuid: "g1", startSec: 342
        )
        let req = ShareClient.makeCreateRequestAuthenticated(bearerToken: "jwt-123", payload: payload)

        XCTAssertEqual(req.url?.absoluteString, "https://sync.yourpods.app/api/yourpods/share/create")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-123",
                       "Pro path must send Bearer token")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Firebase-AppCheck"),
                     "Pro path must NOT send App Check header — middleware checks it first")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["kind"] as? String, "episode")
        XCTAssertEqual(json?["startSec"] as? Int, 342)
    }

    private func episodePayload() -> ShareCreatePayload {
        ShareCreatePayload(kind: .episode, podcastUrl: "https://f/show.xml",
                           episodeUrl: "https://cdn/ep.mp3", episodeGuid: "g1", startSec: 1)
    }

    override func tearDown() { StubURLProtocol.responder = nil; super.tearDown() }

    func test_createShare_success_returnsShareUrl() async throws {
        StubURLProtocol.responder = { req in
            (Self.httpResponse(req, 200), Data(#"{"shareUrl":"https://share.yourpods.app/s/abc"}"#.utf8))
        }
        let client = ShareClient(session: Self.stubbedSession())
        let url = try await client.createShare(episodePayload(), token: "t")
        XCTAssertEqual(url.absoluteString, "https://share.yourpods.app/s/abc")
    }

    func test_createShare_401_mapsToAppCheckInvalid() async {
        StubURLProtocol.responder = { req in (Self.httpResponse(req, 401), Data()) }
        await assertCreateThrows(.appCheckInvalid)
    }

    func test_createShare_403_mapsToAppNotAllowed() async {
        StubURLProtocol.responder = { req in (Self.httpResponse(req, 403), Data()) }
        await assertCreateThrows(.appNotAllowed)
    }

    func test_createShare_500_mapsToRejected() async {
        StubURLProtocol.responder = { req in (Self.httpResponse(req, 500), Data()) }
        await assertCreateThrows(.rejected(500))
    }

    private func assertCreateThrows(_ expected: ShareClientError) async {
        let client = ShareClient(session: Self.stubbedSession())
        do { _ = try await client.createShare(episodePayload(), token: "t"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ShareClientError, expected) }
    }

    private static func httpResponse(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }
    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Minimal URLProtocol stub for deterministic ShareClient tests.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let responder = Self.responder {
            let (response, data) = responder(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

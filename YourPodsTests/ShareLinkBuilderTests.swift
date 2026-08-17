import XCTest
@testable import YourPods

final class ShareLinkBuilderTests: XCTestCase {
    private func request() -> ShareRequest {
        ShareRequest(kind: .episode, podcastUrl: "https://f/show.xml",
                     episodeUrl: "https://cdn/ep.mp3", episodeGuid: "g1", startSec: nil,
                     episodeTitle: "Ep 1", podcastTitle: "Show", episodeLink: "https://site/ep1")
    }

    func test_richLink_whenTokenAndCreateSucceed() async {
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .success("tok")),
            client: FakeShareClient(result: .success(URL(string: "https://share.yourpods.app/s/abc")!)))
        let items = await builder.makeItems(for: request())
        XCTAssertTrue(items.contains { ($0 as? URL)?.host == "share.yourpods.app" })
    }

    func test_fallback_whenTokenUnavailable() async {
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .failure(AppCheckTokenError.unavailable)),
            client: FakeShareClient(result: .failure(ShareClientError.badResponse)))
        let items = await builder.makeItems(for: request())
        XCTAssertFalse(items.contains { ($0 as? URL)?.host == "share.yourpods.app" })
        XCTAssertTrue(items.contains { ($0 as? URL)?.absoluteString == "https://site/ep1" })
    }

    func test_retriesOnceOnAppCheckInvalid_thenFallback() async {
        let client = FakeShareClient(result: .failure(ShareClientError.appCheckInvalid))
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .success("tok")), client: client)
        let items = await builder.makeItems(for: request())
        XCTAssertEqual(client.createCallCount, 2)
        XCTAssertFalse(items.contains { ($0 as? URL)?.host == "share.yourpods.app" })
    }

    func test_doesNotRetryOnAppNotAllowed() async {
        let client = FakeShareClient(result: .failure(ShareClientError.appNotAllowed))
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .success("tok")), client: client)
        _ = await builder.makeItems(for: request())
        XCTAssertEqual(client.createCallCount, 1)
    }

    // MARK: - Pro-user auth path

    func test_proUser_usesAuthenticatedShare() async {
        let client = FakeShareClient(
            result: .success(URL(string: "https://share.yourpods.app/s/abc")!))
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .success("tok")),
            client: client,
            authProvider: FakeAuthProvider(token: "jwt-123"))
        let items = await builder.makeItems(for: request())
        XCTAssertTrue(items.contains { ($0 as? URL)?.host == "share.yourpods.app" })
        XCTAssertGreaterThan(client.authenticatedCallCount, 0, "Should use authenticated path")
        XCTAssertEqual(client.createCallCount, 0, "Should NOT use App Check path")
    }

    func test_proUser_fallsBackToAppCheckOnAuthFailure() async {
        let client = FakeShareClient(
            result: .success(URL(string: "https://share.yourpods.app/s/abc")!))
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .success("tok")),
            client: client,
            authProvider: FakeAuthProvider(token: nil))  // Auth fails
        let items = await builder.makeItems(for: request())
        XCTAssertTrue(items.contains { ($0 as? URL)?.host == "share.yourpods.app" })
        XCTAssertEqual(client.createCallCount, 1, "Should fall back to App Check path")
    }

    func test_nonProUser_usesAppCheckPath() async {
        let client = FakeShareClient(
            result: .success(URL(string: "https://share.yourpods.app/s/abc")!))
        let builder = ShareLinkBuilder(
            tokenProvider: FakeAppCheckTokenProvider(result: .success("tok")),
            client: client)  // No authProvider
        let items = await builder.makeItems(for: request())
        XCTAssertTrue(items.contains { ($0 as? URL)?.host == "share.yourpods.app" })
        XCTAssertEqual(client.createCallCount, 1)
        XCTAssertEqual(client.authenticatedCallCount, 0)
    }
}

final class FakeShareClient: ShareCreating, @unchecked Sendable {
    let result: Result<URL, Error>
    var authenticatedResult: Result<URL, Error>?
    private(set) var createCallCount = 0
    private(set) var authenticatedCallCount = 0
    init(result: Result<URL, Error>, authenticatedResult: Result<URL, Error>? = nil) {
        self.result = result
        self.authenticatedResult = authenticatedResult
    }
    func createShare(_ payload: ShareCreatePayload, token: String) async throws -> URL {
        createCallCount += 1
        return try result.get()
    }
    func createShareAuthenticated(_ payload: ShareCreatePayload, bearerToken: String) async throws -> URL {
        authenticatedCallCount += 1
        return try (authenticatedResult ?? result).get()
    }
}

/// Minimal AuthProvider fake for share tests.
struct FakeAuthProvider: AuthProvider, @unchecked Sendable {
    let token: String?
    func signIn(email: String, password: String) async throws -> String { "" }
    func createUser(email: String, password: String) async throws -> String { "" }
    func getValidToken() async throws -> String {
        guard let token else { throw AuthProviderError.notAuthenticated }
        return token
    }
    func signOut() async {}
    var isAuthenticated: Bool { token != nil }
    var currentUserEmail: String? { nil }
}

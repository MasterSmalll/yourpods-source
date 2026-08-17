/// Feed URL rewrite resolution — the iOS half.
///
/// When a feed moves, the server proposes `old → new` and the user taps Accept or Reject.
/// The iOS Accept path had three independent silent defects, and every one of them ends in
/// the same user-visible state: the library and the server permanently disagree about that
/// feed's URL, with no error and no way to retry.
///
/// 1. **Accept was transmitted as Reject.** The Go handler reads `Accept bool json:"accept"`
///    and only moves the subscription when it is true. `ProResolveUrlRewriteRequest` had no
///    such field, so it decoded to Go's zero value — `false`. The server dutifully deleted
///    the conflict and left the subscription on the old URL.
/// 2. **The body was snake_case** (`old_url`) against camelCase tags, so it never got that
///    far: `400 oldUrl required`, before any of the above ran.
/// 3. **The response decode made an informational count load-bearing.** `affected` was
///    non-optional while the handler returns `{"message": …}` only — so even a fully
///    successful resolve threw on decode and was logged as a failure.
///
/// On top of which the local rename was committed *before* the call and the prompt was
/// dropped on *send*, so there was nothing left to retry with even once a failure was
/// detectable. Web does the opposite and gets a working retry for free.
import XCTest
import SwiftData
@testable import YourPods

@MainActor
final class URLRewriteResolveTests: XCTestCase {

    // MARK: - Mock URLProtocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestBodies: [Data] = []
        nonisolated(unsafe) static var statusCode: Int = 200
        nonisolated(unsafe) static var responseBody: String = #"{"message":"url rewrite accepted"}"#

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
                url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
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
        MockURLProtocol.statusCode = 200
        MockURLProtocol.responseBody = #"{"message":"url rewrite accepted"}"#
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

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.requestBodies.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The request

    /// The defect that made Accept mean Reject. Go decodes an absent bool to `false`, so
    /// omitting this field is not "unspecified" — it is an explicit rejection.
    func test_acceptUrlRewrite_sendsAcceptTrue() async throws {
        _ = try await client.resolveUrlRewrite(
            oldUrl: "https://old.example.com/feed.xml",
            newUrl: "https://new.example.com/feed.xml",
            accept: true
        )
        let body = try sentBody()
        XCTAssertEqual(body["accept"] as? Bool, true,
                       "an absent `accept` decodes to false server-side — Accept becomes Reject")
    }

    /// Go's JSON decoder is case-insensitive but **not punctuation-insensitive**:
    /// `old_url` does not match `json:"oldUrl"`. The field decoded empty and the handler
    /// answered `400 oldUrl required` before doing anything at all.
    func test_acceptUrlRewrite_sendsCamelCaseKeys() async throws {
        _ = try await client.resolveUrlRewrite(
            oldUrl: "https://old.example.com/feed.xml",
            newUrl: "https://new.example.com/feed.xml",
            accept: true
        )
        let body = try sentBody()
        XCTAssertNotNil(body["oldUrl"], "handler tag is json:\"oldUrl\"")
        XCTAssertNotNil(body["newUrl"], "handler tag is json:\"newUrl\"")
        XCTAssertNil(body["old_url"], "snake_case never matched and 400'd every request")
        XCTAssertNil(body["new_url"])
    }

    /// Reject is a real call now — the server records it so the bridge stops re-raising
    /// that pair. Sending `accept: false` must be distinguishable from sending nothing.
    func test_rejectUrlRewrite_sendsAcceptFalse() async throws {
        _ = try await client.resolveUrlRewrite(
            oldUrl: "https://old.example.com/feed.xml",
            newUrl: "https://new.example.com/feed.xml",
            accept: false
        )
        let body = try sentBody()
        XCTAssertEqual(body["accept"] as? Bool, false)
    }

    // MARK: - The response

    /// The count is informational; the success signal is the HTTP status, which
    /// `performPOST` already throws on. Making a count field required meant a rename or an
    /// omission on the server turned every successful resolve into a reported failure —
    /// and this is live: the shipped handler returns `{"message": …}` with no count at all.
    func test_response_withoutACountField_isNotAFailure() async throws {
        MockURLProtocol.responseBody = #"{"message":"url rewrite accepted"}"#
        _ = try await client.resolveUrlRewrite(
            oldUrl: "https://old.example.com/feed.xml",
            newUrl: "https://new.example.com/feed.xml",
            accept: true
        )
        // Reaching here without throwing is the assertion.
    }

    /// The real shape from current server releases. `affected` never existed in any deployment — the handler
    /// has always returned `message` alone, and now returns `updated` plus a `counts`
    /// object. A required `affected` therefore threw on every successful resolve.
    func test_response_buildE281Shape_decodesAndReportsTheCount() async throws {
        MockURLProtocol.responseBody = #"""
        {"message":"url rewrite accepted","updated":3,"counts":{"subscriptions":1,"settings":1,"groups":1}}
        """#
        let response = try await client.resolveUrlRewrite(
            oldUrl: "https://old.example.com/feed.xml",
            newUrl: "https://new.example.com/feed.xml",
            accept: true
        )
        XCTAssertEqual(response.updated, 3)
    }

    /// A rewrite that matched nothing is a real outcome worth seeing, not an error.
    func test_response_zeroUpdated_isStillSuccess() async throws {
        MockURLProtocol.responseBody = #"{"message":"url rewrite accepted","updated":0,"counts":{}}"#
        let response = try await client.resolveUrlRewrite(
            oldUrl: "https://old.example.com/feed.xml",
            newUrl: "https://new.example.com/feed.xml",
            accept: true
        )
        XCTAssertEqual(response.updated, 0)
    }

    func test_serverFailure_throws_soTheCallerCanRetry() async {
        MockURLProtocol.statusCode = 500
        MockURLProtocol.responseBody = #"{"error":"rewrite failed"}"#
        do {
            _ = try await client.resolveUrlRewrite(
                oldUrl: "https://old.example.com/feed.xml",
                newUrl: "https://new.example.com/feed.xml",
                accept: true
            )
            XCTFail("a 500 must surface — it is the only thing that makes the prompt retryable")
        } catch {
            // expected
        }
    }
}

// MARK: - Local commit ordering

/// The rename must not be committed locally until the server has confirmed it. Committing
/// first and firing a fire-and-forget `Task` that only logs the failure is what leaves the
/// library and the server permanently disagreeing with no retry. Holding the prompt open
/// until the server confirms is what makes a retry possible at all.
@MainActor
final class URLRewriteLocalCommitTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!

    private let oldUrl = "https://old.example.com/feed.xml"
    private let newUrl = "https://new.example.com/feed.xml"

    private let testProfileId = "test-url-rewrite"

    override func setUp() {
        super.setUp()
        // `loadSubscriptions` filters by the active profile's URL set, so a leftover
        // profile id from another class silently filters this podcast out and every
        // "should rename" assertion fails for a reason that has nothing to do with the
        // rewrite. A fresh id takes the adoption path.
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)

        let podcast = Podcast(url: oldUrl, title: "Moved Show")
        context.insert(podcast)
        try? context.save()
        podcastManager.loadSubscriptions()

        XCTAssertTrue(
            podcastManager.subscriptions.contains { $0.url == oldUrl },
            "arrange failed — the rest of this class asserts nothing if the podcast isn't subscribed"
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        podcastManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func rewrite() -> URLRewriteConflict {
        URLRewriteConflict(oldUrl: oldUrl, newUrl: newUrl, podcastTitle: "Moved Show", artworkUrl: nil)
    }

    private func currentUrls() -> [String] {
        (try? context.fetch(FetchDescriptor<Podcast>()))?.map(\.url) ?? []
    }

    func test_acceptUrlRewrite_renamesLocally_whenTheServerConfirms() async {
        let client = RewriteStubClient(shouldThrow: false)
        podcastManager.setSyncClient(client, deviceId: "test-device")

        let ok = await podcastManager.acceptUrlRewrite(rewrite())

        XCTAssertTrue(ok)
        XCTAssertTrue(currentUrls().contains(newUrl))
        XCTAssertFalse(currentUrls().contains(oldUrl))
    }

    /// The load-bearing one. A failed resolve must leave the library untouched, so the
    /// prompt the caller keeps is still true and retrying it is meaningful.
    func test_acceptUrlRewrite_leavesTheLibraryUntouched_whenTheServerFails() async {
        let client = RewriteStubClient(shouldThrow: true)
        podcastManager.setSyncClient(client, deviceId: "test-device")

        let ok = await podcastManager.acceptUrlRewrite(rewrite())

        XCTAssertFalse(ok, "a failed resolve must report failure so the prompt survives")
        XCTAssertTrue(currentUrls().contains(oldUrl),
                      "renaming before confirmation is what strands the library out of sync")
        XCTAssertFalse(currentUrls().contains(newUrl))
    }

    /// Vault / gPodder have no rewrite endpoint. The rename is purely local there and must
    /// still happen — otherwise Accept does nothing for non-Pro users.
    func test_acceptUrlRewrite_renamesLocally_whenThereIsNoProClient() async {
        podcastManager.setSyncClient(nil, deviceId: "test-device")

        let ok = await podcastManager.acceptUrlRewrite(rewrite())

        XCTAssertTrue(ok)
        XCTAssertTrue(currentUrls().contains(newUrl))
    }
}

/// Minimal stub — only the rewrite call matters here.
private actor RewriteStubClient: SyncClient {
    private let shouldThrow: Bool
    init(shouldThrow: Bool) { self.shouldThrow = shouldThrow }

    func resolveUrlRewrite(oldUrl: String, newUrl: String, accept: Bool) async throws -> ProResolveUrlRewriteResponse {
        if shouldThrow { throw YourPodsProError.serverError(500) }
        return ProResolveUrlRewriteResponse(message: "url rewrite accepted", updated: 3)
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: items, droppedItems: [])
    }
    var supportsSettingsSync: Bool { false }
}

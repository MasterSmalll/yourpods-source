import XCTest
import SwiftData
@testable import YourPods

/// The delta cursor acknowledges a window of changes, so it must not move until those
/// changes have been applied — per the sync contract.
///
/// It used to be written the moment it arrived, in the same statement that read it off the
/// response. That marks a window consumed before anything has consumed it, and the server
/// does not resend a window the client has acknowledged. Two ways it loses changes:
///
/// 1. **Routine, on every episode change.** Only `ProSyncOrchestrator` applies the hidden /
///    completed / uncompleted side-channels. `PlayerManager.syncPlaybackState` pulls with
///    `force: false` on every track change and applies none of them — so each track change
///    fetched a window of state changes, advanced past it, and dropped it on the floor.
/// 2. **On cancellation or crash.** The orchestrator's own comment promises the in-memory
///    mutations are "re-applied on the next sync if this one is cancelled". That promise
///    only holds while the cursor has not already moved past them, and it had.
///
/// Discarding an uncommitted cursor is always safe — the window is re-delivered and every
/// apply is idempotent. Committing one that was never applied is not.
@MainActor
final class DeltaCursorCommitTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: EpisodeActionSyncService!

    private let profileId = "test-delta-cursor"
    private var cursorKey: String { "lastEpisodeActionSyncToken_\(profileId)" }

    // MARK: - Wire stub

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var body = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
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

    override func setUp() {
        super.setUp()
        clearDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(profileId, forKey: "activeProfileId")

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: StubAuthProvider(),
            session: URLSession(configuration: sessionConfig)
        )
        service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { client },
            profileIdProvider: { self.profileId },
            deviceIdProvider: { "yourpods-iPhone-cursor" }
        )
    }

    override func tearDown() {
        clearDefaults()
        service = nil
        context = nil
        container = nil
        MockURLProtocol.body = Data()
        super.tearDown()
    }

    private func clearDefaults() {
        for key in ["activeProfileId", cursorKey, "episodeActionMap",
                    "lastEpisodeActionSync_\(profileId)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The literal shape `GET /api/yourpods/playback/recent` returns: `states` (not
    /// `actions`), an ISO8601 `timestamp` that becomes the cursor, and the side-channels
    /// derived from each row's `completed` / `hidden` fields rather than sent separately.
    /// An invented payload here would test the stub, not the client.
    private func stubWindow(token: String) {
        MockURLProtocol.body = Data("""
        {
          "states": [
            {
              "podcastUrl": "https://feeds.example.com/show.xml",
              "episodeUrl": "https://cdn.example.com/ep1.mp3",
              "episodeGuid": "ep-completed-elsewhere",
              "positionSec": 2280,
              "durationSec": 2280,
              "updatedAt": "2026-08-02T00:59:00Z",
              "completed": true
            }
          ],
          "timestamp": "\(token)"
        }
        """.utf8)
    }

    private var storedCursor: String? {
        UserDefaults.standard.string(forKey: cursorKey)
    }

    // MARK: - The defect

    /// A pull alone must not acknowledge anything.
    func test_pull_doesNotAdvanceTheCursorOnItsOwn() async throws {
        stubWindow(token: "2026-08-02T01:00:00Z")

        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)

        XCTAssertNil(
            storedCursor,
            "the cursor moved the moment the window arrived — the server will not resend it, "
            + "so anything that fails to apply between here and the commit is lost for good"
        )
        XCTAssertTrue(service.hasPendingCursorToken,
                      "the token still has to be held, or the window can never be acknowledged")
    }

    /// And the changes are still there to be applied — holding the cursor must not hold
    /// the payload hostage.
    func test_pull_stillDeliversTheChangesToApply() async throws {
        stubWindow(token: "2026-08-02T01:00:00Z")

        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)

        XCTAssertEqual(service.lastFetchedCompletedChanges.map(\.guid), ["ep-completed-elsewhere"])
    }

    func test_commit_advancesTheCursor() async throws {
        stubWindow(token: "2026-08-02T01:00:00Z")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)

        service.commitCursorToken()

        XCTAssertEqual(storedCursor, "2026-08-02T01:00:00Z")
        XCTAssertFalse(service.hasPendingCursorToken, "a committed token must not commit twice")
    }

    /// The cancellation case, stated directly: a sync that pulls and then stops before
    /// applying leaves the cursor where it was, so the next sync sees the same window.
    func test_pullWithoutCommit_leavesTheWindowToBeRedelivered() async throws {
        stubWindow(token: "2026-08-02T01:00:00Z")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)
        // …cancelled here: no commit.

        stubWindow(token: "2026-08-02T02:00:00Z")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)
        service.commitCursorToken()

        XCTAssertEqual(storedCursor, "2026-08-02T02:00:00Z",
                       "the second window's token is the one that gets acknowledged")
    }

    /// Committing without a pull is a no-op rather than a crash or a stale write — the
    /// orchestrator calls it unconditionally at the end of its apply block.
    func test_commitWithNothingPending_isANoOp() {
        service.commitCursorToken()

        XCTAssertNil(storedCursor)
    }

    /// A second commit must not resurrect an already-acknowledged token over a newer one.
    func test_doubleCommit_doesNotRewriteAnOlderToken() async throws {
        stubWindow(token: "2026-08-02T01:00:00Z")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)
        service.commitCursorToken()

        stubWindow(token: "2026-08-02T02:00:00Z")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)
        service.commitCursorToken()
        service.commitCursorToken()

        XCTAssertEqual(storedCursor, "2026-08-02T02:00:00Z")
    }
}

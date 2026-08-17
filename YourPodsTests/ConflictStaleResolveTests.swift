import XCTest
import SwiftData
@testable import YourPods

/// `409 {"code":"conflict_stale"}` from `POST /sync-conflicts/resolve{,-all}` means
/// **refresh the list**, not *retry* — per the sync contract and the corresponding
/// server change.
///
/// The server now revalidates a conflict row against live `playback_states` before
/// resolving it, and refuses when the row no longer describes current state. Refusing is
/// the correct answer: the previous behaviour wrote the row's frozen snapshot over live
/// state authoritatively, which is how a conflict "resolved" to a position nobody was at.
///
/// Two things have to be true on this side of the wire:
///
/// 1. **It is not the queue's 409.** `/queue/sync` returns 409 for a stale `baseVersion`,
///    and the caller re-pulls, re-merges and retries. Retrying a stale *conflict* re-sends
///    the same dead row and gets the same 409 forever. One status code, two meanings —
///    distinguished by the body's `code`, which is why the server sends one.
/// 2. **It is not a silent no-op.** The row the user answered is gone server-side and can
///    never resolve; leaving it on screen offers a button that cannot work. Dropping it
///    without re-reading leaves the sheet showing a list the server has already changed.
@MainActor
final class ConflictStaleResolveTests: XCTestCase {

    // MARK: - Per-path mock

    /// Routes by path so one test can answer the upload and the resolve differently —
    /// `resolveConflict` reports through `uploadEpisodeActions` first and only then makes
    /// the authoritative write, and the two must not share a canned response.
    private final class PathMockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
        nonisolated(unsafe) static var requestedPaths: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.requestedPaths.append(path)
            let (status, body) = Self.responses[path] ?? (200, Data("{}".utf8))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
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

    private var client: YourPodsProClient!
    private var container: ModelContainer!
    private var context: ModelContext!

    private let resolvePath = "/api/yourpods/sync-conflicts/resolve"
    private let resolveAllPath = "/api/yourpods/sync-conflicts/resolve-all"
    private let uploadPath = "/api/yourpods/episode-actions"

    private static let staleBody = Data(
        #"{"error":"conflict is no longer current — refresh GET /sync-conflicts","code":"conflict_stale"}"#.utf8
    )

    override func setUp() {
        super.setUp()
        PathMockURLProtocol.responses = [:]
        PathMockURLProtocol.requestedPaths = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PathMockURLProtocol.self]
        client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: StubAuthProvider(),
            session: URLSession(configuration: config)
        )
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: modelConfig)
        context = container.mainContext
    }

    override func tearDown() {
        PathMockURLProtocol.responses = [:]
        PathMockURLProtocol.requestedPaths = []
        client = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - The wire

    func test_resolve_409WithConflictStaleCode_isDistinguishable() async {
        PathMockURLProtocol.responses[resolvePath] = (409, Self.staleBody)

        do {
            try await client.resolveConflict(
                episodeUrl: "https://cdn.example.com/ep1.mp3",
                podcastUrl: nil, position: 828, duration: 3600
            )
            XCTFail("a refused resolution must throw, not report success")
        } catch {
            XCTAssertEqual(error as? YourPodsProError, .conflictStale,
                           "a stale conflict is not the queue's retryable 409 — retrying re-sends the same dead row forever")
        }
    }

    /// The queue's 409 must keep meaning what it meant. `/queue/sync` answers 409 for a
    /// stale `baseVersion` and the caller re-pulls and retries; folding it into the stale
    /// case would turn a recoverable queue push into a refresh that never retries.
    func test_resolve_409WithoutTheCode_staysTheRetryableConflict() async {
        PathMockURLProtocol.responses[resolvePath] = (409, Data(#"{"error":"version conflict"}"#.utf8))

        do {
            try await client.resolveConflict(
                episodeUrl: "https://cdn.example.com/ep1.mp3",
                podcastUrl: nil, position: 828, duration: 3600
            )
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? YourPodsProError, .conflict)
        }
    }

    /// A 409 with no body at all — nothing to read a code out of — must not be guessed
    /// into the stale case.
    func test_resolve_409WithAnEmptyBody_staysTheRetryableConflict() async {
        PathMockURLProtocol.responses[resolvePath] = (409, Data())

        do {
            try await client.resolveConflict(
                episodeUrl: "https://cdn.example.com/ep1.mp3",
                podcastUrl: nil, position: 828, duration: 3600
            )
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? YourPodsProError, .conflict)
        }
    }

    func test_resolveAll_409WithConflictStaleCode_isDistinguishable() async {
        PathMockURLProtocol.responses[resolveAllPath] = (409, Self.staleBody)

        do {
            try await client.resolveAllConflicts(resolution: "device")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? YourPodsProError, .conflictStale)
        }
    }

    // MARK: - What the service reports

    private func makeService() -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { self.client },
            profileIdProvider: { "test-profile-stale" },
            deviceIdProvider: { "yourpods-iPhone-stale" }
        )
    }

    private func conflict() -> SyncConflict {
        SyncConflict(
            episodeGuid: "guid-stale-1",
            episodeTitle: "Episode One",
            podcastTitle: "Test Show",
            podcastUrl: "https://feeds.example.com/show.xml",
            artworkUrl: nil,
            audioUrl: "https://cdn.example.com/ep1.mp3",
            localPosition: 828,
            serverPosition: 2167,
            serverTimestamp: 0,
            totalDuration: 3600,
            occurrenceCount: 1
        )
    }

    func test_resolveConflict_staleRow_reportsStale() async {
        PathMockURLProtocol.responses[resolvePath] = (409, Self.staleBody)

        let outcome = await makeService().resolveConflict(conflict(), chosenPosition: 828)

        XCTAssertEqual(outcome, .stale,
                       "the caller has to tell 'this row is gone, re-read the list' from 'that failed, try again'")
    }

    func test_resolveConflict_success_reportsLanded() async {
        let outcome = await makeService().resolveConflict(conflict(), chosenPosition: 828)

        XCTAssertEqual(outcome, .landed)
    }

    /// Anything else is a failure the user can retry — a 500, a dropped connection, an
    /// expired token. Reporting these as `.stale` would refresh the list and quietly
    /// discard a resolution that was never refused.
    func test_resolveConflict_serverError_reportsFailed_notStale() async {
        PathMockURLProtocol.responses[resolvePath] = (500, Data(#"{"error":"boom"}"#.utf8))

        let outcome = await makeService().resolveConflict(conflict(), chosenPosition: 828)

        XCTAssertEqual(outcome, .failed)
    }

    /// The local write is the user's statement about their own device and survives a
    /// server refusal. Making the write conditional on the server would also break
    /// resolving offline, which works today.
    func test_resolveConflict_staleRow_stillRecordsTheChoiceLocally() async {
        PathMockURLProtocol.responses[resolvePath] = (409, Self.staleBody)
        let service = makeService()

        _ = await service.resolveConflict(conflict(), chosenPosition: 828)

        XCTAssertEqual(service.getLatestAction(for: "guid-stale-1")?.position, 828,
                       "a refused server write discarded the user's own device position too")
    }

    /// The authoritative write is the one that decides, and it must still be
    /// attempted after the report — a `.landed` that never called it would be a lie.
    func test_resolveConflict_makesTheAuthoritativeWrite() async {
        _ = await makeService().resolveConflict(conflict(), chosenPosition: 828)

        XCTAssertTrue(PathMockURLProtocol.requestedPaths.contains(resolvePath),
                      "requested: \(PathMockURLProtocol.requestedPaths)")
    }
}

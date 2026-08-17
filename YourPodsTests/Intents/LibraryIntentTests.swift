import XCTest
import AppIntents
@testable import YourPods

@MainActor
final class LibraryIntentTests: XCTestCase {

    private var received: [SiriIntentCommand] = []

    override func setUp() {
        super.setUp()
        received = []
        SiriIntentBridge.shared.handler = { [weak self] command in
            self?.received.append(command)
            return .success(dialog: "stub")
        }
    }

    override func tearDown() {
        SiriIntentBridge.shared.handler = nil
        super.tearDown()
    }

    func test_libraryIntents_sendExpectedCommands() async throws {
        let pod = PodcastEntity(snapshot: PodcastSnapshot(
            feedUrl: "https://feed/atp", title: "ATP", author: nil, artworkUrl: nil))
        let downloadLatest = DownloadLatestIntent()
        downloadLatest.podcast = pod

        let cases: [(String, () async throws -> Void, SiriIntentCommand)] = [
            ("CheckNew",   { _ = try await CheckForNewEpisodesIntent().perform() }, .checkForNewEpisodes),
            ("DlQueue",    { _ = try await DownloadQueueIntent().perform() },       .downloadQueue),
            ("DlLatest",   { _ = try await downloadLatest.perform() },              .downloadLatest(feedUrl: "https://feed/atp")),
            ("MarkPlayed", { _ = try await MarkPlayedAndPlayNextIntent().perform() }, .markPlayedAndPlayNext),
        ]
        for c in cases {
            received = []
            try await c.1()
            XCTAssertEqual(received, [c.2], c.0)
        }
    }

    // ClearQueueIntent uses requestConfirmation(), which can't be driven headlessly
    // in unit tests — verify its configuration instead; behavior is covered by the
    // handler test plus simulator verification.
    func test_clearQueue_configuration() {
        XCTAssertFalse(ClearQueueIntent.openAppWhenRun)
    }
}

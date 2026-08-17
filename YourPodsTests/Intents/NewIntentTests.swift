import XCTest
import AppIntents
@testable import YourPods

@MainActor
final class NewIntentTests: XCTestCase {

    private var received: [SiriIntentCommand] = []

    override func setUp() {
        super.setUp()
        received = []
    }

    override func tearDown() {
        SiriIntentBridge.shared.handler = nil
        super.tearDown()
    }

    private func stub(_ outcome: IntentOutcome) {
        SiriIntentBridge.shared.handler = { [weak self] command in
            self?.received.append(command)
            return outcome
        }
    }

    private let episodeSnap = EpisodeSnapshot(
        guid: "g1", podcastUrl: "f", title: "Ep", podcastTitle: "P",
        audioUrl: "a", artworkUrl: nil, durationSeconds: 100, positionSeconds: 10,
        isPlayed: false, pubDate: nil)

    func test_verbIntents_sendExpectedCommands() async throws {
        stub(.success(dialog: "ok"))
        let cases: [(String, () async throws -> Void, SiriIntentCommand)] = [
            ("Restart",  { _ = try await RestartEpisodeIntent().perform() },  .restartEpisode),
            ("NextCh",   { _ = try await NextChapterIntent().perform() },     .nextChapter),
            ("PrevCh",   { _ = try await PreviousChapterIntent().perform() }, .previousChapter),
        ]
        for c in cases {
            received = []
            try await c.1()
            XCTAssertEqual(received, [c.2], c.0)
        }
    }

    func test_extendSleepTimer_passesMinutes() async throws {
        stub(.success(dialog: "ok"))
        let intent = ExtendSleepTimerIntent()
        intent.minutes = 15
        _ = try await intent.perform()
        XCTAssertEqual(received, [.extendSleepTimer(minutes: 15)])
    }

    func test_getCurrentEpisode_returnsEntityValue() async throws {
        stub(.episode(episodeSnap, dialog: "Now playing Ep from P."))
        let result = try await GetCurrentEpisodeIntent().perform()
        XCTAssertEqual(result.value?.id, "f|g1")
    }

    func test_getCurrentEpisode_throwsHonestError_whenNothingPlaying() async {
        stub(.failure(message: "Nothing is playing right now."))
        do {
            _ = try await GetCurrentEpisodeIntent().perform()
            XCTFail("expected throw")
        } catch {
            // Getter intents THROW on failure (no value to return); the error's
            // description carries the honest message for Shortcuts to display.
            XCTAssertTrue(String(describing: error).contains("Nothing is playing"))
        }
    }

    func test_getQueue_returnsEntityList() async throws {
        stub(.episodes([episodeSnap], dialog: "You have 1 episode in your queue."))
        let result = try await GetQueueIntent().perform()
        XCTAssertEqual(result.value?.count, 1)
        XCTAssertEqual(result.value?[0].id, "f|g1")
    }

    func test_getPodcasts_returnsEntityList() async throws {
        stub(.podcasts([PodcastSnapshot(feedUrl: "f", title: "T", author: nil, artworkUrl: nil)],
                       dialog: "You follow 1 podcasts."))
        let result = try await GetPodcastsIntent().perform()
        XCTAssertEqual(result.value?.count, 1)
        XCTAssertEqual(result.value?[0].id, "f")
    }

    func test_whatsNext_sendsCommand() async throws {
        stub(.episode(episodeSnap, dialog: "Up next is Ep from P."))
        _ = try await WhatsNextIntent().perform()
        XCTAssertEqual(received, [.whatsNext])
    }
}

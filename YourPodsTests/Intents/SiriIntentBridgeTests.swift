import XCTest
@testable import YourPods

@MainActor
final class SiriIntentBridgeTests: XCTestCase {

    override func tearDown() {
        SiriIntentBridge.shared.handler = nil
        super.tearDown()
    }

    // MARK: - Unwired bridge

    func test_returnsFailure_whenNoHandlerWired() async {
        SiriIntentBridge.shared.handler = nil
        let outcome = await SiriIntentBridge.shared.perform(.pause)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog, "YourPods isn't ready yet. Try again in a moment.")
    }

    // MARK: - Routing

    func test_forwardsCommandToHandler_andReturnsItsOutcome() async {
        var received: [SiriIntentCommand] = []
        SiriIntentBridge.shared.handler = { command in
            received.append(command)
            return .success(dialog: "ok")
        }
        let outcome = await SiriIntentBridge.shared.perform(.setSleepTimer(minutes: 30))
        XCTAssertEqual(received, [.setSleepTimer(minutes: 30)])
        XCTAssertEqual(outcome.spokenDialog, "ok")
        XCTAssertFalse(outcome.isFailure)
    }

    // MARK: - Privacy

    func test_caseName_omitsAssociatedValues() {
        XCTAssertEqual(SiriIntentCommand.bookmarkCurrentMoment(note: "secret text").caseName,
                       "bookmarkCurrentMoment")
        XCTAssertEqual(SiriIntentCommand.pause.caseName, "pause")
    }

    // MARK: - Snapshot mapping

    func test_episodeSnapshot_mapsQueueItemFields() {
        let item = QueueItem(
            id: "guid-1", title: "Ep Title", podcastTitle: "Pod",
            audioUrl: "https://a/1.mp3", artworkUrl: "https://a/art.jpg",
            durationSeconds: 3600, positionSeconds: 90,
            podcastUrl: "https://feed", pubDate: Date(timeIntervalSince1970: 1000))
        let snap = EpisodeSnapshot(item: item)
        XCTAssertEqual(snap.guid, "guid-1")
        XCTAssertEqual(snap.podcastUrl, "https://feed")
        XCTAssertEqual(snap.title, "Ep Title")
        XCTAssertEqual(snap.durationSeconds, 3600)
        XCTAssertEqual(snap.positionSeconds, 90)
    }
}

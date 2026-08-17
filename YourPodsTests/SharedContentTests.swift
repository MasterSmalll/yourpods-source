import XCTest
@testable import YourPods

final class SharedContentTests: XCTestCase {
    func test_toQueueItem_mapsFields() {
        let shared = SharedEpisode(
            guid: "g1", title: "Ep 1", podcastTitle: "Show", podcastAuthor: "Host",
            audioUrl: "https://cdn/ep.mp3", feedUrl: "https://f/show.xml",
            artworkUrl: "https://img/a.jpg", durationSeconds: 1800,
            episodeDescription: "desc", startSec: 342, pubDate: nil)
        let item = shared.toQueueItem()
        XCTAssertEqual(item.id, "g1")
        XCTAssertEqual(item.title, "Ep 1")
        XCTAssertEqual(item.audioUrl, "https://cdn/ep.mp3")
        XCTAssertEqual(item.podcastUrl, "https://f/show.xml")
        XCTAssertEqual(item.podcastAuthor, "Host")
        XCTAssertEqual(item.durationSeconds, 1800)
    }
}

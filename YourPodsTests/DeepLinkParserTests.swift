import XCTest
@testable import YourPods

final class DeepLinkParserTests: XCTestCase {
    func test_episode_withTimestamp() {
        let url = URL(string: "yourpods://episode?feed=https%3A%2F%2Ff%2Fshow.xml&guid=g1&url=https%3A%2F%2Fcdn%2Fep.mp3&t=342")!
        XCTAssertEqual(DeepLinkParser.parse(url),
            .episode(feed: "https://f/show.xml", guid: "g1", audioUrl: "https://cdn/ep.mp3", startSec: 342))
    }

    func test_episode_withoutTimestamp() {
        let url = URL(string: "yourpods://episode?feed=https%3A%2F%2Ff%2Fshow.xml&guid=g1&url=https%3A%2F%2Fcdn%2Fep.mp3")!
        XCTAssertEqual(DeepLinkParser.parse(url),
            .episode(feed: "https://f/show.xml", guid: "g1", audioUrl: "https://cdn/ep.mp3", startSec: nil))
    }

    func test_podcast() {
        let url = URL(string: "yourpods://podcast?feed=https%3A%2F%2Ff%2Fshow.xml")!
        XCTAssertEqual(DeepLinkParser.parse(url), .podcast(feed: "https://f/show.xml"))
    }

    func test_actionHost_isIgnored() {
        XCTAssertNil(DeepLinkParser.parse(URL(string: "yourpods://action/togglePlay")!))
    }

    func test_episode_missingFeed_isNil() {
        XCTAssertNil(DeepLinkParser.parse(URL(string: "yourpods://episode?guid=g1&url=u")!))
    }
}

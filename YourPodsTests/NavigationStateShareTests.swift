import XCTest
@testable import YourPods

@MainActor
final class NavigationStateShareTests: XCTestCase {
    func test_applyOutcome_previewEpisode_setsPendingEpisode() {
        let nav = NavigationState()
        let shared = SharedEpisode(guid: "g1", title: "Ep", podcastTitle: "Show", podcastAuthor: nil,
            audioUrl: "u", feedUrl: "f", artworkUrl: nil, durationSeconds: nil,
            episodeDescription: nil, startSec: nil, pubDate: nil)
        nav.apply(.previewEpisode(shared))
        XCTAssertEqual(nav.pendingSharedEpisode?.guid, "g1")
    }

    func test_applyOutcome_previewPodcast_setsPendingPodcast() {
        let nav = NavigationState()
        nav.apply(.previewPodcast(SharedPodcast(feedUrl: "f", title: "Show", author: nil, artworkUrl: nil, podcastDescription: nil)))
        XCTAssertEqual(nav.pendingSharedPodcast?.title, "Show")
    }

    func test_applyOutcome_failed_setsNothing() {
        let nav = NavigationState()
        nav.apply(.failed)
        XCTAssertNil(nav.pendingSharedEpisode); XCTAssertNil(nav.pendingSharedPodcast)
        XCTAssertTrue(nav.deepLinkFailed)
    }
}

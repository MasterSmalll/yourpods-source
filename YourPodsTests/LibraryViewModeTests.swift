import XCTest
@testable import YourPods

final class LibraryViewModeTests: XCTestCase {

    // Raw values are the persistence contract — changing them silently drops user prefs.
    func test_libraryLens_rawValues() {
        XCTAssertEqual(LibraryLens.podcasts.rawValue, "podcasts")
        XCTAssertEqual(LibraryLens.episodes.rawValue, "episodes")
    }

    func test_episodeArrangement_rawValuesAndDisplayNames() {
        XCTAssertEqual(EpisodeArrangement.newest.rawValue, "newest")
        XCTAssertEqual(EpisodeArrangement.byDate.rawValue, "byDate")
        XCTAssertEqual(EpisodeArrangement.byShow.rawValue, "byShow")
        XCTAssertEqual(EpisodeArrangement.newest.displayName, "Newest First")
        XCTAssertEqual(EpisodeArrangement.byDate.displayName, "By Date")
        XCTAssertEqual(EpisodeArrangement.byShow.displayName, "By Show")
    }

    // Each swipe action maps onto exactly the intended EpisodeMenuAction.
    func test_episodeSwipeAction_mapsToMenuAction() {
        let cases: [(EpisodeSwipeAction, EpisodeMenuAction)] = [
            (.addToQueue, .addToQueue),
            (.playNext, .playNext),
            (.markPlayed, .markPlayed),
            (.hide, .hide),
            (.playNow, .play),
        ]
        for (swipe, expected) in cases {
            XCTAssertEqual(swipe.menuAction, expected, "\(swipe) should map to \(expected)")
        }
    }

    func test_episodeSwipeAction_hasNonEmptyLabels() {
        for action in EpisodeSwipeAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty, "\(action) needs a display name")
            XCTAssertFalse(action.systemImage.isEmpty, "\(action) needs an SF Symbol")
        }
        XCTAssertEqual(EpisodeSwipeAction.allCases.count, 5)
    }
}

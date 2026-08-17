import XCTest
@testable import YourPods

final class LibraryViewPreferencesTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let keys = ["libraryLens", "libraryEpisodeArrangement",
                        "episodeSwipeLeading", "episodeSwipeTrailing"]

    override func setUp() {
        super.setUp()
        keys.forEach { defaults.removeObject(forKey: $0) }
    }
    override func tearDown() {
        keys.forEach { defaults.removeObject(forKey: $0) }
        super.tearDown()
    }

    func test_defaults() {
        let s = SettingsManager()
        XCTAssertEqual(s.libraryLens, .podcasts, "Library must default to the podcast lens")
        XCTAssertEqual(s.libraryEpisodeArrangement, .newest)
        XCTAssertEqual(s.episodeSwipeLeading, .playNext)
        XCTAssertEqual(s.episodeSwipeTrailing, .addToQueue)
    }

    func test_persistsRoundTrip() {
        let s = SettingsManager()
        s.libraryLens = .episodes
        s.libraryEpisodeArrangement = .byShow
        s.episodeSwipeLeading = .markPlayed
        s.episodeSwipeTrailing = .playNow

        let reloaded = SettingsManager()
        XCTAssertEqual(reloaded.libraryLens, .episodes)
        XCTAssertEqual(reloaded.libraryEpisodeArrangement, .byShow)
        XCTAssertEqual(reloaded.episodeSwipeLeading, .markPlayed)
        XCTAssertEqual(reloaded.episodeSwipeTrailing, .playNow)
    }

    // Unknown/garbage persisted value falls back to the default, never crashes.
    func test_unknownRawValueFallsBackToDefault() {
        defaults.set("garbage", forKey: "libraryLens")
        XCTAssertEqual(SettingsManager().libraryLens, .podcasts)
    }
}

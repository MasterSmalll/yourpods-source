import XCTest
@testable import YourPods

/// Tests for the HomeView "Recently Updated" section's episode filtering logic.
/// The limit is now configurable via SettingsManager.recentlyUpdatedLimit (default: 27).
final class HomeViewLayoutTests: XCTestCase {

    // MARK: - Helper: mirrors HomeView.recentEpisodes logic

    /// Pure-logic filter using RecentlyUpdatedFilter directly.
    private func recentEpisodes(
        from episodes: [Episode],
        limit: Int = 27
    ) -> [Episode] {
        RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: limit
        ).episodes
    }

    /// Convenience: create a test Episode with minimal fields.
    private func makeEpisode(
        guid: String,
        title: String = "Episode",
        podcastUrl: String = "feed-a",
        pubDate: Date? = nil,
        isPlayed: Bool = false,
        isInteracted: Bool = false
    ) -> Episode {
        let ep = Episode(guid: guid, title: title, pubDate: pubDate)
        ep.isPlayed = isPlayed
        ep.isInteracted = isInteracted
        let podcast = Podcast(url: podcastUrl, title: "Pod")
        ep.podcast = podcast
        return ep
    }

    // MARK: - Limit

    func test_recentlyUpdatedLimit_defaultIs27() {
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "HomeViewLayoutTest")!)
        XCTAssertEqual(settings.recentlyUpdatedLimit, 27,
                       "Default recently updated limit should be 27")
    }

    func test_recentEpisodes_capsAtLimit() {
        let now = Date()
        let episodes = (0..<35).map { i in
            makeEpisode(
                guid: "ep-\(i)",
                pubDate: Calendar.current.date(byAdding: .day, value: -i, to: now)
            )
        }
        let result = recentEpisodes(from: episodes, limit: 27)
        XCTAssertEqual(result.count, 27, "Should cap at the configured limit")
    }

    func test_recentEpisodes_returnsAllWhenBelowLimit() {
        let now = Date()
        let episodes = (0..<5).map { i in
            makeEpisode(
                guid: "ep-\(i)",
                pubDate: Calendar.current.date(byAdding: .day, value: -i, to: now)
            )
        }
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 5, "Should return all episodes when below limit")
    }

    func test_recentEpisodes_sortedNewestFirst() {
        let now = Date()
        let episodes = [
            makeEpisode(guid: "old", pubDate: Calendar.current.date(byAdding: .day, value: -3, to: now)),
            makeEpisode(guid: "recent", podcastUrl: "feed-b", pubDate: Calendar.current.date(byAdding: .day, value: -1, to: now)),
            makeEpisode(guid: "mid", podcastUrl: "feed-c", pubDate: Calendar.current.date(byAdding: .day, value: -2, to: now)),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.map(\.guid), ["recent", "mid", "old"], "Should be newest first")
    }

    func test_recentEpisodes_excludesPlayedAndInteracted() {
        let now = Date()
        let episodes = [
            makeEpisode(guid: "a", podcastUrl: "feed-a", pubDate: now, isPlayed: true),
            makeEpisode(guid: "b", podcastUrl: "feed-b", pubDate: now, isInteracted: true),
            makeEpisode(guid: "c", podcastUrl: "feed-c", pubDate: now),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.guid, "c")
    }

    // MARK: - RecentGridLayout (width-aware height calculation)

    /// Regression: 3 episodes at standard iPhone width (393pt) needs 2 rows, not 1.
    /// This is the exact scenario that caused the overlap bug.
    func test_gridHeight_3episodes_standardiPhoneWidth_isTwoRows() {
        let height = RecentGridLayout.gridHeight(episodeCount: 3, availableWidth: 393)
        let expectedTwoRowHeight = (RecentGridLayout.rowHeight * 2) + RecentGridLayout.rowSpacing
        XCTAssertEqual(height, expectedTwoRowHeight,
                       "3 episodes at 393pt width should produce 2-row height (354), not 1-row (170)")
    }

    func test_columnsPerRow_standardiPhone() {
        // 393 - 32 = 361 usable; 361 / 122 = 2.95 → 2 columns
        let cols = RecentGridLayout.columnsPerRow(availableWidth: 393)
        XCTAssertEqual(cols, 2, "Standard iPhone width should fit 2 columns")
    }

    func test_columnsPerRow_iPad() {
        // 1024 - 32 = 992 usable; 992 / 122 = 8.1 → 8 columns
        let cols = RecentGridLayout.columnsPerRow(availableWidth: 1024)
        XCTAssertEqual(cols, 8, "iPad width should fit 8 columns")
    }

    func test_gridHeight_2episodes_is1Row() {
        // 2 episodes in 2 columns = 1 row
        let height = RecentGridLayout.gridHeight(episodeCount: 2, availableWidth: 393)
        XCTAssertEqual(height, RecentGridLayout.rowHeight,
                       "2 episodes at iPhone width should be 1 row (170)")
    }

    func test_gridHeight_5episodes_is2Rows() {
        // 5 episodes in 2 columns = 3 rows, capped at 2
        let height = RecentGridLayout.gridHeight(episodeCount: 5, availableWidth: 393)
        let expectedTwoRowHeight = (RecentGridLayout.rowHeight * 2) + RecentGridLayout.rowSpacing
        XCTAssertEqual(height, expectedTwoRowHeight,
                       "5 episodes at iPhone width should be 2-row height (354)")
    }

    func test_fitsOnScreen_threshold() {
        // At 393pt: 2 cols × 2 rows = 4 items max
        XCTAssertTrue(RecentGridLayout.fitsOnScreen(episodeCount: 4, availableWidth: 393),
                      "4 episodes should fit on screen at iPhone width")
        XCTAssertFalse(RecentGridLayout.fitsOnScreen(episodeCount: 5, availableWidth: 393),
                       "5 episodes should NOT fit on screen at iPhone width")
    }
}

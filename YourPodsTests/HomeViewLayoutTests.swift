import XCTest
@testable import YourPods

/// Tests for the HomeView "Recently Updated" section's episode filtering logic.
/// The home screen shows a horizontally-scrollable 2-row grid of recent episodes
/// with a limit that determines how many are shown.
final class HomeViewLayoutTests: XCTestCase {

    // MARK: - Helper: mirrors HomeView.recentEpisodes logic

    /// Pure-logic filter mirroring HomeView's recent episodes computation.
    /// limit parameter should match HomeView.recentEpisodesLimit.
    private func recentEpisodes(
        from episodes: [Episode],
        limit: Int = HomeView.recentEpisodesLimit
    ) -> [Episode] {
        episodes
            .filter { !$0.isPlayed && !$0.isInteracted }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Convenience: create a test Episode with minimal fields.
    private func makeEpisode(
        guid: String,
        title: String = "Episode",
        pubDate: Date? = nil,
        isPlayed: Bool = false,
        isInteracted: Bool = false
    ) -> Episode {
        let ep = Episode(guid: guid, title: title, pubDate: pubDate)
        ep.isPlayed = isPlayed
        ep.isInteracted = isInteracted
        return ep
    }

    // MARK: - Limit

    func test_recentEpisodesLimit_isGreaterThan6ForHorizontalScroll() {
        // With the horizontal 2-row layout, we want more than the old 6 episodes
        XCTAssertGreaterThan(
            HomeView.recentEpisodesLimit, 6,
            "Horizontal scroll 2-row layout should show more than 6 episodes"
        )
    }

    func test_recentEpisodesLimit_equals12() {
        // Two rows × ~6 visible columns = 12 episode cards for the scrollable area
        XCTAssertEqual(
            HomeView.recentEpisodesLimit, 12,
            "Home screen should show 12 recent episodes for the 2-row horizontal scroll"
        )
    }

    func test_recentEpisodes_capsAtLimit() {
        let episodes = (0..<20).map { i in
            makeEpisode(
                guid: "ep-\(i)",
                pubDate: Date(timeIntervalSince1970: Double(i * 86400))
            )
        }
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(
            result.count, HomeView.recentEpisodesLimit,
            "Should cap at recentEpisodesLimit (\(HomeView.recentEpisodesLimit))"
        )
    }

    func test_recentEpisodes_returnsAllWhenBelowLimit() {
        let episodes = (0..<5).map { i in
            makeEpisode(
                guid: "ep-\(i)",
                pubDate: Date(timeIntervalSince1970: Double(i * 86400))
            )
        }
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 5, "Should return all episodes when below limit")
    }

    func test_recentEpisodes_sortedNewestFirst() {
        let old = Date(timeIntervalSince1970: 1000)
        let mid = Date(timeIntervalSince1970: 2000)
        let recent = Date(timeIntervalSince1970: 3000)

        let episodes = [
            makeEpisode(guid: "old", pubDate: old),
            makeEpisode(guid: "recent", pubDate: recent),
            makeEpisode(guid: "mid", pubDate: mid),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.map(\.guid), ["recent", "mid", "old"], "Should be newest first")
    }

    func test_recentEpisodes_excludesPlayedAndInteracted() {
        let episodes = [
            makeEpisode(guid: "a", pubDate: Date(), isPlayed: true),
            makeEpisode(guid: "b", pubDate: Date(), isInteracted: true),
            makeEpisode(guid: "c", pubDate: Date()),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.guid, "c")
    }
}

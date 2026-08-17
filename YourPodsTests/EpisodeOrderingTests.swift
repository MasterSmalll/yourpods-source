import XCTest
@testable import YourPods

/// Tests that episode ordering is deterministic and stable when pubDates
/// are nil or equal — verifying the `episodesByFeedOrder` comparator.
final class EpisodeOrderingTests: XCTestCase {

    // MARK: - Comparator: distinct pubDates sort newest-first (existing behavior)

    func test_distinctPubDates_sortNewestFirst() {
        let a = makeStub(guid: "a", pubDate: date("2026-06-10"), feedItemIndex: 0)
        let b = makeStub(guid: "b", pubDate: date("2026-06-12"), feedItemIndex: 1)
        let c = makeStub(guid: "c", pubDate: date("2026-06-11"), feedItemIndex: 2)

        let sorted = [a, b, c].sorted(by: episodesByFeedOrder)
        XCTAssertEqual(sorted.map(\.guid), ["b", "c", "a"])
    }

    // MARK: - Comparator: nil pubDates sort last (before: arbitrary)

    func test_nilPubDates_sortByFeedItemIndex() {
        let a = makeStub(guid: "a", pubDate: nil, feedItemIndex: 0)
        let b = makeStub(guid: "b", pubDate: nil, feedItemIndex: 1)
        let c = makeStub(guid: "c", pubDate: nil, feedItemIndex: 2)

        let sorted = [c, a, b].sorted(by: episodesByFeedOrder)
        XCTAssertEqual(sorted.map(\.guid), ["a", "b", "c"],
                       "Equal/nil pubDates should fall back to feedItemIndex ascending (document order)")
    }

    // MARK: - Comparator: equal pubDates tie-break by season/episode/feedItemIndex

    func test_equalPubDates_tieBreakBySeasonEpisode() {
        let sameDate = date("2026-06-10")
        let a = makeStub(guid: "a", pubDate: sameDate, feedItemIndex: 0, season: 2, episode: 5)
        let b = makeStub(guid: "b", pubDate: sameDate, feedItemIndex: 1, season: 2, episode: 3)
        let c = makeStub(guid: "c", pubDate: sameDate, feedItemIndex: 2, season: 1, episode: 10)

        let sorted = [c, a, b].sorted(by: episodesByFeedOrder)
        // Season desc → 2, 2, 1 → then episode desc → 5, 3 within season 2
        XCTAssertEqual(sorted.map(\.guid), ["a", "b", "c"])
    }

    // MARK: - Comparator: guid as final tiebreaker

    func test_allTiesEqual_fallbackToGuid() {
        let sameDate = date("2026-06-10")
        let a = makeStub(guid: "alpha", pubDate: sameDate, feedItemIndex: nil)
        let b = makeStub(guid: "bravo", pubDate: sameDate, feedItemIndex: nil)

        let sorted = [b, a].sorted(by: episodesByFeedOrder)
        XCTAssertEqual(sorted.map(\.guid), ["alpha", "bravo"],
                       "When everything ties, guid asc is the final deterministic tiebreaker")
    }

    // MARK: - Comparator: stability across repeated sorts

    func test_repeatedSorts_areStable() {
        let sameDate = date("2026-06-10")
        let episodes = (0..<20).map { i in
            makeStub(guid: "ep-\(i)", pubDate: sameDate, feedItemIndex: i)
        }.shuffled()

        let first = episodes.sorted(by: episodesByFeedOrder)
        let second = episodes.sorted(by: episodesByFeedOrder)
        let third = first.shuffled().sorted(by: episodesByFeedOrder)

        XCTAssertEqual(first.map(\.guid), second.map(\.guid), "Sort must be deterministic")
        XCTAssertEqual(first.map(\.guid), third.map(\.guid), "Sort must be stable across shuffles")
    }

    // MARK: - Helpers

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: s)!
    }

    /// Lightweight Episode stub for comparator testing.
    /// Uses Episode directly (no ModelContainer needed since the comparator
    /// only reads stored properties, not relationships).
    private func makeStub(
        guid: String,
        pubDate: Date?,
        feedItemIndex: Int?,
        season: Int? = nil,
        episode: Double? = nil
    ) -> Episode {
        let ep = Episode(guid: guid, title: guid, pubDate: pubDate)
        ep.feedItemIndex = feedItemIndex
        ep.seasonNumber = season
        ep.episodeNumber = episode
        return ep
    }
}

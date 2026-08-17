import XCTest
@testable import YourPods

final class LibraryEpisodeListTests: XCTestCase {

    private func ep(_ guid: String, daysAgo: Int, isPlayed: Bool = false,
                    isStale: Bool = false, title: String = "Episode") -> Episode {
        let d = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        let e = Episode(guid: guid, title: title, pubDate: d)
        e.isPlayed = isPlayed
        e.isStale = isStale
        return e
    }

    private let none: (String) -> Bool = { _ in false }

    // Newest-first ordering across shows.
    func test_all_sortsNewestFirst_excludesStale() {
        let eps = [ep("a", daysAgo: 5), ep("b", daysAgo: 1), ep("c", daysAgo: 3), ep("stale", daysAgo: 0, isStale: true)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .all,
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertEqual(r.episodes.map(\.guid), ["b", "c", "a"])
        XCTAssertEqual(r.overflowCount, 0)
    }

    // Unplayed uses the shared predicate.
    func test_unplayed_dropsPlayed() {
        let eps = [ep("u", daysAgo: 1), ep("p", daysAgo: 2, isPlayed: true)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .unplayed,
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertEqual(r.episodes.map(\.guid), ["u"])
    }

    func test_downloaded_usesClosure() {
        let eps = [ep("d", daysAgo: 1), ep("x", daysAgo: 2)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .downloaded,
                                         isDownloaded: { $0 == "d" }, hasInProgressAction: none)
        XCTAssertEqual(r.episodes.map(\.guid), ["d"])
    }

    func test_inProgress_usesClosure() {
        let eps = [ep("i", daysAgo: 1), ep("x", daysAgo: 2)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .inProgress,
                                         isDownloaded: none, hasInProgressAction: { $0 == "i" })
        XCTAssertEqual(r.episodes.map(\.guid), ["i"])
    }

    func test_groups_returnsEmpty() {
        let r = LibraryEpisodeList.build(episodes: [ep("a", daysAgo: 1)], filter: .groups,
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertTrue(r.episodes.isEmpty, "Groups has no episode lens")
    }

    // Cap + overflow.
    func test_capLimitsAndReportsOverflow() {
        let eps = (0..<10).map { ep("e\($0)", daysAgo: $0) }  // e0 newest
        let r = LibraryEpisodeList.build(episodes: eps, filter: .all, cap: 4,
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertEqual(r.episodes.map(\.guid), ["e0", "e1", "e2", "e3"])
        XCTAssertEqual(r.overflowCount, 6)
    }

    func test_noOverflow_whenUnderCap() {
        let eps = [ep("a", daysAgo: 1), ep("b", daysAgo: 2)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .all, cap: 10,
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertEqual(r.overflowCount, 0)
    }

    // Title query filters before the cap; matches title or podcast title (nil-safe).
    func test_titleQuery_filtersByTitle() {
        let eps = [ep("a", daysAgo: 1, title: "Swift Talk"), ep("b", daysAgo: 2, title: "Cooking Hour")]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .all, titleQuery: "swift",
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertEqual(r.episodes.map(\.guid), ["a"])
    }

    // Hidden episodes are excluded from the episode lens (respect the user's hide action).
    func test_excludesHiddenEpisodes() {
        let eps = [ep("v", daysAgo: 1), ep("h", daysAgo: 2)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .all,
                                         isDownloaded: none, hasInProgressAction: none,
                                         isHidden: { $0 == "h" })
        XCTAssertEqual(r.episodes.map(\.guid), ["v"], "Hidden episode must not appear in the episode lens")
    }

    // Hidden gates out an episode even when it matches the active filter.
    func test_hiddenExcluded_evenWhenMatchingFilter() {
        let eps = [ep("d", daysAgo: 1), ep("dh", daysAgo: 2)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .downloaded,
                                         isDownloaded: { _ in true }, hasInProgressAction: none,
                                         isHidden: { $0 == "dh" })
        XCTAssertEqual(r.episodes.map(\.guid), ["d"], "Hidden gates out episodes even when they match the filter")
    }

    // Default isHidden (omitted) hides nothing — preserves existing call sites/tests.
    func test_isHiddenDefaults_toNoExclusion() {
        let eps = [ep("a", daysAgo: 1), ep("b", daysAgo: 2)]
        let r = LibraryEpisodeList.build(episodes: eps, filter: .all,
                                         isDownloaded: none, hasInProgressAction: none)
        XCTAssertEqual(r.episodes.map(\.guid), ["a", "b"], "Omitting isHidden must not drop anything")
    }
}

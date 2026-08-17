import XCTest
@testable import YourPods

final class EpisodeArrangerTests: XCTestCase {

    // Fixed reference "now": 2023-11-14 22:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // Boundaries computed the same way the arranger does, so they align regardless of timezone.
    private var startOfToday: Date { Calendar.current.startOfDay(for: now) }
    private var weekAgo: Date { Calendar.current.date(byAdding: .day, value: -7, to: startOfToday)! }

    private func ep(_ guid: String, offsetDays: Double, title: String = "T") -> Episode {
        Episode(guid: guid, title: title, pubDate: now.addingTimeInterval(offsetDays * 86_400))
    }

    func test_newest_singleUntitledSection_passthrough() {
        let eps = [ep("a", offsetDays: 0), ep("b", offsetDays: -1)]
        let s = EpisodeArranger.sections(episodes: eps, arrangement: .newest, now: now)
        XCTAssertEqual(s.count, 1)
        XCTAssertNil(s[0].title)
        XCTAssertEqual(s[0].episodes.map(\.guid), ["a", "b"])
    }

    func test_byDate_bucketsTodayThisWeekEarlier() {
        let eps = [
            ep("today", offsetDays: -0.1),   // earlier today
            ep("week", offsetDays: -3),      // 3 days ago
            ep("old", offsetDays: -20),      // 20 days ago
        ]
        let s = EpisodeArranger.sections(episodes: eps, arrangement: .byDate, now: now)
        XCTAssertEqual(s.map(\.title), ["Today", "This Week", "Earlier"])
        XCTAssertEqual(s[0].episodes.map(\.guid), ["today"])
        XCTAssertEqual(s[1].episodes.map(\.guid), ["week"])
        XCTAssertEqual(s[2].episodes.map(\.guid), ["old"])
    }

    func test_byDate_omitsEmptyBuckets_andNilPubDateGoesToEarlier() {
        let nilDate = Episode(guid: "nd", title: "T", pubDate: nil)
        let s = EpisodeArranger.sections(episodes: [ep("old", offsetDays: -30), nilDate],
                                         arrangement: .byDate, now: now)
        XCTAssertEqual(s.map(\.title), ["Earlier"])
        XCTAssertEqual(Set(s[0].episodes.map(\.guid)), ["old", "nd"])
    }

    func test_byShow_groupsInFirstAppearanceOrder() {
        // Build episodes with distinct podcast titles via a Podcast relationship.
        func withShow(_ guid: String, _ show: String, offsetDays: Double) -> Episode {
            let e = ep(guid, offsetDays: offsetDays)
            let p = Podcast(url: "https://x/\(show)", title: show)
            e.podcast = p
            return e
        }
        let eps = [
            withShow("a1", "Alpha", offsetDays: 0),
            withShow("b1", "Bravo", offsetDays: -1),
            withShow("a2", "Alpha", offsetDays: -2),
        ]
        let s = EpisodeArranger.sections(episodes: eps, arrangement: .byShow, now: now)
        XCTAssertEqual(s.map(\.title), ["Alpha", "Bravo"])
        XCTAssertEqual(s[0].episodes.map(\.guid), ["a1", "a2"])
        XCTAssertEqual(s[1].episodes.map(\.guid), ["b1"])
    }

    // MARK: - EDGE: byDate bucket boundaries

    func test_EDGE_byDate_pubDateExactlyStartOfToday_goesToToday() {
        let e = Episode(guid: "boundary", title: "T", pubDate: startOfToday)
        let s = EpisodeArranger.sections(episodes: [e], arrangement: .byDate, now: now)
        XCTAssertEqual(s.map(\.title), ["Today"])
        XCTAssertEqual(s[0].episodes.map(\.guid), ["boundary"])
    }

    func test_EDGE_byDate_pubDateExactlyWeekAgo_goesToThisWeek() {
        let e = Episode(guid: "boundary", title: "T", pubDate: weekAgo)
        let s = EpisodeArranger.sections(episodes: [e], arrangement: .byDate, now: now)
        XCTAssertEqual(s.map(\.title), ["This Week"])
        XCTAssertEqual(s[0].episodes.map(\.guid), ["boundary"])
    }

    func test_EDGE_byDate_pubDateJustBeforeWeekAgo_goesToEarlier() {
        let e = Episode(guid: "boundary", title: "T", pubDate: weekAgo.addingTimeInterval(-1))
        let s = EpisodeArranger.sections(episodes: [e], arrangement: .byDate, now: now)
        XCTAssertEqual(s.map(\.title), ["Earlier"])
        XCTAssertEqual(s[0].episodes.map(\.guid), ["boundary"])
    }
}

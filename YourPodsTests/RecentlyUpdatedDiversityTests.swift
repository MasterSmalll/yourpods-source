import XCTest
@testable import YourPods

/// Tests that the "Recently Updated" section limits episodes per podcast
/// to those from the last 2 months, ensuring diversity across podcasts.
final class RecentlyUpdatedDiversityTests: XCTestCase {

    // MARK: - Helpers

    /// Create a test episode with a specific podcast URL, pubDate, and guid.
    private func makeEpisode(
        guid: String,
        podcastUrl: String,
        pubDate: Date,
        isPlayed: Bool = false,
        isInteracted: Bool = false,
        isStale: Bool = false
    ) -> Episode {
        let ep = Episode(
            guid: guid,
            title: "Episode \(guid)",
            audioUrl: "https://example.com/\(guid).mp3",
            pubDate: pubDate,
            durationSeconds: 3600
        )
        ep.isPlayed = isPlayed
        ep.isInteracted = isInteracted
        ep.isStale = isStale
        return ep
    }

    // MARK: - Per-Podcast Cutoff Tests

    func test_filterRecentlyUpdated_excludesEpisodesOlderThan2Months() {
        let now = Date()
        let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now)!
        let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: now)!

        let episodes = [
            makeEpisode(guid: "recent", podcastUrl: "feed-a", pubDate: oneMonthAgo),
            makeEpisode(guid: "old", podcastUrl: "feed-a", pubDate: threeMonthsAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 12,
            now: now
        )

        XCTAssertEqual(result.count, 1, "Should exclude episodes older than 2 months")
        XCTAssertEqual(result.first?.guid, "recent")
    }

    func test_filterRecentlyUpdated_episodesExactlyAt2MonthsAreIncluded() {
        let now = Date()
        let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: now)!

        let episodes = [
            makeEpisode(guid: "boundary", podcastUrl: "feed-a", pubDate: twoMonthsAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 12,
            now: now
        )

        XCTAssertEqual(result.count, 1, "Episodes exactly at 2-month boundary should be included")
    }

    func test_filterRecentlyUpdated_improvesDiversityAcrossPodcasts() {
        let now = Date()
        // Podcast A: publishes daily — 10 episodes all within last month
        var episodes: [Episode] = (0..<10).map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return makeEpisode(guid: "a-\(i)", podcastUrl: "feed-a", pubDate: date)
        }
        // Podcast B: publishes weekly — 2 episodes within last month
        episodes += [
            makeEpisode(guid: "b-0", podcastUrl: "feed-b",
                        pubDate: Calendar.current.date(byAdding: .day, value: -1, to: now)!),
            makeEpisode(guid: "b-1", podcastUrl: "feed-b",
                        pubDate: Calendar.current.date(byAdding: .day, value: -7, to: now)!),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 12,
            now: now
        )

        // Both podcasts should appear in results
        let podcastBCount = result.filter { $0.guid.hasPrefix("b-") }.count
        XCTAssertEqual(podcastBCount, 2, "Both Podcast B episodes should appear")
    }

    func test_filterRecentlyUpdated_respectsLimit() {
        let now = Date()
        let episodes: [Episode] = (0..<20).map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            return makeEpisode(guid: "ep-\(i)", podcastUrl: "feed-a", pubDate: date)
        }

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 12,
            now: now
        )

        XCTAssertLessThanOrEqual(result.count, 12, "Should respect the limit parameter")
    }

    func test_filterRecentlyUpdated_sortsNewestFirst() {
        let now = Date()
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        let episodes = [
            makeEpisode(guid: "older", podcastUrl: "feed-a", pubDate: twoDaysAgo),
            makeEpisode(guid: "newer", podcastUrl: "feed-b", pubDate: oneDayAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 12,
            now: now
        )

        XCTAssertEqual(result.first?.guid, "newer", "Results should be sorted newest first")
    }

    func test_filterRecentlyUpdated_excludesPlayedAndInteracted() {
        let now = Date()
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        let episodes = [
            makeEpisode(guid: "played", podcastUrl: "feed-a", pubDate: oneDayAgo, isPlayed: true),
            makeEpisode(guid: "interacted", podcastUrl: "feed-a", pubDate: oneDayAgo, isInteracted: true),
            makeEpisode(guid: "stale", podcastUrl: "feed-a", pubDate: oneDayAgo, isStale: true),
            makeEpisode(guid: "fresh", podcastUrl: "feed-a", pubDate: oneDayAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 12,
            now: now
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.guid, "fresh")
    }

    func test_filterRecentlyUpdated_nilPubDateExcluded() {
        let now = Date()
        let ep = Episode(
            guid: "no-date",
            title: "No Date Episode",
            audioUrl: "https://example.com/no-date.mp3",
            durationSeconds: 3600
        )

        let result = RecentlyUpdatedFilter.filter(
            episodes: [ep],
            limit: 12,
            now: now
        )

        XCTAssertEqual(result.count, 0, "Episodes with nil pubDate should be excluded")
    }
}

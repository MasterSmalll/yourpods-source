import XCTest
@testable import YourPods

// MARK: - Recently Updated Filter Tests (v2: Freshness + Overflow)

/// Tests for the updated RecentlyUpdatedFilter with:
/// - 3-month window (was 2)
/// - Per-podcast guarantee (podcastGuid grouping, URL fallback)
/// - Overflow count for "+N others" card
final class RecentlyUpdatedFilterV2Tests: XCTestCase {

    // MARK: - Helpers

    /// Create a test episode attached to a podcast with a given URL and optional GUID.
    /// Uses a real Podcast object so episode.podcast?.podcastGuid and episode.podcast?.url work.
    private func makeEpisode(
        guid: String,
        podcastUrl: String,
        podcastGuid: String? = nil,
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
        // Attach a lightweight podcast for grouping
        let podcast = Podcast(url: podcastUrl, title: "Podcast \(podcastUrl)")
        podcast.podcastGuid = podcastGuid
        ep.podcast = podcast
        return ep
    }

    /// Convenience: create N episodes from the same podcast, offset by day.
    private func makeEpisodesForPodcast(
        prefix: String,
        podcastUrl: String,
        podcastGuid: String? = nil,
        count: Int,
        startDaysAgo: Int = 0,
        now: Date = Date()
    ) -> [Episode] {
        let podcast = Podcast(url: podcastUrl, title: "Podcast \(prefix)")
        podcast.podcastGuid = podcastGuid
        return (0..<count).map { i in
            let ep = Episode(
                guid: "\(prefix)-\(i)",
                title: "Episode \(prefix)-\(i)",
                audioUrl: "https://example.com/\(prefix)-\(i).mp3",
                pubDate: Calendar.current.date(byAdding: .day, value: -(startDaysAgo + i), to: now)!,
                durationSeconds: 3600
            )
            ep.podcast = podcast
            return ep
        }
    }

    // MARK: - 3-Month Window

    func test_filter_excludesEpisodesOlderThan3Months() {
        let now = Date()
        let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: now)!
        let fourMonthsAgo = Calendar.current.date(byAdding: .month, value: -4, to: now)!

        let episodes = [
            makeEpisode(guid: "recent", podcastUrl: "feed-a", pubDate: twoMonthsAgo),
            makeEpisode(guid: "old", podcastUrl: "feed-a", pubDate: fourMonthsAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 27,
            now: now
        )

        XCTAssertEqual(result.episodes.count, 1, "Should exclude episodes older than 3 months")
        XCTAssertEqual(result.episodes.first?.guid, "recent")
    }

    func test_filter_episodesExactlyAt3MonthsAreIncluded() {
        let now = Date()
        let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: now)!

        let episodes = [
            makeEpisode(guid: "boundary", podcastUrl: "feed-a", pubDate: threeMonthsAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 27,
            now: now
        )

        XCTAssertEqual(result.episodes.count, 1, "Episodes exactly at 3-month boundary should be included")
    }

    // MARK: - Per-Podcast Guarantee (podcastGuid grouping)

    func test_filter_guaranteesNewestPerPodcast_prolificCantCrowdOut() {
        let now = Date()
        // Podcast A (prolific): publishes daily — 20 episodes
        let podcastAEpisodes = makeEpisodesForPodcast(
            prefix: "a", podcastUrl: "feed-a", podcastGuid: "guid-a",
            count: 20, now: now
        )
        // Podcast B (infrequent): published once 45 days ago
        let podcastBEpisodes = [
            makeEpisode(guid: "b-0", podcastUrl: "feed-b", podcastGuid: "guid-b",
                        pubDate: Calendar.current.date(byAdding: .day, value: -45, to: now)!)
        ]

        let allEpisodes = podcastAEpisodes + podcastBEpisodes

        let result = RecentlyUpdatedFilter.filter(
            episodes: allEpisodes,
            limit: 10,
            now: now
        )

        // Podcast B's single episode MUST appear even though it's older than all of A's
        let bGuids = result.episodes.filter { $0.guid.hasPrefix("b-") }
        XCTAssertEqual(bGuids.count, 1,
                       "Infrequent podcast's newest episode must be guaranteed a slot")
    }

    func test_filter_groupsByPodcastGuid_notUrl() {
        let now = Date()
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        // Same podcast GUID, different URLs (URL changed due to dynamic ads)
        let ep1 = makeEpisode(guid: "ep1", podcastUrl: "feed-old-url",
                              podcastGuid: "shared-guid", pubDate: oneDayAgo)
        let ep2 = makeEpisode(guid: "ep2", podcastUrl: "feed-new-url",
                              podcastGuid: "shared-guid", pubDate: twoDaysAgo)

        // Both have the same podcastGuid — only the newest (ep1) should be a primary.
        // With limit=1, only the newest primary should appear.
        let result = RecentlyUpdatedFilter.filter(
            episodes: [ep1, ep2],
            limit: 1,
            now: now
        )
        XCTAssertEqual(result.episodes.count, 1)
        XCTAssertEqual(result.episodes.first?.guid, "ep1",
                       "Should group by podcastGuid, keeping newest as primary")
    }

    func test_filter_fallsBackToUrlWhenGuidIsNil() {
        let now = Date()
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        // No podcastGuid — should group by URL
        let ep1 = makeEpisode(guid: "ep1", podcastUrl: "feed-a", pubDate: oneDayAgo)
        let ep2 = makeEpisode(guid: "ep2", podcastUrl: "feed-a", pubDate: twoDaysAgo)
        let ep3 = makeEpisode(guid: "ep3", podcastUrl: "feed-b", pubDate: twoDaysAgo)

        let result = RecentlyUpdatedFilter.filter(
            episodes: [ep1, ep2, ep3],
            limit: 2,
            now: now
        )

        // With limit=2: feed-a primary (ep1) + feed-b primary (ep3) = 2 primaries
        let guids = Set(result.episodes.map(\.guid))
        XCTAssertTrue(guids.contains("ep1"), "feed-a's newest should be a primary")
        XCTAssertTrue(guids.contains("ep3"), "feed-b's newest should be a primary")
    }

    // MARK: - Cap & Overflow

    func test_filter_respectsLimit() {
        let now = Date()
        let episodes = makeEpisodesForPodcast(
            prefix: "ep", podcastUrl: "feed-a", count: 30, now: now
        )

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 27,
            now: now
        )

        XCTAssertLessThanOrEqual(result.episodes.count, 27, "Should respect the limit parameter")
    }

    func test_filter_returnsOverflowCount() {
        let now = Date()
        let episodes = makeEpisodesForPodcast(
            prefix: "ep", podcastUrl: "feed-a", count: 30, now: now
        )

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 27,
            now: now
        )

        XCTAssertEqual(result.overflowCount, 3,
                       "Overflow count should be totalEligible - limit = 30 - 27 = 3")
    }

    func test_filter_overflowCountIsZeroWhenAllFit() {
        let now = Date()
        let episodes = makeEpisodesForPodcast(
            prefix: "ep", podcastUrl: "feed-a", count: 5, now: now
        )

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 27,
            now: now
        )

        XCTAssertEqual(result.overflowCount, 0, "No overflow when all episodes fit")
    }

    // MARK: - Exclusions

    func test_filter_excludesPlayedInteractedStaleNilPubDate() {
        let now = Date()
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        let episodes = [
            makeEpisode(guid: "played", podcastUrl: "feed-a", pubDate: oneDayAgo, isPlayed: true),
            makeEpisode(guid: "interacted", podcastUrl: "feed-a", pubDate: oneDayAgo, isInteracted: true),
            makeEpisode(guid: "stale", podcastUrl: "feed-a", pubDate: oneDayAgo, isStale: true),
            makeEpisode(guid: "fresh", podcastUrl: "feed-a", pubDate: oneDayAgo),
        ]
        // Add one with nil pubDate
        let noPubDate = Episode(guid: "no-date", title: "No Date", audioUrl: "https://x.com/a.mp3", durationSeconds: 300)
        noPubDate.podcast = Podcast(url: "feed-a", title: "Pod A")

        let allEps = episodes + [noPubDate]

        let result = RecentlyUpdatedFilter.filter(
            episodes: allEps,
            limit: 27,
            now: now
        )

        XCTAssertEqual(result.episodes.count, 1)
        XCTAssertEqual(result.episodes.first?.guid, "fresh")
    }

    // MARK: - Sort Order

    func test_filter_sortsNewestFirst() {
        let now = Date()
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!

        let episodes = [
            makeEpisode(guid: "oldest", podcastUrl: "feed-c", pubDate: threeDaysAgo),
            makeEpisode(guid: "newest", podcastUrl: "feed-a", pubDate: oneDayAgo),
            makeEpisode(guid: "middle", podcastUrl: "feed-b", pubDate: twoDaysAgo),
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 27,
            now: now
        )

        let guids = result.episodes.map(\.guid)
        XCTAssertEqual(guids, ["newest", "middle", "oldest"], "Results should be sorted newest first")
    }

    // MARK: - Edge: primaries exceed cap

    func test_filter_whenMorePodcastsThanLimit_takesNewestPrimaries() {
        let now = Date()
        // 30 different podcasts, each with 1 episode
        var episodes: [Episode] = []
        for i in 0..<30 {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now)!
            episodes.append(
                makeEpisode(guid: "pod\(i)-ep", podcastUrl: "feed-\(i)", pubDate: date)
            )
        }

        let result = RecentlyUpdatedFilter.filter(
            episodes: episodes,
            limit: 10,
            now: now
        )

        XCTAssertEqual(result.episodes.count, 10, "Cap should be honored even when primaries > limit")
        XCTAssertEqual(result.overflowCount, 20, "Overflow should be 30 - 10 = 20")
        // The 10 selected should be the 10 newest primaries
        XCTAssertEqual(result.episodes.first?.guid, "pod0-ep", "Newest primary should be first")
    }

    // MARK: - Edge: extras fill remaining slots

    func test_filter_extrasFromProlificPodcastFillRemainingSlots() {
        let now = Date()
        // 2 podcasts, podcast A has 10 episodes, podcast B has 1
        let podA = makeEpisodesForPodcast(prefix: "a", podcastUrl: "feed-a", count: 10, now: now)
        let podB = [
            makeEpisode(guid: "b-0", podcastUrl: "feed-b",
                        pubDate: Calendar.current.date(byAdding: .day, value: -15, to: now)!)
        ]

        let result = RecentlyUpdatedFilter.filter(
            episodes: podA + podB,
            limit: 5,
            now: now
        )

        // 2 primaries (a-0, b-0) + 3 extras (a-1, a-2, a-3) = 5 total
        XCTAssertEqual(result.episodes.count, 5)
        let bCount = result.episodes.filter { $0.guid.hasPrefix("b-") }.count
        XCTAssertEqual(bCount, 1, "Podcast B's primary must be present")
    }

    func test_filter_orphanedEpisodesDoNotCrowdOutPodcasts() {
        let now = Date()
        
        let orphaned1 = Episode(guid: "orphan1", title: "Orphan 1", audioUrl: "url", pubDate: now, durationSeconds: 100)
        let orphaned2 = Episode(guid: "orphan2", title: "Orphan 2", audioUrl: "url", pubDate: Calendar.current.date(byAdding: .day, value: -1, to: now)!, durationSeconds: 100)
        
        // Two actual podcasts, but older than orphans
        let pod1 = makeEpisode(guid: "pod1", podcastUrl: "feed-a", pubDate: Calendar.current.date(byAdding: .day, value: -2, to: now)!)
        let pod2 = makeEpisode(guid: "pod2", podcastUrl: "feed-b", pubDate: Calendar.current.date(byAdding: .day, value: -3, to: now)!)
        
        let result = RecentlyUpdatedFilter.filter(
            episodes: [orphaned1, orphaned2, pod1, pod2],
            limit: 2,
            now: now
        )
        
        // We only have space for 2. 
        // Actual podcasts should be the primaries. Orphans should be extras.
        // So pod1 and pod2 should take the slots.
        let guids = result.episodes.map(\.guid)
        XCTAssertTrue(guids.contains("pod1"), "Podcast 1 primary should not be crowded out by orphan")
        XCTAssertTrue(guids.contains("pod2"), "Podcast 2 primary should not be crowded out by orphan")
        XCTAssertFalse(guids.contains("orphan1"), "Orphan should fall through to extras")
    }
}

import Foundation

/// Filters episodes for the "Recently Updated" section.
/// Applies a recency cutoff with per-podcast guarantees to ensure diversity —
/// each podcast's newest episode gets a guaranteed slot before extras fill remaining capacity.
enum RecentlyUpdatedFilter {

    /// Result of the filter operation, including overflow count for the "+N others" card.
    struct FilterResult {
        let episodes: [Episode]
        let overflowCount: Int
    }

    /// Filter episodes for the Recently Updated section.
    ///
    /// Algorithm (v2):
    /// 1. 3-month window cutoff.
    /// 2. Eligible = unplayed, un-interacted, non-stale, has pubDate within window.
    /// 3. Group by podcast identity (podcastGuid → URL fallback).
    /// 4. Guarantee newest per-podcast as "primary".
    /// 5. Fill remaining slots with extras (newest-first).
    /// 6. Return overflow count for "+N others" card.
    ///
    /// - Parameters:
    ///   - episodes: All episodes to consider (from all subscriptions).
    ///   - limit: Maximum number of episodes to return.
    ///   - now: Current date (injectable for testing).
    /// - Returns: FilterResult with episodes (newest first) and overflow count.
    static func filter(
        episodes: [Episode],
        limit: Int,
        now: Date = Date()
    ) -> FilterResult {
        let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: now) ?? now

        // Step 1: Filter eligible episodes
        let eligible = episodes.filter { episode in
            !episode.isPlayed
            && !episode.isInteracted
            && !episode.isStale
            && episode.pubDate != nil
            && episode.pubDate! >= cutoff
        }

        // Step 2: Group by podcast identity (podcastGuid → URL fallback). Orphaned go to extras.
        var grouped: [String: [Episode]] = [:]
        var extras: [Episode] = []
        for ep in eligible {
            if let podcast = ep.podcast {
                let key = podcast.podcastGuid ?? podcast.url
                grouped[key, default: []].append(ep)
            } else {
                extras.append(ep)
            }
        }

        // Step 3: Extract primaries (newest per group) and extras
        var primaries: [Episode] = []
        for (_, group) in grouped {
            let sorted = group.sorted(by: episodesByFeedOrder)
            if let newest = sorted.first {
                primaries.append(newest)
                extras.append(contentsOf: sorted.dropFirst())
            }
        }

        // Step 4: Select episodes respecting the cap
        let selected: [Episode]
        if primaries.count >= limit {
            // More podcasts than slots — take the newest primaries
            selected = primaries
                .sorted(by: episodesByFeedOrder)
                .prefix(limit)
                .map { $0 }
        } else {
            // All primaries fit — fill remaining slots with newest extras
            let remaining = limit - primaries.count
            let extrasFill = extras
                .sorted(by: episodesByFeedOrder)
                .prefix(remaining)
            selected = (primaries + extrasFill)
                .sorted(by: episodesByFeedOrder)
        }

        return FilterResult(
            episodes: selected,
            overflowCount: max(0, eligible.count - limit)
        )
    }
}

import Foundation

/// Filters episodes for the "Recently Updated" section.
/// Applies a 2-month recency cutoff to ensure podcast diversity —
/// prolific podcasts can't dominate the list with many old episodes.
enum RecentlyUpdatedFilter {

    /// Filter episodes for the Recently Updated section.
    ///
    /// Only includes episodes that are:
    /// - Not played, not interacted, not stale
    /// - Published within the last 2 months
    /// - Have a non-nil pubDate
    ///
    /// Results are sorted newest-first and capped at `limit`.
    ///
    /// - Parameters:
    ///   - episodes: All episodes to consider (from all subscriptions).
    ///   - limit: Maximum number of episodes to return.
    ///   - now: Current date (injectable for testing).
    /// - Returns: Filtered and sorted episodes, newest first.
    static func filter(
        episodes: [Episode],
        limit: Int,
        now: Date = Date()
    ) -> [Episode] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -2, to: now) ?? now

        return episodes
            .filter { episode in
                !episode.isPlayed
                && !episode.isInteracted
                && !episode.isStale
                && episode.pubDate != nil
                && episode.pubDate! >= cutoff
            }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

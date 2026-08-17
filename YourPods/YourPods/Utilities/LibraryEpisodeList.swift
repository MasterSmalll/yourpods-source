import Foundation

/// Builds the flat, capped episode list for the Library's Episode lens.
/// Filter predicates are shared with the podcast lens via `EpisodeFilterPredicate`.
enum LibraryEpisodeList {

    /// Newest-N cap for the episode lens (spec: guards an unbounded "All").
    static let defaultCap = 200

    struct Result {
        let episodes: [Episode]
        /// Matches beyond the cap (drives the "older hidden" footer). 0 when nothing hidden.
        let overflowCount: Int
    }

    static func build(
        episodes: [Episode],
        filter: LibraryView.LibraryFilter,
        titleQuery: String = "",
        cap: Int = defaultCap,
        isDownloaded: (String) -> Bool,
        hasInProgressAction: (String) -> Bool,
        isHidden: (String) -> Bool = { _ in false }
    ) -> Result {
        // 1. Exclude hidden episodes (respect the user's hide action, matching podcast
        //    detail), then apply the lens filter's per-episode predicate.
        var matched = episodes.filter { ep in
            guard !isHidden(ep.guid) else { return false }
            switch filter {
            case .all:        return !ep.isStale
            case .downloaded: return EpisodeFilterPredicate.isDownloaded(ep, isDownloaded: isDownloaded)
            case .unplayed:   return EpisodeFilterPredicate.isUnplayed(ep)
            case .inProgress: return EpisodeFilterPredicate.isInProgress(ep, hasAction: hasInProgressAction)
            case .groups:     return false   // Groups is podcast-only — no episode lens.
            }
        }

        // 2. Optional text query on episode title or podcast title.
        let query = titleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            matched = matched.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.podcastTitle?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        // 3. Newest-first by pubDate.
        let sorted = matched.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }

        // 4. Cap and report overflow.
        return Result(
            episodes: Array(sorted.prefix(cap)),
            overflowCount: max(0, sorted.count - cap)
        )
    }
}

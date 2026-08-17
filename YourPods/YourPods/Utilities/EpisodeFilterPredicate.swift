import Foundation

/// Per-episode membership predicates for Library filters. Shared by the podcast lens
/// (`LibraryView.filteredSubscriptions`) and the episode lens (`LibraryEpisodeList`) so the
/// two lenses can never diverge. Kept pure (no manager reads) via injected closures/cutoff.
enum EpisodeFilterPredicate {

    /// Unplayed against an explicit cutoff (testable, pure).
    static func isUnplayed(_ ep: Episode, markedPlayedBefore: Date?) -> Bool {
        guard !ep.isStale else { return false }
        guard !ep.isPlayed else { return false }
        guard let pubDate = ep.pubDate else { return false }
        if let cutoff = markedPlayedBefore { return pubDate > cutoff }
        return true
    }

    /// Unplayed using the episode's own podcast cutoff (used by app code).
    static func isUnplayed(_ ep: Episode) -> Bool {
        isUnplayed(ep, markedPlayedBefore: ep.podcast?.effectiveSettings.markedPlayedBefore)
    }

    /// Downloaded: non-stale and present on disk.
    static func isDownloaded(_ ep: Episode, isDownloaded: (String) -> Bool) -> Bool {
        !ep.isStale && isDownloaded(ep.guid)
    }

    /// In progress: non-stale and has a latest playback action recorded.
    static func isInProgress(_ ep: Episode, hasAction: (String) -> Bool) -> Bool {
        !ep.isStale && hasAction(ep.guid)
    }
}

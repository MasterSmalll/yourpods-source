import Foundation

/// Deterministic, total ordering for episodes. pubDate desc (nil last) → season desc
/// → episode desc → feedItemIndex asc (stable feed order) → guid asc.
/// Identical to today for distinct pubDates; only ties become deterministic.
func episodesByFeedOrder(_ a: Episode, _ b: Episode) -> Bool {
    let ad = a.pubDate ?? .distantPast, bd = b.pubDate ?? .distantPast
    if ad != bd { return ad > bd }
    if (a.seasonNumber ?? -1) != (b.seasonNumber ?? -1) { return (a.seasonNumber ?? -1) > (b.seasonNumber ?? -1) }
    if (a.episodeNumber ?? -1) != (b.episodeNumber ?? -1) { return (a.episodeNumber ?? -1) > (b.episodeNumber ?? -1) }
    if (a.feedItemIndex ?? Int.max) != (b.feedItemIndex ?? Int.max) { return (a.feedItemIndex ?? Int.max) < (b.feedItemIndex ?? Int.max) }
    return a.guid < b.guid
}

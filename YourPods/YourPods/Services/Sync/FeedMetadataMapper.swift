import Foundation

/// Assign only when the value actually differs.
///
/// Core Data marks a row dirty on ANY setter call — even assigning an identical
/// value. A refresh with no genuinely new data must commit ~0 rows, because
/// dirty-row volume is the 0xDEAD10CC blast radius.
///
/// Free-standing and `nonisolated` so BOTH the MainActor path (`PodcastManager`)
/// and the background path (`SyncStore`) reach the same guard. This previously
/// lived as a `private` method on `PodcastManager`, which `SyncStore` could not
/// call — so the live refresh path silently kept unguarded assigns.
nonisolated func setIfChanged<Root: AnyObject, Value: Equatable>(
    _ root: Root,
    _ keyPath: ReferenceWritableKeyPath<Root, Value>,
    _ newValue: Value
) {
    if root[keyPath: keyPath] != newValue {
        root[keyPath: keyPath] = newValue
    }
}

/// Strip query parameters from a URL string for base-path comparison.
///
/// Handles Megaphone's `?updated=TIMESTAMP` cache-busters and similar
/// query-param variations that change the URL without changing the content —
/// used by the stale-episode-matching fallback (GUID match first, audio-URL
/// base-path match second).
///
/// Free-standing and `nonisolated` for the same reason as `setIfChanged`:
/// reachable from both the MainActor path (`PodcastManager`) and the
/// background path (`SyncStore`). This previously existed as two hand-copied
/// twins — one `private` on `SyncStore` (the live caller) and one on
/// `PodcastManager` that lost its last caller when `applyFeedResult` was
/// deleted and was pinned only by tests. One implementation, reached by both.
nonisolated func stripQueryParams(_ urlString: String) -> String {
    guard var comps = URLComponents(string: urlString) else { return urlString }
    comps.query = nil
    comps.fragment = nil
    return comps.string ?? urlString
}

/// The single mapper from parsed feed data onto SwiftData models.
///
/// One implementation, reached by every refresh path. Do not fork it: the two
/// hand-copied twins this replaces drifted into two live bugs (unguarded assigns
/// and a never-set `feedItemIndex`) that the test suite could not see.
enum FeedMetadataMapper {

    /// Map RSS / iTunes 1.x / Podcasting 2.0 fields onto an Episode.
    nonisolated static func apply(_ parsed: ParsedEpisode, to episode: Episode) {
        setIfChanged(episode, \.seasonNumber, parsed.seasonNumber)
        setIfChanged(episode, \.seasonName, parsed.seasonName)
        setIfChanged(episode, \.episodeNumber, parsed.episodeNumber)
        setIfChanged(episode, \.episodeDisplay, parsed.episodeDisplay)
        setIfChanged(episode, \.episodeType, parsed.episodeType)
        setIfChanged(episode, \.explicit, parsed.explicit)
        // Feed document order — the episodesByFeedOrder tie-breaker. Belongs here,
        // not at the call sites: it must follow a feed that reorders its items.
        setIfChanged(episode, \.feedItemIndex, parsed.feedItemIndex)

        // Feeds may add these to existing episodes.
        if let transcriptUrl = parsed.transcriptUrl, !transcriptUrl.isEmpty {
            setIfChanged(episode, \.transcriptUrl, transcriptUrl)
            setIfChanged(episode, \.transcriptType, parsed.transcriptType)
        }
        if let chaptersUrl = parsed.chaptersUrl, !chaptersUrl.isEmpty {
            setIfChanged(episode, \.chaptersUrl, chaptersUrl)
        }

        // Encode Podlove inline chapters to JSON for persistence.
        if let chapters = parsed.inlineChapters, !chapters.isEmpty {
            struct InlineChapterData: Codable {
                let startTime: Double
                let title: String
                let img: String?
                let url: String?
            }
            let encoded = chapters.map {
                InlineChapterData(startTime: $0.startTime, title: $0.title, img: $0.image, url: $0.href)
            }
            if let data = try? JSONEncoder().encode(encoded) {
                setIfChanged(episode, \.chaptersJSON, String(data: data, encoding: .utf8))
            }
        }
    }

    /// Map RSS / iTunes 1.x / Podcasting 2.0 fields onto a Podcast.
    ///
    /// The `title`/`description`/`logoUrl`/`website`/`author` assigns that
    /// `SyncStore` did inline before calling this are folded in here and guarded —
    /// they were 5 of the 22 unguarded assigns per podcast row, per refresh.
    nonisolated static func apply(_ parsed: ParsedPodcast, to podcast: Podcast) {
        setIfChanged(podcast, \.title, parsed.title)
        setIfChanged(podcast, \.podcastDescription, parsed.description)
        setIfChanged(podcast, \.logoUrl, parsed.logoUrl)
        setIfChanged(podcast, \.website, parsed.website)
        setIfChanged(podcast, \.author, parsed.author)
        setIfChanged(podcast, \.language, parsed.language)
        setIfChanged(podcast, \.copyright, parsed.copyright)
        setIfChanged(podcast, \.categories, parsed.categories)
        setIfChanged(podcast, \.subcategory, parsed.subcategory)
        setIfChanged(podcast, \.explicit, parsed.explicit)
        setIfChanged(podcast, \.showType, parsed.showType)
        setIfChanged(podcast, \.isComplete, parsed.isComplete)
        setIfChanged(podcast, \.newFeedUrl, parsed.newFeedUrl)
        setIfChanged(podcast, \.podcastGuid, parsed.podcastGuid)
        setIfChanged(podcast, \.fundingUrl, parsed.fundingUrl)
        setIfChanged(podcast, \.fundingLabel, parsed.fundingLabel)
        setIfChanged(podcast, \.publisher, parsed.publisher)
        setIfChanged(podcast, \.supportsValue4Value, parsed.supportsValue4Value)
        setIfChanged(podcast, \.hasLiveItem, parsed.hasLiveItem)
        setIfChanged(podcast, \.liveItemStatus, parsed.liveItemStatus)
        setIfChanged(podcast, \.liveItemStart, parsed.liveItemStart)
        setIfChanged(podcast, \.liveItemContentLink, parsed.liveItemContentLink)
    }
}

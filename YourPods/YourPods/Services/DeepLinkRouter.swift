import Foundation
import os

/// Provider-agnostic feed data so the router is testable without RSSService.
struct ResolvedEpisode: Equatable, Sendable {
    let guid: String; let title: String; let audioUrl: String?
    let imageUrl: String?; let durationSeconds: Int?; let description: String?; let pubDate: Date?
}
struct ResolvedPodcast: Equatable, Sendable {
    let title: String; let author: String?; let logoUrl: String?; let description: String?
}

protocol FeedResolving {
    func resolveFeed(_ feedUrl: String) async -> (podcast: ResolvedPodcast, episodes: [ResolvedEpisode])?
}

/// What the router decided to present for a deep link.
enum DeepLinkOutcome: Equatable, Sendable {
    case knownEpisode(guid: String)
    case previewEpisode(SharedEpisode)
    case knownPodcast(feed: String)
    case previewPodcast(SharedPodcast)
    case failed
}

/// Resolves a `SharedLink` into a presentation outcome (known library item vs. transient preview).
struct DeepLinkRouter {
    let resolver: FeedResolving
    let isEpisodeKnown: (String) -> Bool   // guid → in a subscription?
    let isPodcastKnown: (String) -> Bool   // feed → subscribed?
    private var logger: Logger { Logger(subsystem: "com.yourpods", category: "share") }

    func resolve(_ link: SharedLink) async -> DeepLinkOutcome {
        switch link {
        case .episode(let feed, let guid, let audioUrl, let startSec):
            if let guid, isEpisodeKnown(guid) { return .knownEpisode(guid: guid) }
            guard let (podcast, episodes) = await resolver.resolveFeed(feed) else { return .failed }
            guard let ep = episodes.first(where: { (guid != nil && $0.guid == guid) || $0.audioUrl == audioUrl })
            else { logger.info("Deep link: episode not in feed"); return .failed }
            let shared = SharedEpisode(
                guid: ep.guid, title: ep.title, podcastTitle: podcast.title, podcastAuthor: podcast.author,
                audioUrl: ep.audioUrl ?? audioUrl ?? "", feedUrl: feed,
                artworkUrl: ep.imageUrl ?? podcast.logoUrl, durationSeconds: ep.durationSeconds,
                episodeDescription: ep.description, startSec: startSec, pubDate: ep.pubDate)
            return .previewEpisode(shared)

        case .podcast(let feed):
            if isPodcastKnown(feed) { return .knownPodcast(feed: feed) }
            guard let (podcast, _) = await resolver.resolveFeed(feed) else { return .failed }
            return .previewPodcast(SharedPodcast(
                feedUrl: feed, title: podcast.title, author: podcast.author,
                artworkUrl: podcast.logoUrl, podcastDescription: podcast.description))
        }
    }
}

/// Production adapter: bridges RSSService.fetchFeed → the router's resolved types.
struct RSSFeedResolver: FeedResolving {
    let rss: RSSService
    init(rss: RSSService = RSSService()) { self.rss = rss }
    func resolveFeed(_ feedUrl: String) async -> (podcast: ResolvedPodcast, episodes: [ResolvedEpisode])? {
        guard let result = try? await rss.fetchFeed(url: feedUrl) else { return nil }
        let podcast = ResolvedPodcast(title: result.podcast.title, author: result.podcast.author,
                                      logoUrl: result.podcast.logoUrl, description: result.podcast.description)
        let episodes = result.episodes.map {
            ResolvedEpisode(guid: $0.guid, title: $0.title, audioUrl: $0.audioUrl,
                            imageUrl: $0.imageUrl, durationSeconds: $0.durationSeconds,
                            description: $0.description, pubDate: $0.pubDate)
        }
        return (podcast, episodes)
    }
}

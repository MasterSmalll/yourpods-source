import XCTest
@testable import YourPods

final class DeepLinkRouterTests: XCTestCase {
    func test_episode_unknownToLibrary_buildsPreviewFromFeed() async {
        let resolver = FakeFeedResolver(episodes: [
            ResolvedEpisode(guid: "g1", title: "Ep 1", audioUrl: "https://cdn/ep.mp3",
                            imageUrl: "https://img/a.jpg", durationSeconds: 1800,
                            description: "d", pubDate: nil)],
            podcast: ResolvedPodcast(title: "Show", author: "Host", logoUrl: "https://img/p.jpg", description: "pd"))
        let router = DeepLinkRouter(resolver: resolver, isEpisodeKnown: { _ in false }, isPodcastKnown: { _ in false })

        let outcome = await router.resolve(.episode(feed: "https://f/show.xml", guid: "g1", audioUrl: "https://cdn/ep.mp3", startSec: 342))
        guard case .previewEpisode(let shared) = outcome else { return XCTFail("expected preview") }
        XCTAssertEqual(shared.guid, "g1"); XCTAssertEqual(shared.title, "Ep 1"); XCTAssertEqual(shared.startSec, 342)
    }

    func test_episode_known_routesToLibraryEpisode() async {
        let resolver = FakeFeedResolver(episodes: [], podcast: nil)
        let router = DeepLinkRouter(resolver: resolver, isEpisodeKnown: { $0 == "g1" }, isPodcastKnown: { _ in false })
        let outcome = await router.resolve(.episode(feed: "f", guid: "g1", audioUrl: "u", startSec: nil))
        XCTAssertEqual(outcome, .knownEpisode(guid: "g1"))
    }

    func test_episode_notInFeed_isFailure() async {
        let resolver = FakeFeedResolver(episodes: [], podcast: ResolvedPodcast(title: "Show", author: nil, logoUrl: nil, description: nil))
        let router = DeepLinkRouter(resolver: resolver, isEpisodeKnown: { _ in false }, isPodcastKnown: { _ in false })
        let outcome = await router.resolve(.episode(feed: "f", guid: "missing", audioUrl: "u", startSec: nil))
        XCTAssertEqual(outcome, .failed)
    }

    func test_podcast_notFound_buildsPreview() async {
        let resolver = FakeFeedResolver(episodes: [], podcast: ResolvedPodcast(title: "Show", author: "Host", logoUrl: "https://img/p.jpg", description: "pd"))
        let router = DeepLinkRouter(resolver: resolver, isEpisodeKnown: { _ in false }, isPodcastKnown: { _ in false })
        let outcome = await router.resolve(.podcast(feed: "https://f/show.xml"))
        guard case .previewPodcast(let shared) = outcome else { return XCTFail("expected preview") }
        XCTAssertEqual(shared.title, "Show")
    }
}

struct FakeFeedResolver: FeedResolving {
    let episodes: [ResolvedEpisode]
    let podcast: ResolvedPodcast?
    func resolveFeed(_ feedUrl: String) async -> (podcast: ResolvedPodcast, episodes: [ResolvedEpisode])? {
        guard let podcast else { return nil }
        return (podcast, episodes)
    }
}

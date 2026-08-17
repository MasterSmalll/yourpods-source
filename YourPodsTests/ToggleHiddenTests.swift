import XCTest
import SwiftData
@testable import YourPods

// MARK: - Toggle Hidden (Centralized) Tests

/// Tests for PodcastManager.toggleHidden(episode:) — the single entry point
/// for hide/unhide that replaces duplicated logic across views.
///
/// toggleHidden should:
/// 1. Toggle local hidden state via episodeActionSync
/// 2. Sync to server if a sync client is available (Pro users)
/// 3. Work safely without a sync client (non-Pro / local-only)
@MainActor
final class ToggleHiddenTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
        podcastManager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    /// Helper: create a podcast with episodes inserted into context.
    private func makePodcastWithEpisodes(count: Int) -> (Podcast, [Episode]) {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        var episodes: [Episode] = []
        for i in 0..<count {
            let ep = Episode(
                guid: "ep-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep-\(i).mp3",
                pubDate: Calendar.current.date(byAdding: .day, value: -i, to: Date())
            )
            ep.podcast = podcast
            episodes.append(ep)
        }
        podcast.episodes = episodes
        context.insert(podcast)
        for ep in episodes { context.insert(ep) }
        podcastManager.subscriptions = [podcast]
        return (podcast, episodes)
    }

    // MARK: - Single Episode Toggle

    func test_toggleHidden_hidesUnhiddenEpisode() {
        let (_, episodes) = makePodcastWithEpisodes(count: 1)
        let episode = episodes[0]

        XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episode.guid),
                       "Precondition: episode starts unhidden")

        podcastManager.toggleHidden(episode: episode)

        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episode.guid),
                      "Episode should be hidden after toggle")
        XCTAssertTrue(episode.isPlayed,
                      "Hidden episode should be marked as played")
    }

    func test_toggleHidden_unhidesHiddenEpisode() {
        let (_, episodes) = makePodcastWithEpisodes(count: 1)
        let episode = episodes[0]

        // Hide first
        podcastManager.toggleHidden(episode: episode)
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episode.guid),
                      "Precondition: episode is hidden")

        // Toggle again — should unhide
        podcastManager.toggleHidden(episode: episode)

        XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episode.guid),
                       "Episode should be unhidden after second toggle")
        XCTAssertFalse(episode.isPlayed,
                       "Unhidden episode should be marked as unplayed")
    }

    func test_toggleHidden_roundTrip() {
        let (_, episodes) = makePodcastWithEpisodes(count: 1)
        let episode = episodes[0]

        // hide → unhide → hide
        podcastManager.toggleHidden(episode: episode)
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episode.guid))

        podcastManager.toggleHidden(episode: episode)
        XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episode.guid))

        podcastManager.toggleHidden(episode: episode)
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episode.guid))
    }

    // MARK: - No Crash Without Sync Client

    func test_toggleHidden_noSyncClient_doesNotCrash() {
        let (_, episodes) = makePodcastWithEpisodes(count: 1)
        let episode = episodes[0]

        // PodcastManager has no sync client by default in tests
        podcastManager.toggleHidden(episode: episode)
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episode.guid),
                      "Local hide should work without a sync client")
    }

    // MARK: - Batch Hide

    func test_hideEpisodes_hidesBatch() {
        let (_, episodes) = makePodcastWithEpisodes(count: 5)

        let toHide = Array(episodes[2..<5])  // ep-2, ep-3, ep-4
        podcastManager.hideEpisodes(toHide)

        for ep in toHide {
            XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: ep.guid),
                          "\(ep.guid) should be hidden")
            XCTAssertTrue(ep.isPlayed,
                          "\(ep.guid) should be marked as played")
        }

        // ep-0, ep-1 should remain unhidden
        for i in 0..<2 {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episodes[i].guid),
                           "\(episodes[i].guid) should remain unhidden")
        }
    }

    func test_hideEpisodes_emptyArray_doesNothing() {
        let (_, _) = makePodcastWithEpisodes(count: 1)
        // Should not crash or throw
        podcastManager.hideEpisodes([])
    }
}

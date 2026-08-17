import XCTest
import SwiftData
@testable import YourPods

/// Plan 3 — gpodder/Pinepods: stop re-adding removed episodes.
///
/// gpodder servers have no queue API, so Up Next is purely local. On every refresh
/// `autoQueueExistingEpisodes` re-queues the newest non-interacted candidate per
/// subscription. Remove-only previously set none of the suppression flags, so removed
/// episodes returned. The fix routes remove-only through `PlayerManager.removeFromQueue`
/// (and friends), which marks the episode durably interacted (NOT played) so
/// `getAutoQueueCandidates` no longer offers it.
@MainActor
final class AutoQueueRemoveOnlyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private let profileId = "test-profile-remove-only"
    private let feedUrl = "https://example.com/feed.xml"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_\(profileId)")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(profileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        settingsManager = SettingsManager()
        playerManager.settingsManager = settingsManager
        manager.settingsManager = settingsManager
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func insertSubscribedPodcast(episodeCount: Int = 1) -> Podcast {
        let podcast = Podcast(url: feedUrl, title: "Test Podcast")
        context.insert(podcast)
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep-\(i).mp3",
                pubDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)),
                durationSeconds: 3600
            )
            ep.podcast = podcast
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: feedUrl)
        manager.loadSubscriptions()
        return podcast
    }

    private func makeQueueItem(guid: String, podcastUrl: String) -> QueueItem {
        QueueItem(
            id: guid,
            title: "Episode",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(guid).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    private func episode(_ guid: String, in pod: Podcast) -> Episode {
        pod.episodes.first { $0.guid == guid }!
    }

    // MARK: - Chokepoint marks interacted

    func test_removeOnly_marksInteracted_soAutoQueueDoesNotReAdd() {
        let pod = insertSubscribedPodcast(episodeCount: 1)
        XCTAssertTrue(
            manager.getAutoQueueCandidates(for: pod, globalDefault: .priority).contains { $0.guid == "ep-1" },
            "ep-1 should start as an auto-queue candidate"
        )

        playerManager.removeFromQueue(makeQueueItem(guid: "ep-1", podcastUrl: pod.url))

        let ep = episode("ep-1", in: pod)
        XCTAssertTrue(ep.isInteracted, "remove-only must mark interacted")
        XCTAssertFalse(ep.isPlayed, "remove-only must NOT mark played")
        XCTAssertFalse(
            manager.getAutoQueueCandidates(for: pod, globalDefault: .priority).contains { $0.guid == "ep-1" },
            "removed episode must no longer be an auto-queue candidate"
        )
    }

    // MARK: - Watch remove path routes through the chokepoint

    func test_watchRemovePath_marksInteracted() {
        let pod = insertSubscribedPodcast(episodeCount: 1)
        let item = makeQueueItem(guid: "ep-1", podcastUrl: pod.url)
        audioManager.appendToQueue([item])

        playerManager.removeFromQueue(audioManager.queue.first { $0.id == "ep-1" }!)

        XCTAssertTrue(audioManager.queue.isEmpty)
        XCTAssertTrue(episode("ep-1", in: pod).isInteracted)
    }

    // MARK: - clearAllQueue remove-only marks all interacted

    func test_clearAllQueue_removeOnly_marksAllInteracted() {
        let pod = insertSubscribedPodcast(episodeCount: 2)
        settingsManager.queueRemovalAction = .removeOnly
        audioManager.currentItem = makeQueueItem(guid: "ep-1", podcastUrl: pod.url)
        audioManager.appendToQueue([makeQueueItem(guid: "ep-2", podcastUrl: pod.url)])

        playerManager.clearAllQueue()

        XCTAssertTrue(episode("ep-1", in: pod).isInteracted)
        XCTAssertTrue(episode("ep-2", in: pod).isInteracted)
        XCTAssertFalse(episode("ep-1", in: pod).isPlayed)
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// Adopting the server's playback state means adopting **all** of it, per the sync contract.
///
/// `PlaybackSyncCoordinator` deliberately emits decisions as data rather than effects, so
/// the hard part — deciding — is assertable without a network, a store or an `AVPlayer`.
/// `Adopt` carries `position` **and** `completed`. `applyPlaybackAdopt` took the position
/// and dropped the flag on the floor.
///
/// The reconciler had already done the work: it decided this device should take the
/// server's state, recorded the agreement at that version, and said whether that state is
/// finished. Discarding half of it leaves the device holding a position it agreed to and a
/// completion it did not — and the baseline says the two sides agree, so nothing later
/// re-raises it. Silent, and self-consistent enough to stay silent.
///
/// Until the sync contract's completion authority was enforced this was partly masked: the
/// position heuristic re-marked anything past 95% played, so an adopted `completed: true`
/// near the end appeared to work. That crutch is gone on Pro, which is exactly why the flag
/// has to travel now.
@MainActor
final class AdoptedCompletionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!

    private let testProfileId = "test-adopted-completion"
    private let feedUrl = "https://example.com/feed-adopt"
    private let epUrl = "https://cdn.example.com/adopt-ep.mp3"
    private let epGuid = "adopt-guid-1"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        podcastManager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
    }

    override func tearDown() {
        clearTestDefaults()
        playerManager = nil
        audioManager = nil
        podcastManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "subscriptionUrls_\(testProfileId)",
                    "episodeActionMap", "savedQueue", "savedCurrentItem", "savedCurrentPosition"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedEpisode(isPlayed: Bool) -> Episode {
        let podcast = Podcast(url: feedUrl, title: "Adopt Show")
        context.insert(podcast)
        let episode = Episode(
            guid: epGuid,
            title: "Adopt Episode",
            audioUrl: epUrl,
            pubDate: Date(),
            durationSeconds: 2280,
            podcast: podcast
        )
        episode.isPlayed = isPlayed
        context.insert(episode)
        try! context.save()
        // The local-only mark helpers walk `subscriptions`; without the association and the
        // load they find nothing and every assertion here passes for the wrong reason.
        podcastManager.associateWithCurrentProfile(url: feedUrl)
        podcastManager.loadSubscriptions()
        return episode
    }

    private func loadPlayingItem() {
        audioManager.currentItem = QueueItem(
            id: epGuid, title: "Adopt Episode", podcastTitle: "Adopt Show",
            audioUrl: epUrl, artworkUrl: nil,
            durationSeconds: 2280, positionSeconds: 100,
            podcastUrl: feedUrl, pubDate: nil
        )
    }

    // MARK: - The defect

    func test_adopt_completedTrue_marksTheEpisodePlayed() {
        let episode = seedEpisode(isPlayed: false)
        loadPlayingItem()

        playerManager.applyPlaybackAdopt(.init(episodeUrl: epUrl, position: 2280, completed: true))

        XCTAssertTrue(
            episode.isPlayed,
            "the reconciler decided to take the server's state and said that state is finished; "
            + "taking half of it leaves a position this device agreed to and a completion it did not"
        )
    }

    /// The direction that has no crutch left. Since the sync contract stopped the position
    /// heuristic on Pro, nothing else will clear a stale `isPlayed` for an episode the
    /// server reports as unfinished.
    func test_adopt_completedFalse_unmarksAPlayedEpisode() {
        let episode = seedEpisode(isPlayed: true)
        loadPlayingItem()

        playerManager.applyPlaybackAdopt(.init(episodeUrl: epUrl, position: 1200, completed: false))

        XCTAssertFalse(episode.isPlayed,
                       "adopting an unfinished server state left the episode marked played")
    }

    /// The position half must keep working exactly as it did.
    func test_adopt_stillAdoptsThePosition() {
        seedEpisode(isPlayed: false)
        loadPlayingItem()

        playerManager.applyPlaybackAdopt(.init(episodeUrl: epUrl, position: 1234, completed: false))

        XCTAssertEqual(audioManager.currentPosition, 1234, accuracy: 0.5)
    }

    /// Existing guard: the loaded episode can change while a push is in flight, and an
    /// adopt aimed at the previous one must not land on whatever is playing now.
    func test_adopt_forADifferentEpisode_changesNothing() {
        let episode = seedEpisode(isPlayed: false)
        loadPlayingItem()

        playerManager.applyPlaybackAdopt(.init(
            episodeUrl: "https://cdn.example.com/some-other.mp3", position: 2280, completed: true
        ))

        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(audioManager.currentPosition, 0, accuracy: 0.5,
                       "an adopt for an episode that is not loaded must not move the playhead")
    }

    /// No local episode row (queue-only, or unsubscribed mid-flight): the position still
    /// lands and nothing throws. The completion simply has nowhere to go.
    func test_adopt_withNoLocalEpisode_stillAdoptsPositionAndDoesNotCrash() {
        loadPlayingItem()   // deliberately no seedEpisode

        playerManager.applyPlaybackAdopt(.init(episodeUrl: epUrl, position: 900, completed: true))

        XCTAssertEqual(audioManager.currentPosition, 900, accuracy: 0.5)
    }
}

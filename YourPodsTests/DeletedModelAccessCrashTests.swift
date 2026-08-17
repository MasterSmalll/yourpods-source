import XCTest
import SwiftData
@testable import YourPods

/// Crash class: reading a `@Persisted` property on a SwiftData model that has been
/// deleted traps in `_FullFutureBackingData.getValue` — an uncatchable
/// `_assertionFailure`, not a Swift error.
///
/// Shipped crash (2.0.4, EXC_BREAKPOINT SIGTRAP):
/// ```
/// _assertionFailure
/// _FullFutureBackingData.getValue<A>(forKey:)
/// PersistentModel.getValue<A>(forKey:)
/// Episode.guid.getter
/// EpisodeActionSyncService.applyActionsForPodcast   ← reads episode.guid unguarded
/// EpisodeActionSyncService.applyEpisodeActionsCore
/// YourPodsApp.performStartupSave()
/// ```
///
/// Trigger: `SyncStore.deletePodcasts` (a background actor) cascade-deletes Podcasts and
/// their Episodes during the subscription-delta step, while the main context is still
/// holding those same models and iterating `podcast.episodes` in the episode-action step
/// of the SAME sync cycle (`PodcastManager.swift` → `syncStore.deletePodcasts(urls:)`).
///
/// `Podcast.effectiveSettings` already documents and guards this exact hazard
/// (`guard modelContext != nil, !isDeleted`). The episode-action path never did — these
/// tests pin the guard there. Beyond the crash, applying server sync state to a model
/// that is on its way out of the store is wrong on its own terms.
@MainActor
final class DeletedModelAccessCrashTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let testProfileId = "test-deleted-model"

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeService(podcasts: [Podcast]) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { podcasts },
            syncClientProvider: { nil },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: { true }
        )
    }

    /// One podcast with one episode, already persisted.
    @discardableResult
    private func insertPodcastWithEpisode(
        feed: String,
        guid: String
    ) -> (podcast: Podcast, episode: Episode) {
        let podcast = Podcast(url: feed, title: "Test Pod")
        let episode = Episode(
            guid: guid,
            title: "Ep 1",
            audioUrl: "\(feed)/\(guid).mp3",
            durationSeconds: 3600
        )
        episode.podcast = podcast
        podcast.episodes.append(episode)
        context.insert(podcast)
        try! context.save()
        return (podcast, episode)
    }

    /// A server-originated play action far ahead of the local position, so that
    /// `.serverWins` would definitely mutate the episode if it were reached.
    private func seedServerAction(
        on service: EpisodeActionSyncService,
        podcast: Podcast,
        guid: String,
        audioUrl: String,
        position: Int = 600
    ) {
        service.sendActionLocally(
            EpisodeAction(
                podcast: podcast.url,
                episode: audioUrl,
                guid: guid,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: position,
                started: 0,
                total: 3600,
                device: "other-device"
            )
        )
    }

    // MARK: - EDGE: episode deleted mid-cycle

    /// The episode itself is deleted (the cascade victim) while the action apply
    /// still walks `podcast.episodes`.
    func test_applyEpisodeActions_doesNotMutateEpisodeDeletedMidCycle() {
        let (podcast, episode) = insertPodcastWithEpisode(
            feed: "https://example.com/deleted-episode",
            guid: "ep-deleted-1"
        )
        let audioUrl = episode.audioUrl!
        let service = makeService(podcasts: [podcast])
        seedServerAction(on: service, podcast: podcast, guid: "ep-deleted-1", audioUrl: audioUrl)

        // Background subs-delta cascade lands mid-cycle.
        context.delete(episode)

        let (_, updated) = service.applyEpisodeActionsWithStats(strategy: .serverWins)

        XCTAssertEqual(
            updated, 0,
            "A deleted Episode must be skipped — reading its @Persisted properties traps in _FullFutureBackingData.getValue"
        )
    }

    // MARK: - EDGE: podcast deleted mid-cycle (SyncStore.deletePodcasts shape)

    /// Exactly the production shape: `SyncStore.deletePodcasts` deletes the *Podcast*,
    /// and SwiftData cascades to its Episodes.
    func test_applyEpisodeActions_doesNotMutateEpisodesOfPodcastDeletedMidCycle() {
        let (podcast, episode) = insertPodcastWithEpisode(
            feed: "https://example.com/deleted-podcast",
            guid: "ep-deleted-2"
        )
        let audioUrl = episode.audioUrl!
        let service = makeService(podcasts: [podcast])
        seedServerAction(on: service, podcast: podcast, guid: "ep-deleted-2", audioUrl: audioUrl)

        // SyncStore.deletePodcasts(urls:) — server-initiated unsubscribe, background actor.
        context.delete(podcast)

        let (_, updated) = service.applyEpisodeActionsWithStats(strategy: .serverWins)

        XCTAssertEqual(
            updated, 0,
            "Episodes of a deleted Podcast must be skipped — the cascade invalidates their backing data"
        )
    }

    // MARK: - EDGE: the shared lookup index has the same exposure

    /// `buildEpisodeIndex()` walks `podcast.episodes` and reads `guid` / `audioUrl` for
    /// every episode of every subscription, and runs in the same cycle right after the
    /// subs delta (`syncEpisodeActions`, `setHidden`). Guarding only the apply loop would
    /// relocate the trap here rather than remove it.
    func test_buildEpisodeIndex_excludesDeletedModels() {
        let (podcast, episode) = insertPodcastWithEpisode(
            feed: "https://example.com/index-podcast",
            guid: "ep-index-1"
        )
        let service = makeService(podcasts: [podcast])

        context.delete(episode)

        let index = service.buildEpisodeIndex()

        XCTAssertNil(index.byGuid["ep-index-1"], "a deleted episode must not enter the index")
        XCTAssertNil(index.byGuidCaseInsensitive["ep-index-1"], "nor the case-insensitive index")
        XCTAssertTrue(index.byAudioUrl.isEmpty, "nor the audio-URL index")
    }

    /// A live episode must still be indexed — the guard must not over-reject.
    func test_buildEpisodeIndex_stillIndexesLiveEpisodes() {
        let (podcast, _) = insertPodcastWithEpisode(
            feed: "https://example.com/index-live",
            guid: "ep-index-live"
        )
        let service = makeService(podcasts: [podcast])

        let index = service.buildEpisodeIndex()

        XCTAssertNotNil(index.byGuid["ep-index-live"], "a live episode must still be indexed")
    }

    // MARK: - Live episodes still apply (guard must not over-reject)

    /// The guard must skip only deleted models. A normal episode in a live podcast
    /// still takes the server position, or the fix would silently break sync.
    func test_applyEpisodeActions_stillAppliesToLiveEpisodes() {
        let (podcast, episode) = insertPodcastWithEpisode(
            feed: "https://example.com/live-podcast",
            guid: "ep-live-1"
        )
        let audioUrl = episode.audioUrl!
        let service = makeService(podcasts: [podcast])
        seedServerAction(on: service, podcast: podcast, guid: "ep-live-1", audioUrl: audioUrl)

        let (_, updated) = service.applyEpisodeActionsWithStats(strategy: .serverWins)

        XCTAssertEqual(updated, 1, "A live episode must still receive the server position")
        XCTAssertEqual(episode.listenedSeconds, 600)
    }
}

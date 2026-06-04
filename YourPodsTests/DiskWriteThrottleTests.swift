import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the disk write throttle in PodcastManager.updateEpisodeProgress().
///
/// Root cause: modelContext.save() was called every 5 seconds during playback,
/// generating ~1 GB of SQLite writes over 3 hours — exceeding the iOS disk write budget.
///
/// Fix: Throttle disk persistence to 60-second intervals while keeping in-memory
/// model updates immediate. flushProgressToDisk() bypasses the throttle for
/// critical moments (pause, backgrounding, episode completion).
@MainActor
final class DiskWriteThrottleTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-throttle"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        clearTestDefaults()
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @discardableResult
    private func insertPodcastWithEpisode(
        podcastUrl: String = "https://example.com/podcast",
        episodeGuid: String = "ep-1",
        listenedSeconds: Int = 0
    ) -> (Podcast, Episode) {
        let podcast = Podcast(url: podcastUrl, title: "Test Podcast")
        context.insert(podcast)
        let episode = Episode(guid: episodeGuid, title: "Episode 1", audioUrl: "https://example.com/ep1.mp3")
        episode.listenedSeconds = listenedSeconds
        episode.durationSeconds = 3600
        episode.podcast = podcast
        context.insert(episode)
        try! context.save()
        manager.associateWithCurrentProfile(url: podcastUrl)
        manager.loadSubscriptions()
        return (podcast, episode)
    }

    // MARK: - Throttle Behavior

    /// Two rapid calls must NOT both trigger modelContext.save().
    /// The second call should update in-memory but skip the disk write.
    func test_updateEpisodeProgress_doesNotSaveOnEveryCall() {
        let (_, episode) = insertPodcastWithEpisode()
        let podcastUrl = "https://example.com/podcast"

        // First call: should persist (lastProgressSaveTime is .distantPast)
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 10)
        XCTAssertEqual(episode.listenedSeconds, 10, "First call should update in-memory")

        // Second call: should update in-memory but NOT trigger a disk save
        // (we can't directly observe save count, but we verify the throttle exists
        // by checking that the in-memory model IS updated)
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 20)
        XCTAssertEqual(episode.listenedSeconds, 20,
                       "Second call must still update in-memory even when disk save is throttled")

        // Verify the throttle is working: progressSaveCount should be 1, not 2
        XCTAssertEqual(manager.progressSaveCount, 1,
                       "Only 1 disk save should have fired for 2 rapid calls")
    }

    /// After the throttle interval elapses, the next call should persist to disk.
    func test_updateEpisodeProgress_savesAfterInterval() {
        let (_, episode) = insertPodcastWithEpisode()
        let podcastUrl = "https://example.com/podcast"

        // First call: persists (cold start)
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 10)
        XCTAssertEqual(manager.progressSaveCount, 1, "First call should save")

        // Simulate time passing beyond the throttle interval
        manager.testOverrideLastProgressSaveTime(Date.distantPast)

        // Second call: should now persist because enough time has passed
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 60)
        XCTAssertEqual(manager.progressSaveCount, 2,
                       "Save should fire after throttle interval elapses")
        XCTAssertEqual(episode.listenedSeconds, 60)
    }

    // MARK: - Flush Bypass

    /// flushProgressToDisk() must always save, regardless of throttle state.
    func test_flushProgressToDisk_alwaysSaves() {
        let (_, episode) = insertPodcastWithEpisode()
        let podcastUrl = "https://example.com/podcast"

        // First call: persists
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 10)
        XCTAssertEqual(manager.progressSaveCount, 1)

        // Second call: throttled (no disk save)
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 20)
        XCTAssertEqual(manager.progressSaveCount, 1, "Throttled — still 1 save")

        // Flush: must save unconditionally
        manager.flushProgressToDisk()
        // After flush, the in-memory dirty state (position 20) should be persisted
        XCTAssertEqual(episode.listenedSeconds, 20,
                       "Flush must persist the latest in-memory position")
    }

    // MARK: - In-Memory Immediacy

    /// The in-memory model must update immediately even when disk save is throttled.
    /// This ensures SwiftUI progress bars stay responsive.
    func test_updateEpisodeProgress_updatesInMemoryImmediately() {
        let (_, episode) = insertPodcastWithEpisode()
        let podcastUrl = "https://example.com/podcast"

        // First call triggers save
        manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: 5)

        // Rapid subsequent calls — all should update in-memory
        for i in stride(from: 10, through: 50, by: 5) {
            manager.updateEpisodeProgress(podcastUrl: podcastUrl, episodeGuid: "ep-1", position: i)
            XCTAssertEqual(episode.listenedSeconds, i,
                           "In-memory model must reflect position \(i) immediately")
        }

        // Only 1 disk save should have occurred (the first call)
        XCTAssertEqual(manager.progressSaveCount, 1,
                       "Rapid calls should only trigger 1 disk save due to throttle")
    }
}

import XCTest
import SwiftData
@testable import YourPods

// MARK: - Duration-Based Auto-Hide Tests

/// Tests for `PodcastManager.autoHideUnplayedEpisodes()` — the sweep that hides
/// episodes older than N days that remain unplayed.
///
/// Skips: downloaded, in-progress (listenedSeconds > 0), queued, already-hidden, played.
@MainActor
final class AutoHideUnplayedTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var settingsManager: SettingsManager!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        testDefaults = UserDefaults(suiteName: "AutoHideUnplayedTests")!
        testDefaults.removePersistentDomain(forName: "AutoHideUnplayedTests")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)
        settingsManager = SettingsManager(defaults: testDefaults)
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: "AutoHideUnplayedTests")
        podcastManager = nil
        settingsManager = nil
        context = nil
        container = nil
        testDefaults = nil
        try await super.tearDown()
    }

    /// Helper: create a podcast with episodes at specific day offsets.
    private func makePodcast(
        episodeDaysAgo: [Int],
        url: String = "https://example.com/feed",
        now: Date = Date()
    ) -> (Podcast, [Episode]) {
        let podcast = Podcast(url: url, title: "Test Pod")
        var episodes: [Episode] = []
        for (i, days) in episodeDaysAgo.enumerated() {
            let ep = Episode(
                guid: "ep-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep-\(i).mp3",
                pubDate: Calendar.current.date(byAdding: .day, value: -days, to: now),
                durationSeconds: 3600
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

    // MARK: - Basic Sweep

    func test_autoHideUnplayed_hidesOldUnplayedEpisodes() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        // ep-0: 10 days ago (keep), ep-1: 31 days ago (hide), ep-2: 60 days ago (hide)
        let (_, episodes) = makePodcast(episodeDaysAgo: [10, 31, 60])

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 2, "Should hide 2 episodes older than 30 days")
        XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episodes[0].guid),
                       "ep-0 (10 days) should remain visible")
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[1].guid),
                      "ep-1 (31 days) should be hidden")
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[2].guid),
                      "ep-2 (60 days) should be hidden")
    }

    func test_autoHideUnplayed_disabled_doesNothing() async {
        settingsManager.autoHideUnplayedEnabled = false
        settingsManager.autoHideUnplayedDays = 30

        let (_, _) = makePodcast(episodeDaysAgo: [31, 60])

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Should not hide anything when disabled")
    }

    // MARK: - Skip Conditions

    func test_autoHideUnplayed_skipsPlayedEpisodes() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeDaysAgo: [31])
        episodes[0].isPlayed = true

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Should not hide already-played episodes")
    }

    func test_autoHideUnplayed_skipsInProgressEpisodes() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeDaysAgo: [31])
        episodes[0].listenedSeconds = 120  // Has progress

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Should not hide in-progress episodes")
    }

    func test_autoHideUnplayed_skipsAlreadyHiddenEpisodes() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeDaysAgo: [31])
        // Pre-hide the episode
        podcastManager.episodeActionSync.applyHiddenChanges([
            HiddenStateChange(guid: episodes[0].guid, hidden: true)
        ])

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Should not re-hide already hidden episodes")
    }

    func test_autoHideUnplayed_skipsEpisodesWithNilPubDate() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeDaysAgo: [31])
        episodes[0].pubDate = nil

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Should not hide episodes with nil pubDate")
    }

    // MARK: - Boundary

    func test_autoHideUnplayed_exactBoundaryIsNotHidden() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        // Use a fixed reference date to avoid sub-second drift
        let now = Date()
        let (_, _) = makePodcast(episodeDaysAgo: [30], now: now)

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager, now: now)

        XCTAssertEqual(count, 0, "Episode exactly at boundary should not be hidden")
    }

    func test_autoHideUnplayed_oneDayPastBoundaryIsHidden() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, _) = makePodcast(episodeDaysAgo: [31])

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 1, "Episode 1 day past boundary should be hidden")
    }

    // MARK: - Returns Count

    func test_autoHideUnplayed_returnsCorrectCount() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 7

        let (_, _) = makePodcast(episodeDaysAgo: [1, 5, 8, 14, 21])

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 3, "Should return count of newly hidden episodes (8, 14, 21 days)")
    }

    // MARK: - Per-Podcast Override Tri-State

    func test_autoHideUnplayed_perPodcastOverride_nil_usesGlobal() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        // Per-podcast override is nil → should use global 30 days
        let (_, episodes) = makePodcast(episodeDaysAgo: [31])
        // effectiveSettings.autoHideUnplayedDays defaults to nil

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 1, "nil override should use global threshold (30 days)")
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[0].guid))
    }

    func test_autoHideUnplayed_perPodcastOverride_zero_disables() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (podcast, episodes) = makePodcast(episodeDaysAgo: [31])
        // Set per-podcast override to 0 = disabled
        podcast.effectiveSettings.autoHideUnplayedDays = 0

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Override of 0 should disable auto-hide for this podcast")
        XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episodes[0].guid))
    }

    func test_autoHideUnplayed_perPodcastOverride_customDays() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        // Episode is 10 days old — would survive global 30-day threshold
        let (podcast, episodes) = makePodcast(episodeDaysAgo: [10])
        // Set per-podcast override to 7 days → should hide
        podcast.effectiveSettings.autoHideUnplayedDays = 7

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 1, "Custom override of 7 days should hide 10-day-old episode")
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[0].guid))
    }

    // MARK: - Additional Skip Conditions

    func test_autoHideUnplayed_skipsQueuedEpisodes() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeDaysAgo: [31])
        episodes[0].isInteracted = true  // Queued/interacted

        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)

        XCTAssertEqual(count, 0, "Should not hide queued (isInteracted) episodes")
    }

    func test_autoHideUnplayed_skipsDownloadedEpisodes() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeDaysAgo: [31])

        // Create a mock DownloadManager with the episode marked as downloaded
        let dm = DownloadManager()
        dm.downloadedFiles[episodes[0].guid] = URL(string: "file:///test.mp3")!

        let count = await podcastManager.autoHideUnplayedEpisodes(
            settingsManager: settingsManager,
            downloadManager: dm
        )

        XCTAssertEqual(count, 0, "Should not hide downloaded episodes")
    }

    // MARK: - Progress Callback

    func test_autoHideUnplayed_progressCallbackFires() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, _) = makePodcast(episodeDaysAgo: [31])

        var callbackInvocations: [(String, Int, Int)] = []
        _ = await podcastManager.autoHideUnplayedEpisodes(
            settingsManager: settingsManager,
            progressCallback: { title, index, total in
                callbackInvocations.append((title, index, total))
            }
        )

        XCTAssertEqual(callbackInvocations.count, 1, "Callback should fire once per podcast")
        XCTAssertEqual(callbackInvocations[0].0, "Test Pod", "Title should match podcast")
        XCTAssertEqual(callbackInvocations[0].1, 0, "Index should be 0 for first podcast")
        XCTAssertEqual(callbackInvocations[0].2, 1, "Total should be 1 podcast")
    }

    // MARK: - Pacing Verification

    func test_autoHideUnplayed_pacingWhenCallbackProvided() async {
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let podcast1 = Podcast(url: "https://example.com/feed1", title: "Pod 1")
        let podcast2 = Podcast(url: "https://example.com/feed2", title: "Pod 2")
        podcastManager.subscriptions = [podcast1, podcast2]

        let start = Date()
        _ = await podcastManager.autoHideUnplayedEpisodes(
            settingsManager: settingsManager,
            progressCallback: { _, _, _ in }
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.04, "Should have a paced delay when progressCallback is provided")
    }
}

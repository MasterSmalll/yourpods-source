import XCTest
import SwiftData
@testable import YourPods

// MARK: - Auto-Hide Log Tests

/// Tests for the auto-hide log infrastructure:
/// - `recordAutoHideLog` records episodes keyed by podcast URL
/// - `undoAutoHide` restores all guids for a podcast
/// - 30-day expiry prunes old entries
@MainActor
final class AutoHideLogTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        testDefaults = UserDefaults(suiteName: "AutoHideLogTests")!
        testDefaults.removePersistentDomain(forName: "AutoHideLogTests")
        UserDefaults.standard.removeObject(forKey: "autoHideLog")
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "autoHideLog")
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        testDefaults.removePersistentDomain(forName: "AutoHideLogTests")
        podcastManager = nil
        context = nil
        container = nil
        testDefaults = nil
        try await super.tearDown()
    }

    private func makePodcast(
        url: String = "https://example.com/feed",
        episodeCount: Int
    ) -> (Podcast, [Episode]) {
        let podcast = Podcast(url: url, title: "Test Pod")
        var episodes: [Episode] = []
        for i in 0..<episodeCount {
            let ep = Episode(
                guid: "ep-\(url)-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep-\(i).mp3",
                pubDate: Calendar.current.date(byAdding: .day, value: -(31 + i), to: Date()),
                durationSeconds: 3600
            )
            ep.podcast = podcast
            episodes.append(ep)
        }
        podcast.episodes = episodes
        context.insert(podcast)
        for ep in episodes { context.insert(ep) }
        return (podcast, episodes)
    }

    // MARK: - Log Recording

    func test_autoHideSweep_recordsLogEntries() async {
        let settingsManager = SettingsManager(defaults: testDefaults)
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (podcast, _) = makePodcast(episodeCount: 3)
        podcastManager.subscriptions = [podcast]

        // Sweep — all 3 episodes are 31+ days old
        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)
        XCTAssertEqual(count, 3)

        let log = podcastManager.loadAutoHideLog()
        XCTAssertEqual(log.count, 1, "Should have 1 podcast entry")
        let entry = log["https://example.com/feed"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.count, 3, "Should record 3 auto-hidden episodes")
        XCTAssertEqual(entry?.guids.count, 3)
    }

    func test_emptyLog_returnsEmptyDictionary() {
        let log = podcastManager.loadAutoHideLog()
        XCTAssertTrue(log.isEmpty)
    }

    // MARK: - Undo

    func test_undoAutoHide_restoresHiddenEpisodes() async {
        let settingsManager = SettingsManager(defaults: testDefaults)
        settingsManager.autoHideUnplayedEnabled = true
        settingsManager.autoHideUnplayedDays = 30

        let (_, episodes) = makePodcast(episodeCount: 2)
        podcastManager.subscriptions = [episodes[0].podcast!]

        // Sweep to hide
        let count = await podcastManager.autoHideUnplayedEpisodes(settingsManager: settingsManager)
        XCTAssertEqual(count, 2)

        // Verify hidden
        for ep in episodes {
            XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: ep.guid))
        }

        // Undo
        podcastManager.undoAutoHide(forPodcastUrl: "https://example.com/feed")

        // Verify unhidden
        for ep in episodes {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: ep.guid),
                           "\(ep.guid) should be unhidden after undo")
        }

        // Log should be cleared
        let log = podcastManager.loadAutoHideLog()
        XCTAssertNil(log["https://example.com/feed"], "Log entry should be removed after undo")
    }

    // MARK: - Helpers

    /// Get the first registered Podcast from context.
    private func registeredPodcasts() -> [Podcast] {
        let descriptor = FetchDescriptor<Podcast>()
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 30-Day Expiry

    func test_loadAutoHideLog_prunesEntriesOlderThan30Days() {
        // Manually write a log entry with a lastUpdated date 31 days ago
        let oldDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        let freshDate = Date()
        let log: [String: PodcastManager.AutoHideLogEntry] = [
            "https://old.com/feed": PodcastManager.AutoHideLogEntry(count: 5, guids: ["a", "b", "c", "d", "e"], lastUpdated: oldDate),
            "https://fresh.com/feed": PodcastManager.AutoHideLogEntry(count: 2, guids: ["x", "y"], lastUpdated: freshDate),
        ]
        if let data = try? JSONEncoder().encode(log) {
            UserDefaults.standard.set(data, forKey: "autoHideLog")
        }

        let loaded = podcastManager.loadAutoHideLog()

        XCTAssertNil(loaded["https://old.com/feed"], "31-day-old entry should be pruned")
        XCTAssertNotNil(loaded["https://fresh.com/feed"], "Fresh entry should survive")
        XCTAssertEqual(loaded["https://fresh.com/feed"]?.count, 2)
    }
}

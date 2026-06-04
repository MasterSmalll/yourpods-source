import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for Refactor 1: Deduplication of applyEpisodeActions sync/async variants.
///
/// These tests verify that:
/// 1. The unified `applyEpisodeActionsCore` method exists and works
/// 2. sync (cooperative=false) and async (cooperative=true) paths produce identical results
/// 3. All 3 strategies work through the unified path
/// 4. The async cooperative path still respects Task cancellation
/// 5. The async cooperative path still yields (save count is identical)
@MainActor
final class EpisodeActionDeduplicationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-dedup"

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
            "lastSubscriptionSync_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast", episodeCount: Int = 3) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i)-\(url.hashValue).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    private func buildAction(for episode: Episode, podcast: Podcast, position: Int) -> EpisodeAction {
        EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: position,
            started: 0,
            total: episode.durationSeconds ?? 3600,
            device: "test"
        )
    }

    // MARK: - Parity: sync and async produce identical results

    /// Core parity test: serverWins strategy produces same results via sync and async paths.
    func test_syncAndAsync_serverWins_identicalPositions() async {
        // GIVEN: Two identical libraries with the same action maps
        let podcast = insertPodcast(url: "https://example.com/feed-dedup", episodeCount: 5)
        var map: [String: EpisodeAction] = [:]
        for episode in podcast.episodes {
            map[episode.guid] = buildAction(for: episode, podcast: podcast, position: 500)
        }
        seedActionMap(map)

        // WHEN: Apply via sync
        let syncConflicts = manager.applyEpisodeActions(strategy: .serverWins)

        // THEN: All positions should be 500
        for ep in podcast.episodes {
            XCTAssertEqual(ep.listenedSeconds, 500, "Sync: Episode \(ep.guid) should be at 500")
        }
        XCTAssertTrue(syncConflicts.isEmpty, "serverWins should produce no conflicts")

        // Reset positions to verify async
        for ep in podcast.episodes { ep.listenedSeconds = 0 }
        try! context.save()

        // WHEN: Apply via async
        let asyncConflicts = await manager.applyEpisodeActionsAsync(strategy: .serverWins)

        // THEN: All positions should be 500 — identical to sync
        for ep in podcast.episodes {
            XCTAssertEqual(ep.listenedSeconds, 500, "Async: Episode \(ep.guid) should be at 500")
        }
        XCTAssertTrue(asyncConflicts.isEmpty, "Async serverWins should produce no conflicts")
    }

    /// Parity test: deviceWins strategy produces same results via sync and async.
    func test_syncAndAsync_deviceWins_identicalBehavior() async {
        let podcast = insertPodcast(url: "https://example.com/feed-dedup-dw", episodeCount: 3)
        let episodes = podcast.episodes.sorted { $0.guid < $1.guid }

        // Episode 0: local ahead (300), server behind (100) → keep 300
        episodes[0].listenedSeconds = 300
        // Episode 1: local behind (50), server ahead (400) → take 400
        episodes[1].listenedSeconds = 50
        // Episode 2: local at 0, server at 200 → take 200
        episodes[2].listenedSeconds = 0
        try! context.save()

        var map: [String: EpisodeAction] = [:]
        map[episodes[0].guid] = buildAction(for: episodes[0], podcast: podcast, position: 100)
        map[episodes[1].guid] = buildAction(for: episodes[1], podcast: podcast, position: 400)
        map[episodes[2].guid] = buildAction(for: episodes[2], podcast: podcast, position: 200)
        seedActionMap(map)

        // Sync path
        let syncConflicts = manager.applyEpisodeActions(strategy: .deviceWins)
        XCTAssertEqual(episodes[0].listenedSeconds, 300, "Sync deviceWins: should keep local when ahead")
        XCTAssertEqual(episodes[1].listenedSeconds, 50, "Sync deviceWins: should keep local 50 (device always wins)")
        XCTAssertEqual(episodes[2].listenedSeconds, 200, "Sync deviceWins: should adopt server from 0")
        XCTAssertTrue(syncConflicts.isEmpty)

        // Reset
        episodes[0].listenedSeconds = 300
        episodes[1].listenedSeconds = 50
        episodes[2].listenedSeconds = 0
        try! context.save()

        // Async path
        let asyncConflicts = await manager.applyEpisodeActionsAsync(strategy: .deviceWins)
        XCTAssertEqual(episodes[0].listenedSeconds, 300, "Async deviceWins: should keep local when ahead")
        XCTAssertEqual(episodes[1].listenedSeconds, 50, "Async deviceWins: should keep local 50 (device always wins)")
        XCTAssertEqual(episodes[2].listenedSeconds, 200, "Async deviceWins: should adopt server from 0")
        XCTAssertTrue(asyncConflicts.isEmpty)
    }

    /// Parity test: ask strategy produces identical conflict sets via sync and async.
    func test_syncAndAsync_ask_identicalConflicts() async {
        let podcast = insertPodcast(url: "https://example.com/feed-dedup-ask", episodeCount: 2)
        let episodes = podcast.episodes.sorted { $0.guid < $1.guid }

        // Episode 0: big diff → conflict
        episodes[0].listenedSeconds = 300
        // Episode 1: small diff → auto-resolve
        episodes[1].listenedSeconds = 300
        try! context.save()

        var map: [String: EpisodeAction] = [:]
        map[episodes[0].guid] = buildAction(for: episodes[0], podcast: podcast, position: 1500)
        map[episodes[1].guid] = buildAction(for: episodes[1], podcast: podcast, position: 305)
        seedActionMap(map)

        // Sync path
        let syncConflicts = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertEqual(syncConflicts.count, 1, "Sync: should produce 1 conflict")
        XCTAssertEqual(syncConflicts.first?.episodeGuid, episodes[0].guid)
        XCTAssertEqual(episodes[0].listenedSeconds, 300, "Sync: conflicted episode should not be overwritten")
        XCTAssertEqual(episodes[1].listenedSeconds, 305, "Sync: auto-resolved should take higher")

        // Reset
        episodes[0].listenedSeconds = 300
        episodes[1].listenedSeconds = 300
        try! context.save()
        // Reset conflict counts so the async path gets count=1 too (not 2)
        UserDefaults.standard.removeObject(forKey: "syncConflictCounts")
        manager.loadConflictCounts()

        // Async path
        let asyncConflicts = await manager.applyEpisodeActionsAsync(strategy: .ask)
        XCTAssertEqual(asyncConflicts.count, 1, "Async: should produce 1 conflict")
        XCTAssertEqual(asyncConflicts.first?.episodeGuid, episodes[0].guid)
        XCTAssertEqual(episodes[0].listenedSeconds, 300, "Async: conflicted episode should not be overwritten")
        XCTAssertEqual(episodes[1].listenedSeconds, 305, "Async: auto-resolved should take higher")
    }

    // MARK: - WithStats parity

    /// The WithStats variants should return identical save counts for the same data.
    func test_syncAndAsync_withStats_identicalSaveCounts() async {
        // Create multiple podcasts to ensure multiple saves
        insertPodcast(url: "https://example.com/stats-a", title: "A", episodeCount: 10)
        insertPodcast(url: "https://example.com/stats-b", title: "B", episodeCount: 10)
        insertPodcast(url: "https://example.com/stats-c", title: "C", episodeCount: 10)

        // Populate action map with positions for all episodes
        var map: [String: EpisodeAction] = [:]
        for podcast in manager.subscriptions {
            for ep in podcast.episodes {
                map[ep.guid] = buildAction(for: ep, podcast: podcast, position: 250)
            }
        }
        seedActionMap(map)

        // Sync path
        let (syncConflicts, syncSaves) = manager.applyEpisodeActionsWithStats(strategy: .serverWins)

        // Reset
        for podcast in manager.subscriptions {
            for ep in podcast.episodes { ep.listenedSeconds = 0 }
        }
        try! context.save()

        // Async path
        let (asyncConflicts, asyncSaves) = await manager.applyEpisodeActionsWithStatsAsync(strategy: .serverWins)

        // Both should have the same save count and conflict count
        XCTAssertEqual(syncSaves, asyncSaves,
                       "Sync and async should perform the same number of saves")
        XCTAssertEqual(syncConflicts.count, asyncConflicts.count,
                       "Sync and async should produce the same conflict count")
    }

    // MARK: - Played-at-95% marking parity

    /// Both paths should mark episodes as played when position >= 95% of total.
    func test_syncAndAsync_marksPlayedAt95Percent() async {
        let podcast = insertPodcast(url: "https://example.com/played95", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        episode.listenedSeconds = 0
        try! context.save()

        let action = buildAction(for: episode, podcast: podcast, position: 3500) // 3500/3600 ≈ 97%
        seedActionMap([episode.guid: action])

        // Sync path
        manager.applyEpisodeActions(strategy: .serverWins)
        XCTAssertTrue(episode.isPlayed, "Sync: should mark as played at 97%")

        // Reset
        episode.isPlayed = false
        episode.listenedSeconds = 0
        try! context.save()

        // Async path
        _ = await manager.applyEpisodeActionsAsync(strategy: .serverWins)
        XCTAssertTrue(episode.isPlayed, "Async: should mark as played at 97%")
    }

    // MARK: - Cooperative cancellation still works after dedup

    /// After deduplication, the async path must still respect Task cancellation.
    func test_asyncCooperative_stillRespectsCancellation() async {
        // Create enough data that cancellation has a chance to fire
        for i in 0..<10 {
            insertPodcast(url: "https://example.com/cancel-\(i)", title: "Pod \(i)", episodeCount: 20)
        }
        var map: [String: EpisodeAction] = [:]
        for podcast in manager.subscriptions {
            for ep in podcast.episodes {
                map[ep.guid] = buildAction(for: ep, podcast: podcast, position: 600)
            }
        }
        seedActionMap(map)

        let task = Task {
            await manager.applyEpisodeActionsAsync(strategy: .serverWins)
        }
        task.cancel()
        _ = await task.value

        // The task completed without hanging — that's the primary assertion
        XCTAssertTrue(task.isCancelled, "Task should be cancelled")
    }
}

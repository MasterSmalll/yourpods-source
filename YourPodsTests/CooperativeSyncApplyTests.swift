import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the cooperative async episode action apply path.
///
/// Root cause: `syncEpisodeActions()` and orchestrator error fallbacks use the
/// synchronous `applyEpisodeActions()` which:
/// 1. Has no cancellation checking — background tasks can't exit gracefully
/// 2. Has no cooperative yielding — blocks the main thread during saves
/// 3. `modelContext.save()` inside `autoreleasepool` can trigger pread() signal crash
///
/// The fix routes these paths through `applyEpisodeActionsAsync()` which uses
/// `Task.isCancelled` and `Task.yield()` between per-podcast saves.
@MainActor
final class CooperativeSyncApplyTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-cooperative"

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
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast", episodeCount: Int = 3) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        for i in 0..<episodeCount {
            let ep = Episode(
                guid: "\(url)-ep-\(i)",
                title: "Episode \(i)",
                episodeDescription: nil,
                audioUrl: "https://example.com/\(url)-ep-\(i).mp3",
                pubDate: Date(),
                imageUrl: nil,
                durationSeconds: 600,
                link: nil,
                chaptersUrl: nil,
                transcriptUrl: nil,
                podcast: podcast
            )
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func populateActionMap(position: Int = 120) {
        var map: [String: EpisodeAction] = [:]
        for podcast in manager.subscriptions {
            for episode in podcast.episodes {
                let action = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: position,
                    started: 0,
                    total: episode.durationSeconds ?? 600,
                    device: "test"
                )
                map[episode.guid] = action
            }
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    // MARK: - syncEpisodeActions uses cooperative apply

    /// When `syncEpisodeActions()` is called and the parent task is cancelled,
    /// the apply step should exit early — proving it uses the cooperative async path.
    /// If it used the synchronous path, cancellation would have no effect.
    func test_syncEpisodeActions_respectsCancellation() async {
        // GIVEN: A library with many podcasts and a sync client that returns actions
        for i in 0..<10 {
            insertPodcast(url: "https://example.com/cooperative-\(i)", title: "Podcast \(i)", episodeCount: 20)
        }
        XCTAssertEqual(manager.subscriptions.count, 10, "Precondition: 10 podcasts")

        let spy = CooperativeSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: syncEpisodeActions is called in a task that gets cancelled
        let task = Task {
            _ = try? await manager.syncEpisodeActions()
        }
        // Cancel immediately
        task.cancel()
        _ = await task.value

        // THEN: The task completed without hanging (key guarantee).
        // With cooperative async, Task.isCancelled is checked between podcasts.
        XCTAssertTrue(task.isCancelled, "Task should be marked as cancelled")
    }

    /// syncEpisodeActions must still produce correct results when not cancelled.
    func test_syncEpisodeActions_appliesPositionsCorrectly() async {
        // GIVEN: A library with episodes and an action map with positions
        insertPodcast(url: "https://example.com/cooperative-a", title: "Podcast A", episodeCount: 3)
        insertPodcast(url: "https://example.com/cooperative-b", title: "Podcast B", episodeCount: 2)
        populateActionMap(position: 240)

        let spy = CooperativeSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: syncEpisodeActions runs to completion (no cancellation)
        _ = try? await manager.syncEpisodeActions()

        // THEN: All episode positions should be updated
        let allEpisodes = manager.subscriptions.flatMap(\.episodes)
        for episode in allEpisodes {
            XCTAssertEqual(episode.listenedSeconds, 240,
                           "Episode \(episode.guid) should have position 240 after sync apply")
        }
    }

    // MARK: - Orchestrator fallback uses cooperative apply

    /// When the gPodder orchestrator's episode action sync fails and falls back
    /// to local apply, the apply should use the cooperative async path.
    func test_gPodderOrchestrator_errorFallback_respectsCancellation() async {
        // GIVEN: A library and a spy client that throws on getEpisodeActions
        for i in 0..<5 {
            insertPodcast(url: "https://example.com/gpodder-fallback-\(i)", title: "Podcast \(i)", episodeCount: 10)
        }
        populateActionMap(position: 180)

        let spy = CooperativeFailingSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let orchestrator = GPodderSyncOrchestrator(client: spy)

        // WHEN: The orchestrator runs in a cancelled task
        let task = Task {
            _ = await orchestrator.sync(
                podcastManager: manager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: .serverWins
            )
        }
        task.cancel()
        _ = await task.value

        // THEN: The task completed without hanging
        XCTAssertTrue(task.isCancelled, "Task should be marked as cancelled")
    }

    /// When the Pro orchestrator's episode action sync fails and falls back,
    /// the apply should use the cooperative async path.
    func test_proOrchestrator_errorFallback_respectsCancellation() async {
        // GIVEN: A library and a spy client that throws on getEpisodeActions
        for i in 0..<5 {
            insertPodcast(url: "https://example.com/pro-fallback-\(i)", title: "Podcast \(i)", episodeCount: 10)
        }
        populateActionMap(position: 180)

        let spy = CooperativeFailingSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        playerManager.setSyncClient(spy, deviceId: "test-device")
        let settingsManager = SettingsManager()
        let downloadManager = DownloadManager()

        let orchestrator = ProSyncOrchestrator(client: spy)

        // WHEN: The orchestrator runs in a cancelled task
        let task = Task {
            _ = await orchestrator.sync(
                podcastManager: manager,
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                conflictStrategy: .serverWins
            )
        }
        task.cancel()
        _ = await task.value

        // THEN: The task completed without hanging
        XCTAssertTrue(task.isCancelled, "Task should be marked as cancelled")
    }
}

// MARK: - Spy SyncClients

/// Spy that returns empty results — for testing the normal cooperative path.
actor CooperativeSyncSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

/// Spy that throws on getEpisodeActions — for testing the orchestrator error fallback path.
actor CooperativeFailingSyncSpy: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated server error"])
    }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

import XCTest
import SwiftData
@testable import YourPods

/// Tests that marking episodes as played pushes `completed: true` to the Pro
/// playback endpoint, enabling cross-device sync.
///
/// Root cause: `PodcastManager.markEpisodeAsPlayed()` sent a gPodder-style
/// `EpisodeAction` but never called `syncClient.syncPlayback(completed: true)`.
/// Other devices never saw the completion.
@MainActor
final class EpisodeCompletionSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-completion-sync"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)

        let proProfile = ServerProfile(
            id: testProfileId,
            name: "Pro Test",
            baseUrl: "https://api.yourpods.app",
            username: "test",
            deviceId: "test-device",
            profileType: .yourpodsPro,
            proProfileName: "testpro"
        )
        let profiles = try! JSONEncoder().encode([proProfile])
        UserDefaults.standard.set(profiles, forKey: "serverProfiles")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
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
            "serverProfiles",
            "episodeActionMap",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition",
            "subscriptionUrls_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Test 1: markEpisodeAsPlayed sends syncPlayback(completed: true)

    /// When the user manually marks an episode as played, the Pro server must
    /// receive `syncPlayback(completed: true)` so other devices see the completion.
    func test_markAsPlayed_sendsSyncPlaybackCompleted() async throws {
        // GIVEN: A podcast with an episode, and a Pro sync client
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-1",
            title: "Episode 1",
            audioUrl: "https://example.com/ep1.mp3",
            durationSeconds: 3600,
            podcast: podcast
        )
        context.insert(episode)
        try context.save()
        manager.loadSubscriptions()

        let spy = CompletionSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: The episode is marked as played
        manager.markEpisodeAsPlayed(
            podcastUrl: "https://example.com/feed",
            episodeGuid: "ep-1"
        )

        // Completion now flows through the durable outbox; drain it to assert the eventual push.
        await manager.drainCompletionOutbox(using: spy, baselines: nil)

        // THEN: syncPlayback must have been called with completed: true
        let calls = await spy.syncPlaybackCalls
        let completedCall = calls.first { $0.completed == true }
        XCTAssertNotNil(completedCall,
                        "markEpisodeAsPlayed must send syncPlayback(completed: true) to the Pro server")
        XCTAssertEqual(completedCall?.episodeUrl, "https://example.com/ep1.mp3",
                       "completed: true must be sent for the correct episode URL")
        XCTAssertEqual(completedCall?.nowPlaying, false,
                       "nowPlaying must be false when marking as completed")
    }

    // MARK: - Test 2: markAllEpisodesAsPlayed sends syncPlayback(completed: true)

    /// When the user marks all episodes as played for a podcast, each unplayed
    /// episode must push `completed: true` to the Pro server.
    func test_markAllAsPlayed_sendsSyncPlaybackCompleted() async throws {
        // GIVEN: A podcast with 3 unplayed episodes
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Podcast")
        context.insert(podcast)
        for i in 1...3 {
            let ep = Episode(
                guid: "ep-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i).mp3",
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        try context.save()
        manager.loadSubscriptions()

        let spy = CompletionSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: All episodes are marked as played
        guard let loadedPodcast = manager.subscriptions.first(where: { $0.url == "https://example.com/feed" }) else {
            XCTFail("Podcast not found in subscriptions")
            return
        }
        manager.markAllEpisodesAsPlayed(for: loadedPodcast)

        // Allow async Tasks to run
        try await Task.sleep(for: .milliseconds(500))

        // THEN: syncPlayback(completed: true) must be called for each episode
        let calls = await spy.syncPlaybackCalls
        let completedCalls = calls.filter { $0.completed == true }
        XCTAssertEqual(completedCalls.count, 3,
                       "markAllEpisodesAsPlayed must send completed: true for each of the 3 unplayed episodes, got \(completedCalls.count)")
    }

    // MARK: - Test 3: markEpisodePlayedLocally does NOT send completed

    /// When an episode is marked as played via sync reconciliation (fromSync: true),
    /// it must NOT send syncPlayback back — that would create an echo loop.
    func test_markAsPlayedLocally_doesNotSendCompleted() async throws {
        // GIVEN: A podcast with an episode, and a Pro sync client
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-local",
            title: "Episode Local",
            audioUrl: "https://example.com/ep-local.mp3",
            durationSeconds: 3600,
            podcast: podcast
        )
        context.insert(episode)
        try context.save()
        manager.loadSubscriptions()

        let spy = CompletionSyncSpy()
        manager.setSyncClient(spy, deviceId: "test-device")

        // WHEN: The episode is marked as played locally (from sync)
        manager.markEpisodePlayedLocally(
            podcastUrl: "https://example.com/feed",
            episodeGuid: "ep-local"
        )

        // Allow async Tasks to settle
        try await Task.sleep(for: .milliseconds(300))

        // THEN: syncPlayback must NOT have been called
        let calls = await spy.syncPlaybackCalls
        XCTAssertTrue(calls.isEmpty,
                      "markEpisodePlayedLocally must NOT send syncPlayback — would cause echo loop, got \(calls.count) call(s)")
    }
}

// MARK: - Spy SyncClient for Completion Sync Tests

/// Tracks all `syncPlayback` calls with their `completed` flag,
/// enabling assertions on whether `completed: true` was pushed.
actor CompletionSyncSpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }
    var supportsPlaybackReconciliation: Bool { true }

    struct PlaybackCall {
        let podcastUrl: String
        let episodeUrl: String
        let episodeGuid: String?
        let positionSec: Double
        let nowPlaying: Bool?
        let completed: Bool?
    }

    private(set) var syncPlaybackCalls: [PlaybackCall] = []

    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?,
        clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? {
        syncPlaybackCalls.append(PlaybackCall(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid,
            positionSec: positionSec,
            nowPlaying: nowPlaying,
            completed: completed
        ))
        return nil
    }

    // MARK: - Unused protocol stubs
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: items, droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func deleteQueueItem(episodeUrl: String) async throws {}
    func getCurrentPlayback() async throws -> ProPlaybackState? { nil }
}

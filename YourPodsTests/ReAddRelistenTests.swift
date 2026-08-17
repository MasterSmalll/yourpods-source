import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for Task B6: re-add un-completes (iOS) + mark-unplayed propagates to Pro.
///
/// Two paths wired:
/// A) Re-adding a played episode to the queue clears local played state and tells the
///    server additively via /queue/add (which server-side also un-completes the episode).
/// B) Standalone "mark unplayed" (PodcastManager.markEpisodeAsUnplayed) now fires an
///    uncompletePlayback POST to Pro so other devices pick up the cleared state.
///    (gPodder already gets an action:"new" outbox row — unchanged.)
@MainActor
final class ReAddRelistenTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!

    private let testProfileId = "test-readdrelisten"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        // Set active profile so loadSubscriptions works correctly
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        playerManager = nil
        audioManager = nil
        podcastManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Insert a podcast + episode into the SwiftData context and load it into PodcastManager.
    @discardableResult
    private func insertEpisode(
        guid: String = "ep-guid-1",
        isPlayed: Bool = false,
        listenedSeconds: Int = 0
    ) -> (Podcast, Episode) {
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Test Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: guid,
            title: "Test Episode \(guid)",
            audioUrl: "https://example.com/\(guid).mp3",
            durationSeconds: 3600,
            podcast: podcast
        )
        episode.isPlayed = isPlayed
        episode.listenedSeconds = listenedSeconds
        context.insert(episode)
        try! context.save()
        // Associate podcast with the active profile so loadSubscriptions includes it
        podcastManager.associateWithCurrentProfile(url: podcast.url)
        // Wire it into PodcastManager's in-memory subscriptions list
        podcastManager.loadSubscriptions()
        return (podcast, episode)
    }

    // MARK: - A: Re-add of played episode clears local played state

    /// Test A — re-adding a played episode must clear isPlayed and listenedSeconds locally.
    func test_addToQueue_playedEpisode_clearsLocalPlayed() {
        let (_, episode) = insertEpisode(isPlayed: true, listenedSeconds: 3600)
        XCTAssertTrue(episode.isPlayed, "Precondition: episode must start as played")

        playerManager.addToQueue(episode, playNext: false)

        XCTAssertFalse(episode.isPlayed,
                       "Re-adding a played episode must clear isPlayed")
        XCTAssertEqual(episode.listenedSeconds, 0,
                       "Re-adding a played episode must reset listenedSeconds to 0")
    }

    /// Test B — re-adding a played episode fires addToQueue on the Pro sync client.
    func test_addToQueue_playedEpisode_callsClientAddToQueue() async {
        let spy = ReAddSyncSpy()
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let (_, episode) = insertEpisode(guid: "ep-relisten-1", isPlayed: true, listenedSeconds: 3600)

        let expectation = XCTestExpectation(description: "spy.addToQueue called")
        await spy.setAddToQueueFulfillment(expectation)

        playerManager.addToQueue(episode, playNext: false)

        await fulfillment(of: [expectation], timeout: 2)

        let calledGuids = await spy.addedQueueGuids
        XCTAssertTrue(calledGuids.contains("ep-relisten-1"),
                      "addToQueue should call the sync client with the episode guid; got \(calledGuids)")
    }

    /// Test C — re-adding an UNPLAYED episode must NOT fire addToQueue on the Pro sync client.
    func test_addToQueue_unplayedEpisode_doesNotCallClientAddToQueue() async {
        let spy = ReAddSyncSpy()
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let (_, episode) = insertEpisode(guid: "ep-unplayed-1", isPlayed: false, listenedSeconds: 0)

        playerManager.addToQueue(episode, playNext: false)

        // No Task is created for unplayed episodes (the `if wasPlayed` guard short-circuits),
        // so no sleep is needed — the assertion is deterministically immediate.
        let calledGuids = await spy.addedQueueGuids
        XCTAssertTrue(calledGuids.isEmpty,
                      "addToQueue must NOT fire server call for an unplayed episode; got \(calledGuids)")
    }

    // MARK: - B: markEpisodeAsUnplayed propagates uncompletePlayback to Pro

    /// Test D — markEpisodeAsUnplayed must call uncompletePlayback on the sync client.
    func test_markEpisodeAsUnplayed_callsUncompletePlayback() async {
        let spy = ReAddSyncSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")

        let (podcast, episode) = insertEpisode(guid: "ep-unplay-1", isPlayed: true, listenedSeconds: 600)

        let expectation = XCTestExpectation(description: "spy.uncompletePlayback called")
        await spy.setUncompleteFulfillment(expectation)

        podcastManager.markEpisodeAsUnplayed(podcastUrl: podcast.url, episodeGuid: episode.guid)

        await fulfillment(of: [expectation], timeout: 2)

        let calls = await spy.uncompletePlaybackCalls
        XCTAssertFalse(calls.isEmpty, "uncompletePlayback must be called")
        if let call = calls.first {
            XCTAssertEqual(call.podcastUrl, podcast.url,
                           "uncompletePlayback podcastUrl must match")
            XCTAssertEqual(call.episodeGuid, episode.guid,
                           "uncompletePlayback episodeGuid must match")
        }
    }

    /// Test E — markEpisodeAsUnplayed must clear isPlayed and listenedSeconds locally.
    func test_markEpisodeAsUnplayed_clearsLocalState() {
        let (podcast, episode) = insertEpisode(isPlayed: true, listenedSeconds: 600)
        XCTAssertTrue(episode.isPlayed, "Precondition: episode is played")

        podcastManager.markEpisodeAsUnplayed(podcastUrl: podcast.url, episodeGuid: episode.guid)

        XCTAssertFalse(episode.isPlayed,
                       "markEpisodeAsUnplayed must clear isPlayed")
        XCTAssertEqual(episode.listenedSeconds, 0,
                       "markEpisodeAsUnplayed must reset listenedSeconds")
    }
}

// MARK: - Spy SyncClient

/// Spy that records addToQueue and uncompletePlayback calls for assertion.
private actor ReAddSyncSpy: SyncClient {

    // MARK: - Captured calls

    var addedQueueGuids: [String] = []

    struct UncompleteCall {
        let podcastUrl: String
        let episodeUrl: String
        let episodeGuid: String?
    }
    var uncompletePlaybackCalls: [UncompleteCall] = []

    // MARK: - Fulfillment hooks

    private var addToQueueExpectation: XCTestExpectation?
    private var uncompleteExpectation: XCTestExpectation?

    func setAddToQueueFulfillment(_ exp: XCTestExpectation) {
        addToQueueExpectation = exp
    }

    func setUncompleteFulfillment(_ exp: XCTestExpectation) {
        uncompleteExpectation = exp
    }

    // MARK: - SyncClient conformance

    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }
    var supportsPlaybackReconciliation: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: [], droppedItems: [])
    }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func deleteQueueItem(episodeUrl: String) async throws {}

    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws {
        addedQueueGuids.append(item.episodeGuid ?? item.episodeUrl)
        addToQueueExpectation?.fulfill()
        addToQueueExpectation = nil
    }

    func uncompletePlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        clientUpdatedAt: Date?
    ) async throws {
        uncompletePlaybackCalls.append(UncompleteCall(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid
        ))
        uncompleteExpectation?.fulfill()
        uncompleteExpectation = nil
    }
}

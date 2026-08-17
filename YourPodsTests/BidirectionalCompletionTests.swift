import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for bidirectional completion ingest (Task B3).
///
/// Root cause: `applyCompletedChanges` only applied `completed:true` from the server delta.
/// A relisten or re-add on another device pushes `completed:false` to the server, but iOS
/// never consumed it — so the played state stayed stale on this device.
///
/// Fix: `parseRecentResponse` now emits `UncompletedStateChange` for each `completed:false`
/// state; `applyUncompletedChanges` clears `isPlayed`/`listenedSeconds` with a
/// pending-completion guard so a locally just-finished episode is never reverted mid-cycle.
@MainActor
final class BidirectionalCompletionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var testCompletionOutboxURL: URL!
    private let testProfileId = "test-bidirectional"
    private let testDeviceId  = "test-device-bidirectional"

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        testCompletionOutboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-bidirectional-outbox-\(UUID().uuidString).json")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testCompletionOutboxURL)
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeService(
        subscriptions: [Podcast] = [],
        client: (any SyncClient)? = nil
    ) -> EpisodeActionSyncService {
        let subs = subscriptions
        return EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { client },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId },
            completionOutboxFileURL: self.testCompletionOutboxURL
        )
    }

    private func insertPlayedEpisode(guid: String = "ep-guid-1") -> (Podcast, Episode) {
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Test Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: guid,
            title: "Test Episode",
            audioUrl: "https://example.com/\(guid).mp3",
            podcast: podcast
        )
        episode.isPlayed = true
        episode.listenedSeconds = 1800
        context.insert(episode)
        return (podcast, episode)
    }

    // MARK: - 1. parseRecentResponse emits UncompletedStateChange for completed:false

    func test_parseRecent_emitsUncompletedChange_forCompletedFalse() throws {
        let json = #"""
        {"states":[{"podcastUrl":"https://example.com/feed.xml","episodeUrl":"https://example.com/ep1.mp3","positionSec":0,"completed":false}]}
        """#.data(using: .utf8)!

        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertEqual(parsed.uncompleted.map(\.guid), ["https://example.com/ep1.mp3"],
                       "completed:false should emit one UncompletedStateChange")
        XCTAssertTrue(parsed.completed.isEmpty,
                      "completed:false must NOT emit a CompletedStateChange")
    }

    func test_parseRecent_noUncompletedChange_forCompletedTrue() throws {
        let json = #"""
        {"states":[{"podcastUrl":"https://example.com/feed.xml","episodeUrl":"https://example.com/ep1.mp3","positionSec":3600,"completed":true}]}
        """#.data(using: .utf8)!

        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertTrue(parsed.uncompleted.isEmpty,
                      "completed:true must NOT emit an UncompletedStateChange")
        XCTAssertEqual(parsed.completed.count, 1,
                       "completed:true should emit exactly one CompletedStateChange")
    }

    func test_parseRecent_noUncompletedChange_forCompletedAbsent() throws {
        let json = #"""
        {"states":[{"podcastUrl":"https://example.com/feed.xml","episodeUrl":"https://example.com/ep1.mp3","positionSec":120}]}
        """#.data(using: .utf8)!

        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertTrue(parsed.uncompleted.isEmpty,
                      "absent completed field must NOT emit an UncompletedStateChange")
        XCTAssertTrue(parsed.completed.isEmpty,
                      "absent completed field must NOT emit a CompletedStateChange")
    }

    func test_parseRecent_prefersEpisodeGuid_overEpisodeUrl() throws {
        let json = #"""
        {"states":[{"podcastUrl":"https://example.com/feed.xml","episodeUrl":"https://example.com/ep1.mp3","episodeGuid":"stable-guid-abc","positionSec":0,"completed":false}]}
        """#.data(using: .utf8)!

        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertEqual(parsed.uncompleted.map(\.guid), ["stable-guid-abc"],
                       "UncompletedStateChange should use episodeGuid when present")
    }

    func test_parseRecent_noUncompletedChange_forHighPositionCompletedFalse() throws {
        // A device paused near the end of an episode: completed:false but positionSec is high.
        // This is NOT a genuine relisten/re-add — emitting an UncompletedStateChange here
        // would un-play an episode that applyActionsForPodcast's position>=threshold
        // inference just marked played (played->unplayed regression). Must NOT emit.
        let json = #"""
        {"states":[{"podcastUrl":"https://example.com/feed.xml","episodeUrl":"https://example.com/ep1.mp3","positionSec":3492,"completed":false}]}
        """#.data(using: .utf8)!

        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertTrue(parsed.uncompleted.isEmpty,
                      "completed:false with high positionSec must NOT emit an UncompletedStateChange")
        XCTAssertTrue(parsed.completed.isEmpty,
                      "completed:false must NOT emit a CompletedStateChange")
    }

    // MARK: - 2. applyUncompletedChanges clears isPlayed and listenedSeconds

    func test_applyUncompleted_clearsIsPlayed_andListenedSeconds() {
        let (podcast, episode) = insertPlayedEpisode(guid: "ep-guid-1")
        XCTAssertTrue(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 1800)

        let service = makeService(subscriptions: [podcast])
        let changes = [UncompletedStateChange(guid: "ep-guid-1")]
        service.applyUncompletedChanges(changes)

        XCTAssertFalse(episode.isPlayed,
                       "applyUncompletedChanges must set isPlayed=false")
        XCTAssertEqual(episode.listenedSeconds, 0,
                       "applyUncompletedChanges must reset listenedSeconds to 0")
    }

    func test_applyUncompleted_noOp_whenAlreadyUnplayed() {
        let (podcast, episode) = insertPlayedEpisode(guid: "ep-guid-2")
        episode.isPlayed = false
        episode.listenedSeconds = 0

        let service = makeService(subscriptions: [podcast])
        let changes = [UncompletedStateChange(guid: "ep-guid-2")]
        service.applyUncompletedChanges(changes)

        // Should not crash, and state stays unplayed
        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)
    }

    func test_applyUncompleted_emptyChanges_isNoOp() {
        let (podcast, episode) = insertPlayedEpisode(guid: "ep-guid-3")
        let service = makeService(subscriptions: [podcast])
        service.applyUncompletedChanges([])

        // No mutations, episode stays played
        XCTAssertTrue(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 1800)
    }

    // MARK: - 3. Guard: pending completion in outbox blocks applyUncompletedChanges

    func test_applyUncompleted_skipsGuid_whenInPendingCompletionOutbox() {
        let (podcast, episode) = insertPlayedEpisode(guid: "ep-guid-pending")

        let service = makeService(subscriptions: [podcast])

        // Enqueue a pending completion for this episode so it's in the outbox
        let pending = PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-guid-pending.mp3",
            episodeGuid: "ep-guid-pending",
            durationSec: 3600,
            eventTime: Date()
        )
        service.enqueueCompletion(pending)

        // Verify it's in the outbox
        XCTAssertTrue(service.pendingCompletionGuids().contains("ep-guid-pending"),
                      "Precondition: guid must be in the pending outbox")

        // Now try to un-complete it — should be blocked by the guard
        let changes = [UncompletedStateChange(guid: "ep-guid-pending")]
        service.applyUncompletedChanges(changes)

        XCTAssertTrue(episode.isPlayed,
                      "Episode with pending local completion must NOT be un-played by the server delta")
        XCTAssertEqual(episode.listenedSeconds, 1800,
                       "listenedSeconds must remain untouched for guarded episodes")
    }

    // MARK: - 4. markUnplayedIfNeeded churn guard

    func test_markUnplayedIfNeeded_flipsIsPlayed() {
        let episode = Episode(
            guid: "churn-guid",
            title: "Churn Test",
            audioUrl: "https://example.com/churn.mp3"
        )
        episode.isPlayed = true
        episode.listenedSeconds = 900

        episode.markUnplayedIfNeeded()

        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)
    }

    func test_markUnplayedIfNeeded_noOp_whenAlreadyUnplayed() {
        let episode = Episode(
            guid: "noop-guid",
            title: "No-op Test",
            audioUrl: "https://example.com/noop.mp3"
        )
        episode.isPlayed = false
        episode.listenedSeconds = 0

        episode.markUnplayedIfNeeded()

        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)
    }
}

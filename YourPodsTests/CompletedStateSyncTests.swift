import XCTest
import SwiftData
@testable import YourPods

/// iOS must honor the server's authoritative `completed`
/// flag from `GET /playback/recent`, instead of re-deriving completion from a
/// lossy position>=threshold heuristic.
///
/// Root cause: `YourPodsProClient.getEpisodeActionsWithHiddenChanges` decodes
/// `completed` but drops it (only `hidden` was extracted), so a finished-on-web
/// episode is never reliably marked played on iOS — and lingers in the mini player.
///
/// Fix mirrors the existing `HiddenStateChange` side-channel: decode emits a
/// `CompletedStateChange` list; `applyCompletedChanges` marks `isPlayed` with no
/// outbound echo.
@MainActor
final class CompletedStateSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-completed"
    private let testDeviceId = "test-device-completed"
    private var testOutboxURL: URL!

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
        testOutboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-completed-\(UUID().uuidString).json")
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: testOutboxURL)
        manager = nil
        context = nil
        container = nil
        testOutboxURL = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in [
            "activeProfileId",
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeService(client: SyncClient? = nil) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { client },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId },
            outboxFileURL: testOutboxURL
        )
    }

    @discardableResult
    private func insertPodcastWithEpisode(guid: String = "ep-1") -> (Podcast, Episode) {
        let podcast = Podcast(url: "https://example.com/pod1", title: "Test Podcast")
        context.insert(podcast)
        let ep = Episode(
            guid: guid,
            title: "Episode",
            audioUrl: "https://example.com/\(guid).mp3",
            pubDate: Date(),
            durationSeconds: 3600
        )
        ep.podcast = podcast
        ep.isPlayed = false
        context.insert(ep)
        podcast.episodes = [ep]
        manager.subscriptions = [podcast]
        return (podcast, ep)
    }

    // MARK: - Apply layer

    /// The authoritative server flag marks the episode played with NO outbound echo.
    func test_applyCompletedChanges_marksEpisodePlayed_noOutboundAction() {
        let (_, ep) = insertPodcastWithEpisode(guid: "ep-1")
        let service = makeService()
        XCTAssertFalse(ep.isPlayed)

        service.applyCompletedChanges([CompletedStateChange(guid: "ep-1")])

        XCTAssertTrue(ep.isPlayed, "completed=true from server must mark the episode played")
        XCTAssertTrue(service.outbox.isEmpty, "applying a server completion must NOT enqueue an outbound action (no echo)")
    }

    /// Empty input is a no-op (mirrors applyHiddenChanges guard).
    func test_applyCompletedChanges_emptyIsNoOp() {
        let (_, ep) = insertPodcastWithEpisode(guid: "ep-1")
        let service = makeService()

        service.applyCompletedChanges([])

        XCTAssertFalse(ep.isPlayed)
    }

    // MARK: - Decode layer

    /// The `/playback/recent` decode emits a CompletedStateChange ONLY for
    /// completed==true rows (never un-completes from the pull side).
    func test_parseRecentResponse_emitsCompletedOnlyForTrue() throws {
        let json = """
        {
          "states": [
            { "podcastUrl": "https://example.com/pod1", "episodeUrl": "https://example.com/ep-1.mp3", "episodeGuid": "ep-1", "positionSec": 3600, "durationSec": 3600, "completed": true, "nowPlaying": false },
            { "podcastUrl": "https://example.com/pod1", "episodeUrl": "https://example.com/ep-2.mp3", "episodeGuid": "ep-2", "positionSec": 120, "durationSec": 3600, "completed": false, "nowPlaying": true }
          ],
          "timestamp": "2026-06-13T12:00:00Z"
        }
        """.data(using: .utf8)!

        let parsed = try YourPodsProClient.parseRecentResponse(json)

        XCTAssertEqual(parsed.actions.count, 2, "both states still map to play actions")
        XCTAssertEqual(parsed.completed.count, 1, "only completed==true emits a CompletedStateChange")
        XCTAssertEqual(parsed.completed.first?.guid, "ep-1")
    }
}

import XCTest
@testable import YourPods

/// An episode that goes back into Up Next after you play something else must
/// survive the next sync.
///
/// Reported from the device: "When I click on an episode in my queue, the mini
/// player episode correctly goes back to queue — however during the next sync
/// that episode seems to be removed from queue." iOS only, which is the tell:
/// this prune exists only in `PlayerManager.syncQueueWithServer`.
///
/// The two halves that collide are each individually reasonable:
///
/// 1. **The queue carries Up Next only.** A now-playing episode is owned by the
///    playback channel and is never pushed as a queue item, so it is absent
///    from the server's queue for as long as it is playing.
/// 2. **The prune snapshot includes the now-playing episode** — `allServerGuids`
///    is `finalQueue + currentId`, added so the episode you are listening to is
///    not pruned out from under you.
///
/// Together they mean the now-playing episode is recorded as "the server knew
/// about this" while being deliberately withheld from the server. That is
/// harmless until it comes *back* to Up Next: `preserveCurrent` re-inserts it
/// locally, the next sync computes `previousServerGuids − serverGuids`, finds
/// it there, and concludes another device deleted it.
///
/// It is deterministic, not a race — and the prune runs *before* the push, so
/// the re-add is destroyed before it can ever be uploaded.
@MainActor
final class QueueReturnFromNowPlayingTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let serverGuidsKey = PlayerManager.proQueueSyncServerGuidsKey
    private let syncCompletedKey = "proQueueSyncCompleted"

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: serverGuidsKey)
        defaults.removeObject(forKey: syncCompletedKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: serverGuidsKey)
        defaults.removeObject(forKey: syncCompletedKey)
        super.tearDown()
    }

    private func makeItem(id: String, title: String = "Episode", position: Int = 0) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: position,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    private func makeSyncItem(guid: String, sortOrder: Int) -> QueueSyncItem {
        QueueSyncItem(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/\(guid).mp3",
            episodeGuid: guid,
            sortOrder: sortOrder,
            positionSec: 0,
            title: "Episode",
            podcastTitle: "Test Podcast"
        )
    }

    /// Plays out the whole sequence rather than asserting against a snapshot
    /// written by hand.
    ///
    /// Hand-seeding `proQueueSyncServerGuids` would encode *today's* writer into
    /// the test: the fix changes what a sync persists, so a hardcoded `{B, A}`
    /// would keep the test red no matter how correct the code became, and a
    /// hardcoded `{B}` would make it green without the fix ever running. The
    /// snapshot has to be written by a real sync.
    ///
    /// 1. **A is playing, B is Up Next.** A sync runs and persists its own
    ///    baseline.
    /// 2. **The user taps B.** `preserveCurrent` returns A to Up Next; B becomes
    ///    now-playing. Nothing has been pushed.
    /// 3. **The next sync runs.** A must survive it.
    private func runTapThenSync(
        secondPull: [QueueSyncItem]? = nil
    ) async -> (audioManager: AudioManager, client: QueuePruningMockSyncClient) {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setEchoMode(true)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        // ── 1. A playing, B queued. The server holds Up Next only, so just B.
        audioManager.currentItem = makeItem(id: "ep-a", title: "Was Playing", position: 812)
        audioManager.appendToQueue([makeItem(id: "ep-b", title: "Up Next")])
        await mockClient.setGetQueueResponse([makeSyncItem(guid: "ep-b", sortOrder: 1)])
        await playerManager.syncQueueWithServer()

        // ── 2. The tap. This is what AudioManager.playEpisode(preserveCurrent:)
        //       does: the outgoing episode goes back to the top of Up Next and
        //       the tapped one becomes now-playing.
        let outgoing = audioManager.currentItem!
        audioManager.removeFromQueue(makeItem(id: "ep-b"))
        audioManager.currentItem = makeItem(id: "ep-b", title: "Just Tapped")
        audioManager.insertNext([outgoing])

        // ── 3. The next sync. The server still reflects the pre-tap world.
        await mockClient.setGetQueueResponse(secondPull ?? [makeSyncItem(guid: "ep-b", sortOrder: 1)])
        await playerManager.syncQueueWithServer()

        return (audioManager, mockClient)
    }

    // MARK: - The defect

    func test_episodeReturnedToUpNext_isNotPrunedByTheNextSync() async {
        let (audioManager, _) = await runTapThenSync()

        XCTAssertTrue(
            audioManager.queue.map(\.id).contains("ep-a"),
            """
            The episode you were listening to was dropped from Up Next by the \
            first sync after you tapped another one. It is in the prune \
            snapshot because it was the now-playing episode, and absent from \
            the server queue because now-playing episodes are never pushed \
            there — so returning to Up Next makes it look remotely deleted.
            """
        )
    }

    /// It must come back with the position it had, not from zero — the whole
    /// point of putting it back in Up Next is to resume it later.
    func test_returnedEpisode_keepsItsPosition() async {
        let (audioManager, _) = await runTapThenSync()

        XCTAssertEqual(audioManager.queue.first(where: { $0.id == "ep-a" })?.positionSeconds, 812,
                       "surviving the prune is no use if it resumes from the start")
    }

    /// The returned episode must also reach the server, or the next device to
    /// sync re-derives the same deletion from its own snapshot.
    func test_returnedEpisode_isPushedToTheServer() async {
        let (_, mockClient) = await runTapThenSync()

        let pushed = await mockClient.lastPushedItems.map { $0.episodeGuid ?? $0.episodeUrl }
        XCTAssertTrue(pushed.contains("ep-a"),
                      "pruned locally means never pushed — the queue is only repaired on this device")
    }

    /// The snapshot is the mechanism, so assert it directly: after a sync while
    /// an episode is playing, that episode must not be recorded as something
    /// the server holds. It is the one id guaranteed to be absent next time.
    func test_snapshot_doesNotClaimTheServerHoldsTheNowPlayingEpisode() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setEchoMode(true)
        await mockClient.setGetQueueResponse([makeSyncItem(guid: "ep-b", sortOrder: 1)])
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        audioManager.currentItem = makeItem(id: "ep-a", title: "Playing")
        audioManager.appendToQueue([makeItem(id: "ep-b", title: "Up Next")])

        await playerManager.syncQueueWithServer()

        let snapshot = defaults.stringArray(forKey: serverGuidsKey) ?? []
        XCTAssertFalse(snapshot.contains("ep-a"),
                       "the now-playing episode is never pushed to the queue, so recording it as "
                       + "server-held guarantees it reads as remotely deleted next sync")
        XCTAssertTrue(snapshot.contains("ep-b"), "genuine Up Next items must still be recorded")
    }

    // MARK: - The prune still has to work

    /// The narrowing must not cost the real case: an episode genuinely removed
    /// on another device is still pruned. It was Up Next at the last sync
    /// (never now-playing here) and is gone from the server now.
    func test_episodeRemovedOnAnotherDevice_isStillPruned() async {
        defaults.set(["ep-x", "ep-y"], forKey: serverGuidsKey)
        defaults.set(true, forKey: syncCompletedKey)

        let audioManager = AudioManager()
        audioManager.appendToQueue([makeItem(id: "ep-x"), makeItem(id: "ep-y")])

        let playerManager = PlayerManager(audioManager: audioManager)
        let mockClient = QueuePruningMockSyncClient()
        await mockClient.setGetQueueResponse([makeSyncItem(guid: "ep-x", sortOrder: 1)])
        await mockClient.setEchoMode(true)
        playerManager.setSyncClient(mockClient, deviceId: "test-device")

        await playerManager.syncQueueWithServer()

        XCTAssertFalse(audioManager.queue.map(\.id).contains("ep-y"),
                       "ep-y was Up Next on the server and is now gone — that is a real remote removal")
    }
}

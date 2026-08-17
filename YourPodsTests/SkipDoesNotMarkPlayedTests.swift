import XCTest
@testable import YourPods

/// Skipping an episode is not finishing it — and it must not lose your place either.
///
/// `AudioManager.skipToNext` fires `onEpisodeCompleted` unconditionally, and
/// `handleEpisodeCompleted` sends an `EpisodeAction` with `position: totalDuration,
/// total: totalDuration` and marks the episode played locally. So pressing next on the
/// headphones, in the car, in the player, or via Siri is recorded as *you finished this*
/// — and pushes a full-duration position that propagates to every other device.
///
/// Owner-confirmed. The four call sites do not share an intent, which is the whole
/// difficulty:
///
/// | Site | Intent | Completes? |
/// |---|---|---|
/// | `AudioManager` skip-outro observer | reached the end minus the outro | **yes** |
/// | `AudioManager` `.nextEpisode` remote command | manual (headphones / car) | **no** |
/// | `PlayerManager.skipToNext()` (player button, Siri) | manual | **no** |
/// | `PlayerManager` mark-played flow | explicitly marking played | **yes** |
///
/// The default stays `true`: it matches the completion-intending majority and keeps
/// auto-advance semantics for anything not listed above.
///
/// ## The half that is easy to miss
///
/// `QueueItem` is a **struct**, and `PlayerManager`'s "previous item" was a snapshot
/// taken when an episode *became* current — its resume position, not where you skipped
/// from. Nothing refreshed it. So the push that clears the outgoing episode's
/// `nowPlaying` asserted a **stale position with a fresh event time**.
///
/// Today the false completion masks that by pushing the full duration: wrong, but at
/// least forward. Suppress the completion without fixing the snapshot and "skipping no
/// longer marks played" silently becomes "skipping rewinds you to where you started" —
/// and on the merging server a fresh-timestamped older position is exactly the stale-ping
/// shape that was measured rewinding a stored position by 2988 seconds.
@MainActor
final class SkipDoesNotMarkPlayedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearPersistedQueue()
    }

    override func tearDown() {
        clearPersistedQueue()
        super.tearDown()
    }

    /// `AudioManager.queue`'s didSet persists to the real `UserDefaults.standard`, so a
    /// queue mutation here restores itself into the next test's fresh `AudioManager()`.
    private func clearPersistedQueue() {
        for key in ["savedQueue", "savedCurrentItem", "savedCurrentPosition"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Fixtures

    private func makeItem(id: String, positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: id, title: "Episode \(id)", podcastTitle: "Pod",
            audioUrl: "https://example.com/\(id).mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
    }

    private func pollUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    // MARK: - The defect: a manual skip is not a completion

    func test_skipToNext_notCompletingCurrent_doesNotFireCompletion() async {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.appendToQueue([makeItem(id: "ep-2")])
        manager.isPlaying = true
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }

        manager.skipToNext(completingCurrent: false)

        let advanced = await pollUntil { manager.currentItem?.id == "ep-2" }
        XCTAssertTrue(advanced, "suppressing the completion must not suppress the skip")
        XCTAssertTrue(manager.queue.isEmpty, "the next item is still popped from Up Next")
        XCTAssertEqual(completedIds, [],
                       "a manual skip recorded as a completion marks the episode played and "
                       + "pushes a full-duration position to every other device")
    }

    /// The default is the completion-intending majority — skip-outro and auto-advance
    /// both reach `skipToNext` and both genuinely finished the episode.
    func test_skipToNext_byDefault_stillFiresCompletion() async {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.appendToQueue([makeItem(id: "ep-2")])
        manager.isPlaying = true
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }

        manager.skipToNext()

        _ = await pollUntil { manager.currentItem?.id == "ep-2" }
        XCTAssertEqual(completedIds, ["ep-1"])
    }

    /// Headphones and car controls. `.nextEpisode` reaches `skipToNext` with no way for
    /// the user to have meant "I finished this".
    func test_remoteNextEpisodeCommand_doesNotFireCompletion() async {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.appendToQueue([makeItem(id: "ep-2")])
        manager.isPlaying = true
        var completedIds: [String] = []
        manager.onEpisodeCompleted = { completedIds.append($0.id) }

        manager.executeRemoteAction(.nextEpisode)

        let advanced = await pollUntil { manager.currentItem?.id == "ep-2" }
        XCTAssertTrue(advanced)
        XCTAssertEqual(completedIds, [],
                       "pressing next on headphones marked the episode played")
    }

    /// The player's next button and Siri's "next episode" both land here.
    func test_playerManagerSkipToNext_doesNotFireCompletion() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1")
        audioManager.appendToQueue([makeItem(id: "ep-2")])
        audioManager.isPlaying = true
        var completedIds: [String] = []
        let original = audioManager.onEpisodeCompleted
        audioManager.onEpisodeCompleted = { completedIds.append($0.id); original?($0) }

        playerManager.skipToNext()

        let advanced = await pollUntil { audioManager.currentItem?.id == "ep-2" }
        XCTAssertTrue(advanced)
        XCTAssertEqual(completedIds, [])
    }

    /// The other side of the intent table: explicitly marking played must still complete,
    /// or the fix trades one silent wrong answer for another.
    func test_markCurrentEpisodeAsPlayed_stillFiresCompletion() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1")
        audioManager.appendToQueue([makeItem(id: "ep-2")])
        audioManager.isPlaying = true
        var completedIds: [String] = []
        let original = audioManager.onEpisodeCompleted
        audioManager.onEpisodeCompleted = { completedIds.append($0.id); original?($0) }

        playerManager.markCurrentEpisodeAsPlayed()

        _ = await pollUntil { audioManager.currentItem?.id == "ep-2" }
        XCTAssertEqual(completedIds, ["ep-1"],
                       "marking played is the one manual action that IS a completion")
    }

    // MARK: - The other half: the outgoing episode keeps its place

    /// The episode being left is handed over **while its live position is still current**,
    /// which is the only moment it exists — `playEpisode` replaces `currentItem` next.
    func test_itemWillChange_firesWithTheOutgoingEpisode() async {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.appendToQueue([makeItem(id: "ep-2")])
        manager.isPlaying = true
        var outgoing: [String] = []
        manager.onItemWillChange = { outgoing.append($0.id) }

        manager.skipToNext(completingCurrent: false)

        _ = await pollUntil { manager.currentItem?.id == "ep-2" }
        XCTAssertEqual(outgoing, ["ep-1"],
                       "nothing else can name the episode being left once currentItem has moved")
    }

    func test_itemWillChange_doesNotFire_whenThereIsNothingToLeave() async {
        let manager = AudioManager()
        var outgoing: [String] = []
        manager.onItemWillChange = { outgoing.append($0.id) }

        await manager.playEpisode(makeItem(id: "ep-1"))

        XCTAssertEqual(outgoing, [], "a first play leaves nothing behind")
    }

    /// The regression this whole second half exists to prevent.
    ///
    /// `positionSeconds: 60` is where the episode was resumed; `currentPosition` 1200 is
    /// where the user actually skipped from. The value handed to the "clear nowPlaying"
    /// push has to be the second one — a fresh-timestamped 60 is a rewind, and the server
    /// merges it as one.
    func test_manualSkip_previousItemCarriesTheLivePosition_notTheResumeOne() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1", positionSeconds: 60)
        audioManager.appendToQueue([makeItem(id: "ep-2")])
        audioManager.testableSetPlaybackState(position: 1200, duration: 3600)
        audioManager.isPlaying = true

        playerManager.skipToNext()

        _ = await pollUntil { audioManager.currentItem?.id == "ep-2" }
        XCTAssertEqual(playerManager.previousItemForSync?.id, "ep-1")
        XCTAssertEqual(
            playerManager.previousItemForSync?.positionSeconds, 1200,
            "the episode you skipped away from was reported at the position it was resumed "
            + "at, with a fresh event time — the server merges that as a rewind"
        )
    }

    /// Same requirement on the completing path: auto-advance and skip-outro also clear the
    /// outgoing episode's nowPlaying, and a stale position there is the same bug.
    func test_completingSkip_previousItemAlsoCarriesTheLivePosition() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1", positionSeconds: 60)
        audioManager.appendToQueue([makeItem(id: "ep-2")])
        audioManager.testableSetPlaybackState(position: 3595, duration: 3600)
        audioManager.isPlaying = true

        audioManager.skipToNext()

        _ = await pollUntil { audioManager.currentItem?.id == "ep-2" }
        XCTAssertEqual(playerManager.previousItemForSync?.positionSeconds, 3595)
    }
}

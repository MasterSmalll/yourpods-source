/// CAS wiring — the push path actually sends a baseline and reads the answer.
///
/// `PlaybackReconciler` and `PlaybackSyncCoordinator` are both fully tested in isolation
/// and both were, until this commit, connected to nothing: every push site sent
/// `baseVersion: nil` (legacy last-write-wins) and the `/playback/sync` response was
/// discarded. The server's Channel B — which persists a sheet-worthy divergence so the
/// conflict UI can appear at all — is inert until a client sends a baseline, so "all the
/// unit tests pass" was true while the feature did nothing end to end.
///
/// These tests drive the real `PlayerManager` push method against a mock `SyncClient` and
/// assert on what went **out on the wire** and what changed **in the store** — the two
/// places the previous green suite could not see.
import XCTest
import SwiftData
@testable import YourPods

@MainActor
final class PlaybackCASWiringTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!
    private var podcastManager: PodcastManager!
    private var settingsManager: SettingsManager!
    private var tempDir: URL!
    private var store: PlaybackBaselineStore!

    private let epUrl = "https://cdn.example.com/ep1.mp3"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        // This class builds a `PlayerManager` (which restores the persisted current item)
        // and sets `currentItem` directly, so it is both a reader and a potential writer.
        clearAudioPersistenceDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        podcastManager = PodcastManager(modelContext: context)
        settingsManager = SettingsManager()
        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cas-wiring-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = PlaybackBaselineStore(fileURL: tempDir.appendingPathComponent("baselines.json"))
        playerManager.playbackBaselines = store
    }

    override func tearDown() {
        clearTestDefaults()
        clearAudioPersistenceDefaults()
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        tempDir = nil
        settingsManager = nil
        podcastManager = nil
        playerManager = nil
        audioManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "syncConflictStrategy"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private func makeItem(url: String? = nil, position: Int = 828, isPlayed: Bool = false) -> QueueItem {
        var item = QueueItem(
            id: "guid-1",
            title: "Episode One",
            podcastTitle: "Test Pod",
            audioUrl: url ?? epUrl,
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: position,
            podcastUrl: "https://example.com/feed.xml",
            pubDate: nil
        )
        item.isPlayed = isPlayed
        return item
    }

    private func push(
        item: QueueItem,
        client: CASMockSyncClient,
        nowPlaying: Bool = false,
        completed: Bool? = nil,
        attempt: Int = 1
    ) async {
        await playerManager.pushPlaybackWithCAS(
            item: item,
            positionSec: Double(item.positionSeconds),
            nowPlaying: nowPlaying,
            completed: completed,
            client: client,
            eventTime: Date(timeIntervalSince1970: 1_700_000_000),
            attempt: attempt
        )
    }

    // MARK: - baseVersion goes out

    func test_push_carriesTheStoredBaselineAsBaseVersion() async {
        store.recordAgreement(episodeUrl: epUrl, version: 42, completed: false)
        let client = CASMockSyncClient()

        await push(item: makeItem(), client: client)

        let sent = await client.pushes
        XCTAssertEqual(sent.first?.baseVersion, 42)
    }

    /// `0` means "I believe no row exists" and conflicts; an **omitted** `baseVersion` is
    /// the legacy last-write-wins path. Sending `nil` here is what made every previous
    /// build silently opt out of CAS — the bug this commit exists to fix.
    func test_push_withNoBaseline_sendsTheZeroSentinel_notNil() async {
        let client = CASMockSyncClient()

        await push(item: makeItem(), client: client)

        let sent = await client.pushes
        XCTAssertEqual(sent.first?.baseVersion, 0)
        XCTAssertNotNil(sent.first?.baseVersion, "nil is legacy LWW — it opts this episode out of CAS entirely")
    }

    // MARK: - the flags go out explicitly

    /// A versioned push is written **verbatim** server-side — `completed =
    /// EXCLUDED.completed`, no merge, no `GREATEST`, no event-time predicate — the verbatim
    /// write rule. Go decodes an *absent* `completed` as `false`, and `ProPlaybackSyncRequest`
    /// omits the key when it is nil. So a CAS push that says nothing about completion does
    /// not mean "leave it alone" — it means "this episode is not finished", and the server
    /// writes that over whatever another device just marked played.
    ///
    /// This is why the baseline and the explicit flag are one change and not two: adding a
    /// `baseVersion` to a push that omits `completed` is strictly *worse* than the
    /// versionless push it replaces, because the versionless path merges and this one does
    /// not. Both existing CAS call sites pass `completed: nil` today.
    func test_push_alwaysSendsExplicitCompleted_neverOmitsIt() async {
        let client = CASMockSyncClient()

        await push(item: makeItem(), client: client, completed: nil)

        let sent = await client.pushes
        XCTAssertNotNil(
            sent.first?.completed,
            "an omitted `completed` decodes to false and a versioned write applies it verbatim — "
            + "this push un-completes the episode on every device"
        )
    }

    /// What it asserts has to be what the reconciler resolves it against. `pushPlaybackWithCAS`
    /// already builds its `PlaybackSnapshot` from `completed ?? item.isPlayed`; sending `nil`
    /// on the wire meant the server was told `false` while the local ladder believed `true`,
    /// so a conflict came back attributed to the wrong side.
    func test_push_withNoExplicitCompleted_assertsTheItemsOwnPlayedState() async {
        let client = CASMockSyncClient()

        await push(item: makeItem(isPlayed: true), client: client, completed: nil)

        let sent = await client.pushes
        XCTAssertEqual(sent.first?.completed, true,
                       "the snapshot this push is reconciled against says completed — the wire must say it too")
    }

    /// The mirror case: an unplayed episode must assert `false`, not fall silent. Explicit
    /// `false` is safe precisely *because* it is versioned — if another device completed the
    /// episode the version moved, this push conflicts, and `resolveCompleted` attributes the
    /// flip to the side that actually made it.
    func test_push_forAnUnplayedItem_assertsCompletedFalse() async {
        let client = CASMockSyncClient()

        await push(item: makeItem(isPlayed: false), client: client, completed: nil)

        let sent = await client.pushes
        XCTAssertEqual(sent.first?.completed, false)
    }

    // MARK: - the answer comes back in

    func test_ack_advancesTheStoredBaseline() async {
        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 1,
            accepted: [.init(episodeUrl: epUrl, version: 43)],
            conflicts: []
        ))

        await push(item: makeItem(), client: client)

        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 43)
    }

    /// Ladder (d) under `.ask` — the divergence reaches the user. This is the end the
    /// whole feature exists for, and it has never once run.
    func test_conflict_neitherPlaying_underAsk_reachesPendingConflicts() async {
        settingsManager.syncConflictStrategy = .ask
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 0,
            accepted: [],
            conflicts: [.init(episodeUrl: epUrl, server: .init(
                positionSec: 2167, completed: false, nowPlaying: false, version: 12))]
        ))

        await push(item: makeItem(position: 828), client: client)

        XCTAssertEqual(playerManager.pendingConflicts.count, 1)
        XCTAssertEqual(playerManager.pendingConflicts.first?.localPosition, 828)
        XCTAssertEqual(playerManager.pendingConflicts.first?.serverPosition, 2167)
        XCTAssertEqual(playerManager.pendingConflicts.first?.episodeGuid, "guid-1")
    }

    func test_conflict_resolvingToAdopt_writesThePositionLocally() async {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)
        let item = makeItem(position: 828)
        audioManager.currentItem = item

        let client = CASMockSyncClient()
        // Within the 5s tolerance, server larger → adopt silently.
        await client.setResponse(ProPlaybackSyncResponse(
            count: 0,
            accepted: [],
            conflicts: [.init(episodeUrl: epUrl, server: .init(
                positionSec: 831, completed: false, nowPlaying: false, version: 12))]
        ))

        await push(item: item, client: client)

        XCTAssertEqual(audioManager.currentPosition, 831, accuracy: 0.01)
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 12)
    }

    /// An adopt that lands after the user has moved on must not write episode A's position
    /// onto episode B. Silent cross-episode position corruption is the exact defect class
    /// this contract exists to eliminate.
    func test_EDGE_adopt_doesNotWritePosition_whenTheItemChangedMidFlight() async {
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)
        let item = makeItem(position: 828)
        audioManager.currentItem = makeItem(url: "https://cdn.example.com/OTHER.mp3", position: 10)
        audioManager.currentPosition = 10

        let client = CASMockSyncClient()
        await client.setResponse(ProPlaybackSyncResponse(
            count: 0,
            accepted: [],
            conflicts: [.init(episodeUrl: epUrl, server: .init(
                positionSec: 831, completed: false, nowPlaying: false, version: 12))]
        ))

        await push(item: item, client: client)

        XCTAssertEqual(audioManager.currentPosition, 10, accuracy: 0.01,
                       "the now-playing episode changed — its position is not ours to overwrite")
    }

    /// The device won, so it must re-push with the version the *conflict* reported, and the
    /// baseline may only advance when that second push is acked.
    func test_conflict_resolvingToLocal_rePushesWithTheConflictVersion() async {
        settingsManager.syncConflictStrategy = .deviceWins
        store.recordAgreement(episodeUrl: epUrl, version: 5, completed: false)

        let client = CASMockSyncClient()
        await client.setResponses([
            ProPlaybackSyncResponse(count: 0, accepted: [], conflicts: [
                .init(episodeUrl: epUrl, server: .init(
                    positionSec: 2167, completed: false, nowPlaying: false, version: 12))
            ]),
            ProPlaybackSyncResponse(count: 1, accepted: [.init(episodeUrl: epUrl, version: 13)], conflicts: [])
        ])

        await push(item: makeItem(position: 828), client: client)

        let sent = await client.pushes
        XCTAssertEqual(sent.count, 2, "a local win must be re-pushed, not just decided")
        XCTAssertEqual(sent.last?.baseVersion, 12)
        XCTAssertEqual(sent.last?.positionSec, 828)
        XCTAssertEqual(store.baseline(for: epUrl)?.syncedVersion, 13, "advances on the re-push's ack")
    }

    /// A server that predates CAS answers with no arrays. That is not an error, and it
    /// must not be treated as one — otherwise upgrading the client breaks every push
    /// against a deployment that hasn't shipped yet.
    func test_serverWithNothingToSayAboutCAS_isNotAnError() async {
        let client = CASMockSyncClient()
        await client.setResponse(nil)

        await push(item: makeItem(), client: client)

        XCTAssertTrue(playerManager.pendingConflicts.isEmpty)
        XCTAssertNil(store.baseline(for: epUrl))
    }
}

// MARK: - Mock

/// Records what went out and replays a scripted sequence of answers.
actor CASMockSyncClient: SyncClient {

    struct Push: Equatable {
        let episodeUrl: String
        let positionSec: Double
        let baseVersion: Int64?
        let nowPlaying: Bool?
        let completed: Bool?
    }

    private(set) var pushes: [Push] = []
    private var responses: [ProPlaybackSyncResponse?] = []

    func setResponse(_ response: ProPlaybackSyncResponse?) {
        responses = [response]
    }

    func setResponses(_ list: [ProPlaybackSyncResponse?]) {
        responses = list
    }

    @discardableResult
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
        pushes.append(Push(
            episodeUrl: episodeUrl,
            positionSec: positionSec,
            baseVersion: baseVersion,
            nowPlaying: nowPlaying,
            completed: completed
        ))
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }

    // MARK: - Stubs

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        QueueSyncResult(items: items, droppedItems: [])
    }
    var supportsSettingsSync: Bool { false }
}

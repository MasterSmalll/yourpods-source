/// Apply-side playback-position tests, per the sync contract.
///
/// A sync bug we hit: web pushed 2167.4s, the server
/// stored it and served it to iOS four times, and iOS kept displaying 828s and
/// re-pushing 828 seven times in 70 seconds. The reconcile *decision* was already
/// correct — `performReconciliation` Case 3 logged "adopting server position" —
/// but the adopt wrote only `currentItem.positionSeconds` and issued an
/// `AVPlayer.seek`. With no `AVPlayerItem` loaded (an episode restored into the
/// mini player but never played this launch — exactly the reported state) that
/// seek is a no-op and the periodic time observer never fires, so
/// `AudioManager.currentPosition` — which both the UI and the outbound push read —
/// kept the stale local value forever.
///
/// The sync contract, apply side, now makes this normative: a pulled row whose
/// event time is newer than the client's own last local change MUST be adopted,
/// **including backward**, and MUST NOT be re-pushed afterwards.
import SwiftData
import XCTest
@testable import YourPods

@MainActor
final class PlaybackPositionAdoptTests: XCTestCase {

    // Numbers are the ones from the field report so the regression stays recognisable.
    private static let localPositionSec = 828.0      // 13:48 — what iOS displayed
    private static let serverPositionSec = 2167.4    // 36:07 — what web pushed
    private static let durationSec = 4115.0

    private static let episodeUrl = "https://example.com/ep-1.mp3"
    private static let podcastUrl = "https://example.com/feed.xml"

    /// The device's frozen last-local-change time (paused → this is what it reports).
    private static let localEventTime = Date(timeIntervalSince1970: 1_785_373_200)  // 01:00:00
    /// Web's write, ~27 minutes later — strictly newer, so iOS must adopt.
    private static let newerServerTime = Date(timeIntervalSince1970: 1_785_374_808) // 01:26:48
    /// A server row older than the local change — iOS must NOT adopt.
    private static let olderServerTime = Date(timeIntervalSince1970: 1_785_372_000) // 00:40:00

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private let testProfileId = "test-profile-adopt"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        // Injected clock: `init` stamps playbackEventTime from it, so the device's
        // frozen event time is deterministic rather than "whenever setUp ran".
        audioManager = AudioManager(now: { Self.localEventTime })
        playerManager = PlayerManager(audioManager: audioManager)
        podcastManager = PodcastManager(modelContext: context)
        settingsManager = SettingsManager()

        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager
        podcastManager.settingsManager = settingsManager
        settingsManager.syncConflictStrategy = .serverWins

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
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        podcastManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        // `syncConflictStrategy` belongs here because setUp writes `.serverWins` into the
        // *standard* suite. Omitting it left every later test in the same process running
        // under serverWins instead of the default `.ask` — which shows up as
        // `StrategyBypassTests.test_defaultConflictStrategy_isAsk` failing whenever the
        // two classes share a worker clone, but silently changes conflict behaviour for
        // every conflict-related test that follows, which is the worse half.
        for key in ["activeProfileId", "serverProfiles", "episodeActionMap",
                    "savedQueue", "savedCurrentItem", "savedCurrentPosition",
                    "savedPlaybackEventTime", "syncConflictStrategy"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func serverState(
        positionSec: Double = serverPositionSec,
        updatedAt: Date? = newerServerTime
    ) -> ProPlaybackState {
        ProPlaybackState(
            podcastUrl: Self.podcastUrl,
            episodeUrl: Self.episodeUrl,
            episodeGuid: "ep-1",
            positionSec: positionSec,
            durationSec: Self.durationSec,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: updatedAt.map { Self.iso.string(from: $0) },
            nowPlaying: true,
            completed: false,
            hidden: nil
        )
    }

    /// Loads the episode the way a relaunch does: `currentItem` present, position
    /// restored, and **no `AVPlayerItem` loaded** — the state the report describes.
    private func loadRestoredButUnplayedEpisode() {
        audioManager.currentItem = QueueItem(
            id: "ep-1",
            title: "Episode 1",
            podcastTitle: "Podcast",
            audioUrl: Self.episodeUrl,
            artworkUrl: nil,
            durationSeconds: Int(Self.durationSec),
            positionSeconds: Int(Self.localPositionSec),
            podcastUrl: Self.podcastUrl,
            pubDate: nil
        )
        audioManager.currentPosition = Self.localPositionSec
        audioManager.isPlaying = false
    }

    /// Waits for a fire-and-forget playback push to land on the spy.
    private func waitForPlaybackSync(_ spy: ReconcileSpy, timeout: TimeInterval = 2.0) async -> ReconcileSpy.PlaybackSyncCall? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let call = await spy.lastPlaybackSync { return call }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await spy.lastPlaybackSync
    }

    // MARK: - The adopt must reach `currentPosition`

    /// THE REGRESSION. Server holds 2167.4 with a newer event time; iOS is paused at
    /// 828 with no player item loaded. `currentPosition` is what the UI renders and
    /// what the outbound push reads, so an adopt that never reaches it is invisible.
    func test_reconcile_adoptsServerPosition_intoCurrentPosition_whenNoPlayerItemIsLoaded() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(serverState())
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertEqual(audioManager.currentPosition, Self.serverPositionSec, accuracy: 1.0,
                       "AVPlayer.seek is a no-op with no loaded item, so the adopt must write currentPosition explicitly — it is what the UI and the outbound push read")
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, Int(Self.serverPositionSec),
                       "The queue item's frozen position must be adopted too, so persistence and cold-start play() use the server value")
    }

    // MARK: - The superseded local position must never be re-pushed

    /// iOS re-asserted 828 five more times *after* receiving 2167.4. The sync contract:
    /// a client "MUST NOT re-push its superseded local position afterwards" — and because
    /// a re-push carries a fresh event time, doing so silently destroys the newer state.
    func test_reconcile_pushCarriesAdoptedPosition_notSupersededLocalPosition() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(serverState())
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()
        playerManager.syncNowPlayingToProServer()

        let call = await waitForPlaybackSync(spy)
        XCTAssertEqual(call?.positionSec ?? -1, Self.serverPositionSec, accuracy: 1.0,
                       "The push after an adopt must carry the adopted position, not the superseded local one")
    }

    /// The sync contract: adopting must not make this device look like the live source.
    /// A fresh event time on a position we did not originate outranks the device that did.
    func test_reconcile_doesNotStampFreshLocalEventTime_whenAdoptingRemotePosition() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(serverState())
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()

        // Equality, not `<=`: with an injected fixed clock a fresh local stamp and no
        // stamp at all look identical, so only "carries the server's time" is a real
        // assertion. Today `seek(to:)` stamps the local clock, so this is red.
        XCTAssertEqual(audioManager.playbackEventTime, Self.newerServerTime,
                       "A remote adopt is not a local playback event — it must carry the server's event time, never a fresh local stamp")
    }

    // MARK: - Backward adoption is required, not corruption

    /// The scenario: a web pause moves iOS's position backward. The sync contract —
    /// "A backward move under a newer event time is not corruption."
    func test_reconcile_adoptsBackwardPosition_whenServerEventTimeIsNewer() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(serverState(positionSec: 100))
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertEqual(audioManager.currentPosition, 100, accuracy: 1.0,
                       "A newer server event time must move the playhead backward as readily as forward")
    }

    // MARK: - Freshness gate

    /// The gate that keeps the now-working adopt from clobbering a fresh local seek:
    /// `syncPlaybackChain` pre-fetches server state *before* pushing local, then
    /// reconciles against that pre-push snapshot. Without this guard a user who seeks
    /// and immediately syncs pushes their new position, has it accepted, and then has
    /// it overwritten by the stale pre-fetch.
    func test_reconcile_doesNotAdopt_whenLocalEventTimeIsNewerThanServerUpdatedAt() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(serverState(updatedAt: Self.olderServerTime))
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertEqual(audioManager.currentPosition, Self.localPositionSec, accuracy: 1.0,
                       "A server row older than this device's last local change must not overwrite it — our own push is the newer truth")
    }

    /// EDGE: the skew allowance must not swallow a *recent* local change. A backward
    /// seek is the dangerous case and it does not self-heal: our push lands verbatim
    /// (fresh event time + nowPlaying), but if we then adopt the pre-push snapshot we
    /// re-push the older position carrying the server's *older* event time, so the merge
    /// falls to `GREATEST` and the higher — wrong — position wins permanently.
    func test_reconcile_doesNotAdopt_whenLocalChangeIsOnlySecondsNewerThanServerRow() async {
        let spy = ReconcileSpy()
        // Row written 30s before this device's last local change — our own echo from a
        // previous cycle, not another device reporting something newer.
        await spy.setCurrentPlaybackResponse(
            serverState(positionSec: 2000, updatedAt: Self.localEventTime.addingTimeInterval(-30))
        )
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertEqual(audioManager.currentPosition, Self.localPositionSec, accuracy: 1.0,
                       "A row older than this device's own last change must not be adopted — the clock-skew allowance must stay far below a plausible local-edit interval")
    }

    /// EDGE: no `updatedAt` on the row → fail open and adopt. Declining is not a safe
    /// default under the sync contract: it strands two devices at different playheads
    /// with no path to converge, which is the bug being fixed here.
    func test_reconcile_adopts_whenServerUpdatedAtIsMissing() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(serverState(updatedAt: nil))
        playerManager.setSyncClient(spy, deviceId: "test-device")
        loadRestoredButUnplayedEpisode()

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertEqual(audioManager.currentPosition, Self.serverPositionSec, accuracy: 1.0,
                       "An unparseable/absent event time must fail open to adopting — declining strands the devices")
    }
}

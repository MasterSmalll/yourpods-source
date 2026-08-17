/// Unified Playback Sync Tests — NowPlaying, Reconciliation, Cross-Device, Improvements
import SwiftData
import XCTest
@testable import YourPods

// MARK: - From NowPlayingSyncTests.swift

// MARK: - Model Encoding/Decoding Tests

/// Tests for the `nowPlaying` field added to ProPlaybackSyncRequest and ProPlaybackState.
final class NowPlayingSyncTests: XCTestCase {

    // `PlayerManager.init` calls `AudioManager.restoreQueue()`, so the no-op tests below
    // assert against whatever a previously-scheduled class persisted unless this runs.
    override func setUp() {
        super.setUp()
        clearAudioPersistenceDefaults()
    }

    override func tearDown() {
        clearAudioPersistenceDefaults()
        super.tearDown()
    }

    // MARK: - ProPlaybackSyncRequest Encoding

    func test_ProPlaybackSyncRequest_encodesNowPlayingTrue() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "guid-1",
            positionSec: 300,
            durationSec: 3600,
            nowPlaying: true,
            completed: nil,
            deviceId: nil
        )
        
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(dict["nowPlaying"] as? Bool, true,
                       "nowPlaying: true must be encoded in the JSON payload")
    }
    
    func test_ProPlaybackSyncRequest_encodesNowPlayingFalse() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil,
            positionSec: 0,
            durationSec: nil,
            nowPlaying: false,
            completed: nil,
            deviceId: nil
        )
        
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(dict["nowPlaying"] as? Bool, false,
                       "nowPlaying: false must be encoded in the JSON payload")
    }
    
    func test_ProPlaybackSyncRequest_omitsNowPlayingWhenNil() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil,
            positionSec: 0,
            durationSec: nil,
            nowPlaying: nil,
            completed: nil,
            deviceId: nil
        )
        
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        // When nil, the key should either be absent or null — not `false`
        // Codable encodes Optional as null by default; verify it's not `false`
        XCTAssertNil(dict["nowPlaying"] as? Bool,
                     "nowPlaying: nil should not encode as a boolean value")
    }
    
    // MARK: - ProPlaybackState Decoding
    
    func test_ProPlaybackState_decodesNowPlayingTrue() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "positionSec": 300,
            "nowPlaying": true
        }
        """.data(using: .utf8)!
        
        let state = try JSONDecoder().decode(ProPlaybackState.self, from: json)
        XCTAssertEqual(state.nowPlaying, true,
                       "nowPlaying: true must be decoded from server response")
    }
    
    func test_ProPlaybackState_decodesNowPlayingFalse() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "positionSec": 300,
            "nowPlaying": false
        }
        """.data(using: .utf8)!
        
        let state = try JSONDecoder().decode(ProPlaybackState.self, from: json)
        XCTAssertEqual(state.nowPlaying, false)
    }
    
    func test_ProPlaybackState_decodesNilWhenFieldMissing() throws {
        // Backward compat: server may not return nowPlaying field
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "positionSec": 300
        }
        """.data(using: .utf8)!
        
        let state = try JSONDecoder().decode(ProPlaybackState.self, from: json)
        XCTAssertNil(state.nowPlaying,
                     "Missing nowPlaying field must decode as nil for backward compat")
    }
    
    // MARK: - PlayerManager: syncNowPlayingToProServer
    
    @MainActor
    func test_syncNowPlayingToProServer_noOp_whenNoCurrentItem() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        // No current item — should not crash
        XCTAssertNil(audioManager.currentItem)
        playerManager.syncNowPlayingToProServer(nowPlaying: true)
        // No assertion needed — just verifying no crash
    }
    
    @MainActor
    func test_syncNowPlayingToProServer_noOp_whenNoProClient() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 300,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        
        // No sync client set — should not crash (gPodder/Vault mode)
        playerManager.syncNowPlayingToProServer(nowPlaying: true)
        // No assertion needed — verifying no crash for non-Pro users
    }
    
    @MainActor
    func test_syncNowPlayingToProServer_noOp_whenGPodderClient() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 300,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        
        // Set a gPodder client — nowPlaying sync should be no-op
        let gPodderClient = GPodderClient(baseUrl: "https://gpodder.example.com", username: "test", password: "pass")
        playerManager.setSyncClient(gPodderClient, deviceId: "test-device")
        
        playerManager.syncNowPlayingToProServer(nowPlaying: true)
        // No crash = pass. The method should silently skip for gPodder clients.
    }
    
    // MARK: - PlayerManager: restoreNowPlayingFromProServer
    
    @MainActor
    func test_restoreNowPlayingFromProServer_noOp_whenEpisodeAlreadyLoaded() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let item = QueueItem(
            id: "ep-existing", title: "Already Playing", podcastTitle: "Pod",
            audioUrl: "https://example.com/existing.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 500,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item
        
        // When an episode is already loaded, restore should be a no-op
        await playerManager.restoreNowPlayingFromProServer()
        
        XCTAssertEqual(audioManager.currentItem?.id, "ep-existing",
                       "Restore must not replace an already-loaded episode")
    }
    
    @MainActor
    func test_restoreNowPlayingFromProServer_noOp_whenNoProClient() async {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        
        // No sync client — should complete without crash
        await playerManager.restoreNowPlayingFromProServer()
        
        XCTAssertNil(audioManager.currentItem,
                     "No episode should be loaded when there's no Pro client")
    }
    
    // MARK: - Staleness Guard
    
    func test_ProPlaybackState_updatedAt_recentIsNotStale() {
        // An updatedAt within 24h should be considered "recent"
        let recentDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)) // 1 hour ago
        let state = ProPlaybackState(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "guid-1",
            positionSec: 300,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Pod",
            artUrl: nil,
            updatedAt: recentDate,
            nowPlaying: true,
            completed: nil,
            hidden: nil
        )
        
        XCTAssertEqual(state.nowPlaying, true)
        // The staleness check will be in PlayerManager logic, not the model itself
    }
}

// MARK: - From NowPlayingReconciliationTests.swift

/// Tests for `PlayerManager.reconcileNowPlayingWithServer()` — the cross-device
/// episode completion reconciliation added as ProSyncOrchestrator Step 5b.
///
/// Uses the server's `completed` flag as the single source of truth.
/// No client-side heuristics (95% threshold, action map, conflict strategy).
@MainActor
final class NowPlayingReconciliationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-reconcile"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        podcastManager = PodcastManager(modelContext: context)
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()

        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager
        podcastManager.downloadManager = downloadManager
        podcastManager.settingsManager = settingsManager

        // Set up Pro profile
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
        downloadManager = nil
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        podcastManager = nil
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
            "proFirstSyncCompleted_testpro",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeQueueItem(
        id: String = "ep-1",
        title: String = "Episode 1",
        podcastTitle: String = "Podcast",
        audioUrl: String? = nil,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 42,
        durationSeconds: Int = 3600
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: audioUrl ?? "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - Test 1: Server reports completed → mark played, advance

    /// When the server's current playback state has `completed: true`,
    /// the local episode should be marked as played and cleared from the player.
    func test_reconcile_serverCompleted_marksPlayedAndAdvances() async {
        let spy = ReconcileSpy()
        // Server returns a completed episode matching what's locally loaded
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 3600,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: true,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Load a current episode
        audioManager.currentItem = makeQueueItem(id: "ep-1")

        await playerManager.reconcileNowPlayingWithServer()

        // The completed episode should be cleared
        XCTAssertNil(audioManager.currentItem,
                     "Completed episode must be cleared from the player")
    }

    // MARK: - Test 2: Server playing different episode → load server's, preserve local

    /// When the server's now-playing episode is different from the local one,
    /// load the server's episode but do NOT mark the local one as played.
    /// The local episode should remain in the queue for the user to resume later.
    func test_reconcile_serverDifferentEpisode_loadsServerEpisode() async {
        let spy = ReconcileSpy()
        // Server is playing a DIFFERENT episode
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-2.mp3",
            episodeGuid: "ep-2",
            positionSec: 120,
            durationSec: 1800,
            title: "Episode 2",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Load a different current episode locally
        audioManager.currentItem = makeQueueItem(id: "ep-1")

        await playerManager.reconcileNowPlayingWithServer()

        // The server's episode should now be loaded
        XCTAssertEqual(audioManager.currentItem?.audioUrl, "https://example.com/ep-2.mp3",
                       "Server's now-playing episode must be loaded when different from local")
    }

    // MARK: - Test 2b: Server playing different episode → local NOT marked as played

    /// When the server has a different active episode, the local in-progress
    /// episode must NOT be marked as played. It should remain available in the
    /// queue for the user to resume later.
    func test_reconcile_serverDifferentEpisode_doesNotMarkLocalAsPlayed() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-2.mp3",
            episodeGuid: "ep-2",
            positionSec: 120,
            durationSec: 1800,
            title: "Episode 2",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        // Create and persist the local episode in SwiftData so we can check isPlayed
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-1",
            title: "Episode 1",
            audioUrl: "https://example.com/ep-1.mp3",
            podcast: podcast
        )
        episode.isPlayed = false
        episode.listenedSeconds = 120  // 2 minutes in
        context.insert(episode)
        try! context.save()

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1", positionSeconds: 120)

        await playerManager.reconcileNowPlayingWithServer()

        // The local episode must NOT be marked as played
        let fetched = try! context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "ep-1" }))
        XCTAssertFalse(fetched.first?.isPlayed ?? true,
                       "Local in-progress episode must NOT be marked as played when server has a different episode")
    }

    // MARK: - Test 3: Server returns nil → preserve current item (no-op)

    /// When the server has no active playback (nil response), the local
    /// episode must be preserved. Nil means "server has no state" — NOT
    /// "the current episode is completed."
    func test_reconcile_serverNil_preservesCurrentItem() async {
        let spy = ReconcileSpy()
        // Server returns nil — no active playback state
        await spy.setCurrentPlaybackResponse(nil)

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Load a current episode (2 minutes into a 60-minute episode)
        audioManager.currentItem = makeQueueItem(id: "ep-1", positionSeconds: 120, durationSeconds: 3600)

        await playerManager.reconcileNowPlayingWithServer()

        // The episode must be preserved — nil is not evidence of completion
        XCTAssertNotNil(audioManager.currentItem,
                        "Episode must NOT be cleared when server returns nil — nil ≠ completed")
        XCTAssertEqual(audioManager.currentItem?.id, "ep-1",
                       "The original episode must remain loaded")
    }

    // MARK: - Fix B: nil server state + already-played current → clear

    /// When the server returns nil BUT the current item's episode is already
    /// marked played locally (e.g. Fix A applied a server `completed` flag),
    /// the finished item must be cleared from the player — not preserved.
    /// (The existing unplayed-episode nil tests above must still preserve.)
    func test_reconcile_serverNil_clearsAlreadyPlayedCurrentItem() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(nil)

        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-done",
            title: "Done",
            audioUrl: "https://example.com/ep-done.mp3",
            podcast: podcast
        )
        episode.isPlayed = true
        context.insert(episode)
        try! context.save()
        podcastManager.subscriptions = [podcast]

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-done", positionSeconds: 3600, durationSeconds: 3600)

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertNil(audioManager.currentItem,
                     "A finished current item (already isPlayed) must be cleared when the server returns nil")
    }

    // MARK: - Fix D: local-stop paths clear the server now-playing (iOS→web)

    /// Waits for a fire-and-forget playback push to land on the spy.
    private func waitForPlaybackSync(_ spy: ReconcileSpy, timeout: TimeInterval = 2.0) async -> ReconcileSpy.PlaybackSyncCall? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let call = await spy.lastPlaybackSync { return call }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await spy.lastPlaybackSync
    }

    /// Manual "Mark Played" must push completed:true / nowPlaying:false so the
    /// web mini player drops the episode (it previously only wrote a gPodder action).
    func test_markCurrentEpisodeAsPlayed_pushesCompletedToServer() async {
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)
        let episode = Episode(guid: "ep-1", title: "Ep", audioUrl: "https://example.com/ep-1.mp3", podcast: podcast)
        context.insert(episode)
        try! context.save()
        podcastManager.subscriptions = [podcast]

        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        audioManager.currentItem = makeQueueItem(id: "ep-1")

        playerManager.markCurrentEpisodeAsPlayed()  // user-initiated (fromSync = false)

        // Completion now flows through the durable outbox; drain it to assert the eventual push.
        await podcastManager.drainCompletionOutbox(using: spy, baselines: nil)

        let call = await waitForPlaybackSync(spy)
        XCTAssertEqual(call?.episodeUrl, "https://example.com/ep-1.mp3")
        XCTAssertEqual(call?.nowPlaying, false, "manual mark-played must clear server nowPlaying")
        XCTAssertEqual(call?.completed, true, "manual mark-played must mark server completed")
    }

    /// Removing the current episode (without marking played) must push
    /// nowPlaying:false so other devices stop showing it as now-playing.
    func test_removeCurrentEpisodeFromQueue_pushesNowPlayingFalse() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        audioManager.currentItem = makeQueueItem(id: "ep-2")

        playerManager.removeCurrentEpisodeFromQueue()

        let call = await waitForPlaybackSync(spy)
        XCTAssertEqual(call?.episodeUrl, "https://example.com/ep-2.mp3")
        XCTAssertEqual(call?.nowPlaying, false, "removing the current item must clear server nowPlaying")
        XCTAssertNotEqual(call?.completed, true, "remove-without-playing must NOT mark the episode completed")
    }

    // MARK: - Local-stop pushes carry the client event time

    /// A user-initiated local stop must push a `clientUpdatedAt` (the action's event
    /// time) so the server can order this write against other devices and reject it
    /// only if a newer change exists. Without it, a stale push silently wins by
    /// arrival time (the "plane / 3rd device" clobber, Bug 5).
    func test_removeCurrentEpisodeFromQueue_pushesClientEventTime() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")
        audioManager.currentItem = makeQueueItem(id: "ep-2")

        playerManager.removeCurrentEpisodeFromQueue()

        let call = await waitForPlaybackSync(spy)
        XCTAssertNotNil(call?.clientUpdatedAt,
                        "local-stop push must carry the client event time")
    }

    // MARK: - Test 3b: Regression — 2 min in, sync, server nil → episode preserved

    /// Reproduces the exact user-reported bug: user is 2 minutes into an episode,
    /// taps Refresh & Sync, server returns nil (hasn't received the nowPlaying push
    /// yet because it happens later in the sync sequence), and the episode is
    /// incorrectly killed.
    func test_reconcile_serverNil_doesNotMarkInProgressEpisodeAsPlayed() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(nil)

        // Create and persist the episode in SwiftData
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-regression",
            title: "In Progress Episode",
            audioUrl: "https://example.com/ep-regression.mp3",
            durationSeconds: 3600,  // 60 minutes
            podcast: podcast
        )
        episode.isPlayed = false
        episode.listenedSeconds = 120  // 2 minutes in
        context.insert(episode)
        try! context.save()

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(
            id: "ep-regression",
            title: "In Progress Episode",
            audioUrl: "https://example.com/ep-regression.mp3",
            positionSeconds: 120,
            durationSeconds: 3600
        )

        await playerManager.reconcileNowPlayingWithServer()

        // Episode MUST be preserved
        XCTAssertNotNil(audioManager.currentItem,
                        "In-progress episode must survive sync when server returns nil")
        XCTAssertEqual(audioManager.currentItem?.id, "ep-regression")

        // Episode must NOT be marked as played in SwiftData
        let fetched = try! context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "ep-regression" }))
        XCTAssertFalse(fetched.first?.isPlayed ?? true,
                       "2-minute-in episode must NOT be marked as played during sync")
    }

    // MARK: - Test 4: User actively playing → no-op

    /// When the user is actively playing (isPlaying = true), reconciliation
    /// must NOT interrupt playback — even if the server says it's completed.
    func test_reconcile_activePlayback_isNoOp() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 3600,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: true,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")
        audioManager.isPlaying = true  // User is actively playing

        await playerManager.reconcileNowPlayingWithServer()

        // Must NOT clear — active playback takes priority
        XCTAssertNotNil(audioManager.currentItem,
                        "Active playback must never be interrupted by reconciliation")
        XCTAssertEqual(audioManager.currentItem?.id, "ep-1",
                       "The original episode must remain loaded during active playback")
    }

    // MARK: - Test 5: Non-Pro client → no-op

    /// For gPodder/Vault clients, reconciliation is a no-op since
    /// the feature requires the Pro `/playback/current` endpoint.
    func test_reconcile_nonProClient_isNoOp() async {
        let gPodderClient = GPodderClient(
            baseUrl: "https://gpodder.example.com",
            username: "test",
            password: "pass"
        )
        podcastManager.setSyncClient(gPodderClient, deviceId: "test-device")
        playerManager.setSyncClient(gPodderClient, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")

        await playerManager.reconcileNowPlayingWithServer()

        // Must remain unchanged — gPodder doesn't support this
        XCTAssertNotNil(audioManager.currentItem,
                        "Non-Pro client must not trigger reconciliation")
        XCTAssertEqual(audioManager.currentItem?.id, "ep-1")
    }

    // MARK: - Test 6: Empty player — adopt the server's now-playing (web→iOS handoff)

    /// When the player is empty AND the server has no now-playing episode, the
    /// reconcile queries the server (that IS the mechanism for discovering a
    /// cross-device episode) and correctly leaves the player empty.
    ///
    /// NOTE: this replaces an older `test_reconcile_noCurrentItem_isNoOp` that
    /// asserted the empty-player path must NOT call getCurrentPlayback. That
    /// optimization was the bug: it meant a now-playing episode set on the web
    /// could never be adopted into an empty iOS mini player. Querying the server
    /// on an empty player is now intended.
    func test_reconcile_emptyPlayer_serverEmpty_staysEmpty() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(nil)
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // No current item loaded
        XCTAssertNil(audioManager.currentItem)

        await playerManager.reconcileNowPlayingWithServer()

        let wasCalled = await spy.getCurrentPlaybackCalled
        XCTAssertTrue(wasCalled,
                      "Empty-player reconcile must query the server to discover a web-set now-playing")
        XCTAssertNil(audioManager.currentItem,
                     "Empty player must stay empty when the server has no now-playing episode")
    }

    /// Empty player + server now-playing (set on the web) → the parameterless
    /// reconcile path also adopts it (mirrors the preFetched-overload coverage in
    /// ForegroundSyncCompletionTests, exercising the relaxed empty-player guard).
    func test_reconcile_emptyPlayer_adoptsServerNowPlaying() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/web-ep.mp3",
            episodeGuid: "web-ep",
            positionSec: 300,
            durationSec: 1800,
            title: "Played on Web",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        XCTAssertNil(audioManager.currentItem)

        await playerManager.reconcileNowPlayingWithServer()

        XCTAssertEqual(audioManager.currentItem?.audioUrl, "https://example.com/web-ep.mp3",
                       "Empty player must adopt the server's now-playing via the parameterless reconcile path too")
        XCTAssertFalse(audioManager.isPlaying,
                       "Adopted episode must load paused")
    }

    // MARK: - Model Tests: completed field encoding/decoding

    func test_ProPlaybackSyncRequest_encodesCompletedTrue() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "guid-1",
            positionSec: 3600,
            durationSec: 3600,
            nowPlaying: false,
            completed: true,
            deviceId: nil
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["completed"] as? Bool, true,
                       "completed: true must be encoded in the JSON payload")
        XCTAssertEqual(dict["nowPlaying"] as? Bool, false,
                       "nowPlaying: false must accompany completed: true")
    }

    func test_ProPlaybackSyncRequest_omitsCompletedWhenNil() throws {
        let request = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil,
            positionSec: 300,
            durationSec: 3600,
            nowPlaying: true,
            completed: nil,
            deviceId: nil
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // When nil, the key should be absent or null — not false
        XCTAssertNil(dict["completed"] as? Bool,
                     "completed: nil should not encode as a boolean value")
    }

    func test_ProPlaybackState_decodesCompletedTrue() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "positionSec": 3600,
            "completed": true,
            "nowPlaying": false
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(ProPlaybackState.self, from: json)
        XCTAssertEqual(state.completed, true,
                       "completed: true must be decoded from server response")
    }

    func test_ProPlaybackState_decodesCompletedMissing() throws {
        // Backward compat: server may not return completed field
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "positionSec": 300,
            "nowPlaying": true
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(ProPlaybackState.self, from: json)
        XCTAssertNil(state.completed,
                     "Missing completed field must decode as nil for backward compat")
    }

    // MARK: - restoreNowPlaying skips completed

    func test_restoreNowPlaying_skipsCompletedEpisodes() async {
        let spy = ReconcileSpy()
        // Server returns a completed episode with nowPlaying: true
        // (edge case — should still be skipped because completed takes priority)
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-completed.mp3",
            episodeGuid: "ep-completed",
            positionSec: 3600,
            durationSec: 3600,
            title: "Completed Episode",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: true,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // No current item — restore would normally load it
        XCTAssertNil(audioManager.currentItem)

        await playerManager.restoreNowPlayingFromProServer()

        XCTAssertNil(audioManager.currentItem,
                     "restoreNowPlaying must NOT load a completed episode")
    }

    // MARK: - fromSync: Prevents outbound action echo

    /// When reconcileNowPlayingWithServer detects completed=true from the server,
    /// markCurrentEpisodeAsPlayed(fromSync: true) must NOT send an EpisodeAction
    /// back to the server — that would be a redundant echo of what the server just told us.
    func test_reconcile_serverCompleted_doesNotSendEpisodeActionBack() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 3600,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: true,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")

        await playerManager.reconcileNowPlayingWithServer()

        // Wait for any async tasks to settle
        try? await Task.sleep(for: .milliseconds(200))

        // The episode should be cleared (marked as played)
        XCTAssertNil(audioManager.currentItem,
                     "Completed episode must be cleared")

        // No outbound EpisodeAction should have been sent via uploadEpisodeActions.
        // fromSync: true must call markEpisodePlayedLocally (no action) instead of
        // markEpisodeAsPlayed (which sends an action back to the server).
        let uploadCount = await spy.uploadedActionCount
        XCTAssertEqual(uploadCount, 0,
                       "fromSync: true must NOT send an EpisodeAction back to the server — " +
                       "it would be a redundant echo of what the server just told us")
    }

    // NOTE: handleEpisodeCompleted sends completed: true via syncNowPlayingToProServer,
    // which casts to the concrete YourPodsProClient (actor, not subclassable).
    // The completed field encoding is verified by test_ProPlaybackSyncRequest_encodesCompletedTrue.
    // The integration is verified via code inspection:
    //   handleEpisodeCompleted → syncNowPlayingToProServer(nowPlaying: false, completed: true)

    // MARK: - Same-Episode Position Reconciliation (iPad Sync Fix)

    /// When the server has the same episode at a different position and the user
    /// is NOT playing, reconciliation should adopt the server position (serverWins).
    func test_reconcile_sameEpisode_serverWins_updatesPosition() async {
        let spy = ReconcileSpy()
        // Server has the SAME episode at position 300s
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 300,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Local has the same episode at position 0 (stale)
        audioManager.currentItem = makeQueueItem(id: "ep-1", positionSeconds: 0)
        audioManager.isPlaying = false

        // Set strategy to serverWins
        settingsManager.syncConflictStrategy = .serverWins
        playerManager.settingsManager = settingsManager

        await playerManager.reconcileNowPlayingWithServer()

        // Position must be updated to server's 300s
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 300,
                       "serverWins must adopt server position (300s) for same episode")
    }

    /// When deviceWins, reconciliation should keep the local position.
    func test_reconcile_sameEpisode_deviceWins_keepsPosition() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 300,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1", positionSeconds: 100)
        audioManager.isPlaying = false

        settingsManager.syncConflictStrategy = .deviceWins
        playerManager.settingsManager = settingsManager

        await playerManager.reconcileNowPlayingWithServer()

        // Position must stay at 100 (local wins)
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 100,
                       "deviceWins must keep local position (100s)")
    }

    /// When positions differ by ≤10 seconds, no reconciliation needed (noise filter).
    func test_reconcile_sameEpisode_smallDiff_noOp() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 45,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1", positionSeconds: 42)
        audioManager.isPlaying = false

        settingsManager.syncConflictStrategy = .serverWins
        playerManager.settingsManager = settingsManager

        await playerManager.reconcileNowPlayingWithServer()

        // Position should NOT change — diff is only 3s (≤10s threshold)
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 42,
                       "Differences ≤10s should be ignored as noise")
    }

    /// When the user IS playing and the server has a different episode,
    /// reconciliation should NOT interrupt — log and defer to queue sync.
    func test_reconcile_differentEpisode_isPlaying_preservesLocal() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-2.mp3",
            episodeGuid: "ep-2",
            positionSec: 120,
            durationSec: 1800,
            title: "Different Episode",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")
        audioManager.isPlaying = true  // Actively playing

        await playerManager.reconcileNowPlayingWithServer()

        // Must NOT switch — user is playing
        XCTAssertEqual(audioManager.currentItem?.id, "ep-1",
                       "Must NOT interrupt active playback to switch episodes")
    }

    /// When the user is PAUSED and the server has a different episode,
    /// reconciliation should switch to the server's episode.
    func test_reconcile_differentEpisode_paused_switchesToServer() async {
        let spy = ReconcileSpy()
        await spy.setCurrentPlaybackResponse(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-2.mp3",
            episodeGuid: "ep-2",
            positionSec: 120,
            durationSec: 1800,
            title: "Different Episode",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        ))

        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")
        audioManager.isPlaying = false  // Paused

        await playerManager.reconcileNowPlayingWithServer()

        // Should switch to server's episode
        XCTAssertEqual(audioManager.currentItem?.audioUrl, "https://example.com/ep-2.mp3",
                       "When paused, should switch to server's now-playing episode")
    }
}

// MARK: - Spy for Reconciliation Tests

/// A spy that conforms to `SyncClient` for testing reconciliation.
/// Since `YourPodsProClient` is an actor and can't be subclassed,
/// reconciliation uses the `SyncClient.getCurrentPlayback()` protocol method.
actor ReconcileSpy: SyncClient {
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { false }
    var supportsPlaybackReconciliation: Bool { true }

    private var _currentPlaybackResponse: ProPlaybackState?
    private(set) var getCurrentPlaybackCalled = false

    /// Tracks the order of calls: "getCurrentPlayback" or "syncPlayback"
    private(set) var callOrder: [String] = []

    struct PlaybackSyncCall {
        let podcastUrl: String
        let episodeUrl: String
        let nowPlaying: Bool?
        let completed: Bool?
        var clientUpdatedAt: Date? = nil
        /// Captured so apply-side tests can prove a push carries the *adopted*
        /// position rather than a superseded local one (per the sync contract).
        var positionSec: Double? = nil
    }
    private(set) var lastPlaybackSync: PlaybackSyncCall?

    func setCurrentPlaybackResponse(_ state: ProPlaybackState?) {
        _currentPlaybackResponse = state
    }

    func getCurrentPlayback() async throws -> ProPlaybackState? {
        getCurrentPlaybackCalled = true
        callOrder.append("getCurrentPlayback")
        return _currentPlaybackResponse
    }

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
        callOrder.append("syncPlayback")
        lastPlaybackSync = PlaybackSyncCall(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            nowPlaying: nowPlaying,
            completed: completed,
            clientUpdatedAt: clientUpdatedAt,
            positionSec: positionSec
        )
        return nil
    }

    /// Tracks syncPlayback calls WITH the completed field.
    /// Called directly by tests that verify syncNowPlayingToProServer behavior.
    func recordPlaybackSync(podcastUrl: String, episodeUrl: String, nowPlaying: Bool?, completed: Bool?) {
        lastPlaybackSync = PlaybackSyncCall(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            nowPlaying: nowPlaying,
            completed: completed
        )
    }

    // MARK: - Unused protocol stubs
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    private(set) var uploadedActionCount = 0
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        uploadedActionCount += actions.count
        return []
    }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: items, droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func deleteQueueItem(episodeUrl: String) async throws {}
}

// MARK: - From CrossDeviceSyncBugTests.swift

/// Regression tests for three cross-device sync bugs:
///
/// Bug 1: `completed: true` sent for the wrong episode (reads currentItem after auto-advance)
/// Bug 2: Previous episode's `nowPlaying` not cleared when switching tracks
/// Bug 3: Queue sync pushes the whole queue on a fresh device / doesn't restore currentItem
@MainActor
final class CrossDeviceSyncBugTests: XCTestCase {

    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!
    private var podcastManager: PodcastManager!
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        UserDefaults.standard.removeObject(forKey: "proQueueSyncCompleted")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        podcastManager = PodcastManager(modelContext: container.mainContext)
        playerManager.podcastManager = podcastManager
    }

    override func tearDown() {
        playerManager = nil
        audioManager = nil
        podcastManager = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQueueItem(
        id: String = "ep-1",
        title: String = "Episode 1",
        podcastTitle: String = "Podcast",
        audioUrl: String? = nil,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 0,
        durationSeconds: Int = 3600
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: audioUrl ?? "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - Bug 1: completed:true sent for wrong episode

    /// When an episode completes, the `completed: true` flag must be sent
    /// with the FINISHED episode's metadata — not the auto-advanced next episode.
    func test_syncCompletedEpisode_sendsCompletedForFinishedItem() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let finishedItem = makeQueueItem(
            id: "ep-finished",
            title: "Finished Episode",
            audioUrl: "https://example.com/finished.mp3",
            durationSeconds: 3600
        )

        // Simulate: episode just completed, auto-advance already loaded next episode
        let nextItem = makeQueueItem(
            id: "ep-next",
            title: "Next Episode",
            audioUrl: "https://example.com/next.mp3"
        )
        audioManager.currentItem = nextItem

        // Call the new method that takes the completed item explicitly
        playerManager.syncCompletedEpisodeToProServer(finishedItem)

        // Completion now flows through the durable outbox; drain it to assert the eventual push.
        await podcastManager.drainCompletionOutbox(using: spy, baselines: nil)

        // THEN: The completed sync should reference the FINISHED episode, not the current one
        let calls = await spy.playbackSyncCalls
        let completedCall = calls.first { $0.completed == true }
        XCTAssertNotNil(completedCall, "A completed: true call must be sent")
        XCTAssertEqual(completedCall?.episodeGuid, "ep-finished",
                       "completed: true must reference the finished episode, not the auto-advanced one")
        XCTAssertEqual(completedCall?.nowPlaying, false,
                       "completed episode must have nowPlaying: false")
    }

    /// The completed sync must include the correct position (= duration) for the finished episode.
    func test_syncCompletedEpisode_sendsCorrectPosition() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let finishedItem = makeQueueItem(
            id: "ep-finished",
            title: "Finished Episode",
            durationSeconds: 1800
        )

        playerManager.syncCompletedEpisodeToProServer(finishedItem)

        // Completion now flows through the durable outbox; drain it to assert the eventual push.
        await podcastManager.drainCompletionOutbox(using: spy, baselines: nil)

        let calls = await spy.playbackSyncCalls
        let completedCall = calls.first { $0.completed == true }
        XCTAssertNotNil(completedCall)
        // Position should equal duration (episode is fully played)
        XCTAssertEqual(completedCall?.positionSec, 1800,
                       "Completed episode position should equal its duration")
        XCTAssertEqual(completedCall?.durationSec, 1800)
    }

    // MARK: - Bug 2: Previous nowPlaying not cleared

    /// When switching to a new episode, the previous episode should get
    /// `nowPlaying: false` sent to the server.
    func test_handleItemChanged_clearsPreviousEpisodeNowPlaying() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let previousItem = makeQueueItem(
            id: "ep-previous",
            title: "Previous Episode",
            audioUrl: "https://example.com/previous.mp3"
        )

        let newItem = makeQueueItem(
            id: "ep-new",
            title: "New Episode",
            audioUrl: "https://example.com/new.mp3"
        )

        // Simulate: user was playing previousItem, then switches to newItem
        audioManager.currentItem = previousItem
        // Set the previous item tracking
        playerManager.trackPreviousItem(previousItem)

        // Now switch to new item (this triggers handleItemChanged internally)
        audioManager.currentItem = newItem
        playerManager.syncNowPlayingToProServer(nowPlaying: true, clearingPrevious: previousItem)

        try? await Task.sleep(for: .milliseconds(200))

        let calls = await spy.playbackSyncCalls

        // Should have a nowPlaying: false call for the previous episode
        let clearCall = calls.first { $0.episodeGuid == "ep-previous" && $0.nowPlaying == false }
        XCTAssertNotNil(clearCall,
                        "Previous episode must have nowPlaying: false sent to server")

        // And a nowPlaying: true call for the new episode
        let newCall = calls.first { $0.episodeGuid == "ep-new" && $0.nowPlaying == true }
        XCTAssertNotNil(newCall,
                        "New episode must have nowPlaying: true sent to server")
    }

    // MARK: - Bug 3: Queue sync on fresh device

    /// Per the sync contract: on a fresh device, syncQueueWithServer adopts the
    /// server queue as Up Next and must NOT treat a sortOrder-0 item as the
    /// now-playing episode. sortOrder 0 is a valid Up Next position — the web
    /// "add to top of queue" feature inserts there (server `AddToQueue addToTop`).
    /// Now-playing is restored separately from the playback channel.
    func test_syncQueueWithServer_freshDevice_adoptsAllAsUpNext_doesNotLiftSortOrderZero() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        await spy.setCurrentPlayback(nil)  // no now-playing on the playback channel
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/top.mp3",
                          episodeGuid: "ep-top", sortOrder: 0, positionSec: 0,
                          title: "Added To Top", podcastTitle: "Great Podcast",
                          durationSec: 3600),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/up-next-1.mp3",
                          episodeGuid: "ep-up-next-1", sortOrder: 1, positionSec: 0,
                          title: "Up Next 1", podcastTitle: "Great Podcast",
                          durationSec: 1800),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/up-next-2.mp3",
                          episodeGuid: "ep-up-next-2", sortOrder: 2, positionSec: 120,
                          title: "Up Next 2", podcastTitle: "Great Podcast",
                          durationSec: 2400),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Verify precondition: fresh device state
        XCTAssertNil(audioManager.currentItem, "Precondition: no current item on fresh device")
        XCTAssertTrue(audioManager.queue.isEmpty, "Precondition: empty queue on fresh device")

        // WHEN
        await playerManager.syncQueueWithServer()

        // THEN: nothing is lifted as now-playing (playback channel had none)
        XCTAssertNil(audioManager.currentItem,
                     "A sortOrder-0 queue item must NOT be mistaken for now-playing")

        // AND: every server item becomes Up Next, in order
        XCTAssertEqual(audioManager.queue.map(\.id), ["ep-top", "ep-up-next-1", "ep-up-next-2"],
                       "All server items (including sortOrder 0) become Up Next")
    }

    /// Per the sync contract: on a fresh device, the now-playing episode is
    /// restored from the playback channel (/playback/current), and if that episode
    /// also appears in the queue (legacy leak), it is excluded from Up Next.
    func test_syncQueueWithServer_freshDevice_restoresNowPlayingFromPlaybackChannel() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        await spy.setCurrentPlayback(ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/now.mp3",
            episodeGuid: "ep-now",
            positionSec: 1234,
            durationSec: 3600,
            title: "Now Playing",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: false,
            hidden: nil
        ))
        await spy.setServerQueue([
            // Legacy leak: the now-playing episode also left in the queue.
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/now.mp3",
                          episodeGuid: "ep-now", sortOrder: 0, positionSec: 1234,
                          title: "Now Playing", podcastTitle: "Podcast", durationSec: 3600),
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/up-next.mp3",
                          episodeGuid: "ep-up-next", sortOrder: 1, positionSec: 0,
                          title: "Up Next", podcastTitle: "Podcast", durationSec: 1800),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        await playerManager.syncQueueWithServer()

        // Now-playing restored from the playback channel, with its position
        XCTAssertEqual(audioManager.currentItem?.id, "ep-now",
                       "Now-playing must be restored from the playback channel")
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 1234,
                       "Restored now-playing must carry its server position")

        // The now-playing episode must NOT also appear in Up Next
        XCTAssertEqual(audioManager.queue.map(\.id), ["ep-up-next"],
                       "Now-playing must be excluded from the adopted Up Next queue")
    }

    /// On a fresh device, syncQueueWithServer should NOT push local auto-queued
    /// items back to the server. The server queue is authoritative.
    func test_syncQueueWithServer_freshDevice_doesNotPushBackToServer() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/ep1.mp3",
                          episodeGuid: "ep-1", sortOrder: 0, positionSec: 500,
                          title: "Episode 1", podcastTitle: "Podcast",
                          durationSec: 3600),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Precondition: fresh device
        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)

        await playerManager.syncQueueWithServer()

        // THEN: syncQueue (POST) should NOT have been called
        // On a fresh device, we adopt wholesale — no push needed
        let syncCalled = await spy.syncQueueCalled
        XCTAssertFalse(syncCalled,
                       "Fresh device should adopt server queue without pushing back")
    }

    /// Regression guard: existing device (has items) should still merge normally.
    func test_syncQueueWithServer_existingDevice_mergesNormally() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([
            QueueSyncItem(podcastUrl: "https://example.com/feed.xml",
                          episodeUrl: "https://example.com/server-ep.mp3",
                          episodeGuid: "ep-server", sortOrder: 1, positionSec: 0,
                          title: "Server Episode", podcastTitle: "Server Podcast"),
        ])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Existing device has a current item and queue
        let currentItem = makeQueueItem(id: "ep-current", title: "Currently Playing")
        audioManager.currentItem = currentItem
        audioManager.appendToQueue([
            makeQueueItem(id: "ep-local", title: "Local Episode")
        ])

        await playerManager.syncQueueWithServer()

        // THEN: Normal merge behavior — local items preserved, server items added
        XCTAssertEqual(audioManager.currentItem?.id, "ep-current",
                       "Existing currentItem must be preserved during normal merge")

        // Push should have been called (normal merge path)
        let syncCalled = await spy.syncQueueCalled
        XCTAssertTrue(syncCalled,
                      "Existing device should push merged queue to server")

        // Both local and server items should be present
        let queueIds = audioManager.queue.map(\.id)
        XCTAssertTrue(queueIds.contains("ep-local"), "Local item must remain")
        XCTAssertTrue(queueIds.contains("ep-server"), "Server item must be merged in")
    }

    /// On a fresh device with an empty server queue, nothing should crash
    /// and the state should remain empty.
    func test_syncQueueWithServer_freshDevice_emptyServerQueue_noOp() async {
        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        await spy.setServerQueue([])
        playerManager.setSyncClient(spy, deviceId: "test-device")

        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)

        await playerManager.syncQueueWithServer()

        XCTAssertNil(audioManager.currentItem, "Empty server queue should leave currentItem nil")
        XCTAssertTrue(audioManager.queue.isEmpty, "Empty server queue should leave queue empty")
    }
}

// MARK: - Spy: Tracks playback sync calls with full parameter capture

/// A spy sync client that captures all playback sync calls with their parameters,
/// including `completed` and `nowPlaying` flags.
actor PlaybackSyncSpy: SyncClient {
    private var _supportsQueueSync: Bool = true
    var supportsQueueSync: Bool { _supportsQueueSync }
    var supportsSettingsSync: Bool { false }

    // Queue tracking
    var syncQueueCalled = false
    var getQueueCalled = false
    var syncedQueueItems: [QueueSyncItem] = []
    private var serverQueue: [QueueSyncItem] = []
    private var syncResponse: [QueueSyncItem]?

    // Playback sync tracking
    struct PlaybackSyncCall {
        let podcastUrl: String
        let episodeUrl: String
        let episodeGuid: String?
        let positionSec: Double
        let durationSec: Double?
        let nowPlaying: Bool?
        let completed: Bool?
        let deviceId: String?
        let clientUpdatedAt: Date?
    }
    var playbackSyncCalls: [PlaybackSyncCall] = []

    // Configurable now-playing response from the playback channel (/playback/current).
    private var _currentPlayback: ProPlaybackState?

    func setSupportsQueue(_ value: Bool) { _supportsQueueSync = value }
    func setServerQueue(_ items: [QueueSyncItem]) { serverQueue = items }
    func setSyncResponse(_ items: [QueueSyncItem]) { syncResponse = items }
    func setCurrentPlayback(_ state: ProPlaybackState?) { _currentPlayback = state }

    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        syncQueueCalled = true
        return QueueSyncResult(items: syncResponse ?? items, droppedItems: [])
    }

    func getQueue() async throws -> [QueueSyncItem] {
        getQueueCalled = true
        return serverQueue
    }

    func deleteQueueItem(episodeUrl: String) async throws {}

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
        playbackSyncCalls.append(PlaybackSyncCall(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid,
            positionSec: positionSec,
            durationSec: durationSec,
            nowPlaying: nowPlaying,
            completed: completed,
            deviceId: deviceId,
            clientUpdatedAt: clientUpdatedAt
        ))
        return nil
    }

    func getCurrentPlayback() async throws -> ProPlaybackState? { _currentPlayback }
    var supportsPlaybackReconciliation: Bool { _currentPlayback != nil }

    // MARK: - Unused protocol stubs
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
}

// MARK: - From PlaybackSyncImprovementTests.swift

/// Tests for playback & sync pipeline improvements:
/// - P1-1: syncPlaybackState uses incremental sync (force: false)
/// - P0-3: Manual seek triggers debounced server sync
/// - P1-4: Queue push only fires on membership/order changes, not position-only
/// - P2-1: Action map pruning (old entries + unsubscribed podcasts)
/// - P1-2: Crash-safe batch episode action uploads
/// - P1-3: Queue dedup assertions
@MainActor
final class PlaybackSyncImprovementTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-sync-improvements"

    override func setUp() {
        super.setUp()
        clearTestDefaults()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        podcastManager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager
        podcastManager.downloadManager = downloadManager
        podcastManager.settingsManager = settingsManager
    }

    override func tearDown() {
        clearTestDefaults()
        downloadManager = nil
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        podcastManager = nil
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
            "syncConflictStrategy",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition",
            "syncConflictCounts",
            "pendingUploadGuids",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @discardableResult
    private func insertPodcast(
        url: String = "https://example.com/feed",
        title: String = "Test Podcast",
        episodeCount: Int = 3
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        try! context.save()
        podcastManager.associateWithCurrentProfile(url: url)
        podcastManager.loadSubscriptions()
        return podcast
    }

    // MARK: - P1-1: syncPlaybackState uses incremental sync

    /// syncPlaybackState should call syncEpisodeActions with force: false
    /// so it only pulls actions since the last sync, not the entire history.
    func test_syncPlaybackState_usesIncrementalSync() async {
        let podcast = insertPodcast()
        let spy = SpySyncClientTrackingForce()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Set a currentItem so syncPlaybackState doesn't bail out
        let item = QueueItem(
            id: podcast.episodes.first!.guid,
            title: "Test",
            podcastTitle: "Test Pod",
            audioUrl: "https://example.com/ep1.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: podcast.url,
            pubDate: nil
        )
        audioManager.currentItem = item

        // WHEN
        await playerManager.syncPlaybackState()

        // THEN: the spy should have been called with since > 0 (incremental)
        // or at minimum, force should have been false
        let sinceCalls = await spy.getEpisodeActionsSinceCalls
        XCTAssertFalse(sinceCalls.isEmpty, "syncPlaybackState should call getEpisodeActions")
        // When force=false and there's a previous sync timestamp, since > 0.
        // When force=true, since=0 (full pull). We set a previous timestamp to verify.
        // First, seed a previous sync timestamp
        UserDefaults.standard.set(1000, forKey: "lastEpisodeActionSync_\(testProfileId)")
        podcastManager.loadActionMap()

        await playerManager.syncPlaybackState()
        let calls2 = await spy.getEpisodeActionsSinceCalls
        // The last call should have since = 1000 (incremental), not 0 (full)
        if let lastSince = calls2.last {
            XCTAssertGreaterThan(lastSince, 0,
                "syncPlaybackState must use incremental sync (since > 0), got since=\(lastSince)")
        }
    }

    // MARK: - P0-3: Seek triggers debounced server sync

    /// When the user seeks, an episode action should be queued for server sync.
    func test_seek_triggersServerSync() async {
        let podcast = insertPodcast()
        let spy = SpySyncClientTrackingForce()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = QueueItem(
            id: podcast.episodes.first!.guid,
            title: "Test",
            podcastTitle: "Test Pod",
            audioUrl: "https://example.com/ep1.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: podcast.url,
            pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.currentPosition = 100

        // WHEN: user seeks
        playerManager.seekAndSync(to: 2000)

        // Wait for debounce (1.5s + small margin)
        try? await Task.sleep(for: .seconds(2.0))

        // THEN: an episode action should have been uploaded
        let uploadCalls = await spy.uploadedActions
        XCTAssertFalse(uploadCalls.isEmpty,
            "Seek should trigger a debounced server sync with episode action upload")
        if let lastAction = uploadCalls.last {
            XCTAssertEqual(lastAction.position, 2000,
                "Uploaded action should contain the seek target position")
        }
    }

    /// Rapid seeks should be debounced — only the last seek position should sync.
    func test_rapidSeeks_areDebouncedToLastPosition() async {
        let podcast = insertPodcast()
        let spy = SpySyncClientTrackingForce()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = QueueItem(
            id: podcast.episodes.first!.guid,
            title: "Test",
            podcastTitle: "Test Pod",
            audioUrl: "https://example.com/ep1.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: podcast.url,
            pubDate: nil
        )
        audioManager.currentItem = item

        // WHEN: user scrubs rapidly through multiple positions
        playerManager.seekAndSync(to: 500)
        playerManager.seekAndSync(to: 1000)
        playerManager.seekAndSync(to: 1500)
        playerManager.seekAndSync(to: 2000)

        // Wait for debounce
        try? await Task.sleep(for: .seconds(2.0))

        // THEN: only one upload, at the LAST position
        let uploadCalls = await spy.uploadedActions
        // Should have at most 1 upload (debounced)
        XCTAssertEqual(uploadCalls.count, 1,
            "Rapid seeks should be debounced to a single upload, got \(uploadCalls.count)")
        XCTAssertEqual(uploadCalls.first?.position, 2000,
            "Debounced upload should contain the final seek position (2000)")
    }

    // MARK: - P2-1: Action map pruning

    /// Prune should remove entries older than 90 days.
    func test_pruneActionMap_removesOldEntries() {
        let now = Int(Date().timeIntervalSince1970)
        let oldTimestamp = now - (91 * 86400) // 91 days ago
        let recentTimestamp = now - (30 * 86400) // 30 days ago

        let podcast = insertPodcast()
        let episodeGuid = podcast.episodes.first!.guid

        // Seed action map with old and recent entries
        let oldAction = EpisodeAction(
            podcast: "https://old.com/feed", episode: "https://old.com/ep.mp3",
            guid: "old-episode-guid", action: "play",
            timestamp: oldTimestamp, position: 100, started: 0, total: 3600, device: "test"
        )
        let recentAction = EpisodeAction(
            podcast: podcast.url, episode: podcast.episodes.first!.audioUrl ?? "",
            guid: episodeGuid, action: "play",
            timestamp: recentTimestamp, position: 200, started: 0, total: 3600, device: "test"
        )
        let map: [String: EpisodeAction] = [
            "old-episode-guid": oldAction,
            episodeGuid: recentAction,
        ]
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        podcastManager.loadActionMap()

        XCTAssertEqual(podcastManager.actionMap.count, 2, "Should start with 2 entries")

        // WHEN
        podcastManager.pruneActionMap()

        // THEN: old entry removed, recent entry kept
        XCTAssertEqual(podcastManager.actionMap.count, 1,
            "Old entry (91 days) should be pruned")
        XCTAssertNotNil(podcastManager.actionMap[episodeGuid],
            "Recent entry should be kept")
        XCTAssertNil(podcastManager.actionMap["old-episode-guid"],
            "Old entry should be removed")
    }

    /// Prune should keep entries for subscribed podcasts even if old.
    func test_pruneActionMap_keepsSubscribedEvenIfOld() {
        let now = Int(Date().timeIntervalSince1970)
        let oldTimestamp = now - (120 * 86400) // 120 days ago

        let podcast = insertPodcast()
        let episodeGuid = podcast.episodes.first!.guid

        let oldButSubscribed = EpisodeAction(
            podcast: podcast.url, episode: podcast.episodes.first!.audioUrl ?? "",
            guid: episodeGuid, action: "play",
            timestamp: oldTimestamp, position: 200, started: 0, total: 3600, device: "test"
        )
        let map: [String: EpisodeAction] = [episodeGuid: oldButSubscribed]
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        podcastManager.loadActionMap()

        // WHEN
        podcastManager.pruneActionMap()

        // THEN: entry is kept because the podcast is still subscribed
        XCTAssertEqual(podcastManager.actionMap.count, 1,
            "Old entry for subscribed podcast should be kept")
    }

    // MARK: - P1-2: Crash-safe batch uploads

    /// Pending upload GUIDs should be tracked and persisted.
    func test_pendingUploadGuids_arePersisted() async {
        let podcast = insertPodcast()
        let spy = SpySyncClientTrackingForce()
        podcastManager.setSyncClient(spy, deviceId: "test-device")

        let action = EpisodeAction(
            podcast: podcast.url, episode: "https://example.com/ep1.mp3",
            guid: podcast.episodes.first!.guid, action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 500, started: 0, total: 3600, device: "test-device"
        )

        // WHEN: action is sent
        podcastManager.bufferEpisodeAction(action)

        // THEN: action should be in the outbox
        XCTAssertFalse(podcastManager.episodeActionSync.outbox.isEmpty,
            "Action should be tracked in the outbox after bufferEpisodeAction")
        XCTAssertNotNil(podcastManager.episodeActionSync.outbox[podcast.episodes.first!.guid],
            "Action GUID should be in the outbox")
    }

    /// Flush should upload all pending actions and clear the pending set on success.
    func test_flushPendingActions_uploadsAndClears() async {
        let podcast = insertPodcast()
        let spy = SpySyncClientTrackingForce()
        podcastManager.setSyncClient(spy, deviceId: "test-device")

        let guid = podcast.episodes.first!.guid
        let action = EpisodeAction(
            podcast: podcast.url, episode: "https://example.com/ep1.mp3",
            guid: guid, action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 500, started: 0, total: 3600, device: "test-device"
        )
        podcastManager.bufferEpisodeAction(action)

        // WHEN: flush
        await podcastManager.flushPendingActions()

        // THEN: outbox should be empty, upload should have occurred
        XCTAssertTrue(podcastManager.episodeActionSync.outbox.isEmpty,
            "Outbox should be cleared after successful flush")
        let uploads = await spy.uploadedActions
        XCTAssertFalse(uploads.isEmpty, "Actions should have been uploaded")
    }

    // MARK: - P1-4: Dirty-tracking for queue push

    /// onQueueMembershipChanged should NOT fire for position-only updates.
    func test_queuePositionUpdate_doesNotFireMembershipChanged() {
        var membershipChangedCount = 0
        audioManager.onQueueMembershipChanged = { membershipChangedCount += 1 }

        // Add items to queue (triggers membership change)
        let item = QueueItem(
            id: "ep-1", title: "Test", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 100,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.appendToQueue([item])
        let addCount = membershipChangedCount

        // WHEN: position-only update
        audioManager.updateQueueItemPosition(id: "ep-1", positionSeconds: 200)

        // THEN: membership count should NOT have increased
        XCTAssertEqual(membershipChangedCount, addCount,
            "Position-only update should NOT fire onQueueMembershipChanged")
    }

    /// Adding an item SHOULD fire onQueueMembershipChanged.
    func test_queueAdd_firesMembershipChanged() {
        var fired = false
        audioManager.onQueueMembershipChanged = { fired = true }

        let item = QueueItem(
            id: "ep-1", title: "Test", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 100,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )

        // WHEN
        audioManager.appendToQueue([item])

        // THEN
        XCTAssertTrue(fired, "Adding item should fire onQueueMembershipChanged")
    }

    /// Removing an item SHOULD fire onQueueMembershipChanged.
    func test_queueRemove_firesMembershipChanged() {
        let item = QueueItem(
            id: "ep-1", title: "Test", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 100,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.appendToQueue([item])

        var fired = false
        audioManager.onQueueMembershipChanged = { fired = true }

        // WHEN
        audioManager.removeFromQueue(item)

        // THEN
        XCTAssertTrue(fired, "Removing item should fire onQueueMembershipChanged")
    }
    // MARK: - forceSyncProgress cancels pending seek debounce

    /// When the app backgrounds during a scrub, forceSyncProgress should
    /// cancel the pending seekSyncTask to prevent a stale/duplicate sync
    /// from firing later and overwriting the position already flushed.
    func test_forceSyncProgress_cancelsPendingSeekDebounce() async {
        let podcast = insertPodcast()
        let spy = SpySyncClientTrackingForce()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let item = QueueItem(
            id: podcast.episodes.first!.guid,
            title: "Test",
            podcastTitle: "Test Pod",
            audioUrl: "https://example.com/ep1.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: podcast.url,
            pubDate: nil
        )
        audioManager.currentItem = item
        audioManager.currentPosition = 100

        // WHEN: user seeks (starts a debounce timer)
        playerManager.seekAndSync(to: 2000)

        // THEN: immediately background — forceSyncProgress fires
        playerManager.forceSyncProgress()

        // Wait for the seek debounce period to expire
        try? await Task.sleep(for: .seconds(2.0))

        // The seek's debounced action should NOT have fired —
        // forceSyncProgress already flushed and cancelled it.
        let uploadCalls = await spy.uploadedActions
        // forceSyncProgress sends 1 action; the debounce should NOT send another
        XCTAssertLessThanOrEqual(uploadCalls.count, 1,
            "forceSyncProgress must cancel pending seekSyncTask — got \(uploadCalls.count) uploads " +
            "instead of at most 1 (the forceSyncProgress action itself)")
    }
}

// MARK: - Spy SyncClient that tracks force/since parameters

actor SpySyncClientTrackingForce: SyncClient {
    var getEpisodeActionsSinceCalls: [Int] = []
    var uploadedActions: [EpisodeAction] = []

    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: Int(Date().timeIntervalSince1970))
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        uploadedActions.append(contentsOf: actions)
        return []
    }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        getEpisodeActionsSinceCalls.append(since)
        return []
    }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
}

// MARK: - Pre-Fetch Reconciliation & Post-Sync Cleanup Tests

/// Tests for the fix where Step 5b's nowPlaying push overwrites the server's
/// completed state before Step 5c can read it, and for post-sync queue cleanup
/// that removes completed episodes from the AudioManager queue.
@MainActor
final class ForegroundSyncCompletionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-profile-fgsync"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        podcastManager = PodcastManager(modelContext: context)
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()

        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager
        podcastManager.downloadManager = downloadManager
        podcastManager.settingsManager = settingsManager

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
        downloadManager = nil
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        podcastManager = nil
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
            "proFirstSyncCompleted_testpro",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeQueueItem(
        id: String = "ep-1",
        title: String = "Episode 1",
        podcastTitle: String = "Podcast",
        audioUrl: String? = nil,
        podcastUrl: String = "https://example.com/feed.xml",
        positionSeconds: Int = 42,
        durationSeconds: Int = 3600
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: audioUrl ?? "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil
        )
    }

    // MARK: - Bug 1: Pre-fetch server state before push

    /// When `reconcileNowPlayingWithServer(preFetchedState:)` receives a pre-fetched
    /// completed state, it must mark the episode as played — even though a fresh
    /// `getCurrentPlayback()` would now return the overwritten state from Step 5b.
    func test_reconcile_preFetchedCompleted_marksPlayedAndAdvances() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")

        // Pre-fetched state: server says this episode is completed (from web player)
        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 3600,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: true,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        // The completed episode must be cleared from the player
        XCTAssertNil(audioManager.currentItem,
                     "Pre-fetched completed state must clear the current episode")
    }

    /// The pre-fetched flow must NOT call getCurrentPlayback() again —
    /// it should use the provided state directly.
    func test_reconcile_preFetched_doesNotCallGetCurrentPlaybackAgain() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        audioManager.currentItem = makeQueueItem(id: "ep-1")

        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-1.mp3",
            episodeGuid: "ep-1",
            positionSec: 3600,
            durationSec: 3600,
            title: "Episode 1",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: true,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        let wasCalled = await spy.getCurrentPlaybackCalled
        XCTAssertFalse(wasCalled,
                       "Pre-fetched path must NOT call getCurrentPlayback() — it uses the provided state")
    }

    // MARK: - Bug 1a: Empty player adopts the server's now-playing (web→iOS handoff)

    /// THE FIX. When iOS has NO current item (queue consumed, or nothing started
    /// this session) and the server reports a fresh now-playing episode that was
    /// set on the web, the routine per-sync reconcile must ADOPT it into the mini
    /// player. Previously `reconcileNowPlayingWithServer(preFetchedState:)` bailed
    /// at the `currentItem != nil` guard, so the web episode was fetched and then
    /// discarded — the user picked up iOS to an empty mini player.
    func test_reconcile_emptyPlayer_adoptsServerNowPlaying() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Precondition: the player is empty (the reported symptom's state)
        XCTAssertNil(audioManager.currentItem)

        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/web-ep.mp3",
            episodeGuid: "web-ep",
            positionSec: 300,
            durationSec: 1800,
            title: "Played on Web",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        XCTAssertEqual(audioManager.currentItem?.audioUrl, "https://example.com/web-ep.mp3",
                       "Empty player must adopt the server's now-playing episode set on the web")
        XCTAssertFalse(audioManager.isPlaying,
                       "Adopted episode must load PAUSED — the user presses play when ready")
    }

    /// The adopted episode must load at the server's last position so the user
    /// resumes exactly where they left off on the web.
    func test_reconcile_emptyPlayer_adoptsAtServerPosition() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/web-ep.mp3",
            episodeGuid: "web-ep",
            positionSec: 754,
            durationSec: 1800,
            title: "Played on Web",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 754,
                       "Adopted episode must resume at the server's last position")
    }

    /// CONSTRAINT (c): a completed server episode must NEVER be resurrected into an
    /// empty player. (The server already filters completed rows out of
    /// /playback/current, but the client guards defensively too.)
    func test_reconcile_emptyPlayer_serverCompleted_doesNotAdopt() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/web-ep.mp3",
            episodeGuid: "web-ep",
            positionSec: 1800,
            durationSec: 1800,
            title: "Finished on Web",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: true,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        XCTAssertNil(audioManager.currentItem,
                     "A completed server episode must NOT be resurrected into an empty player")
    }

    /// CONSTRAINT: only a row the server actually marks now-playing is adopted.
    /// A stray position-only row (nowPlaying != true) must not surface as the player.
    func test_reconcile_emptyPlayer_serverNotNowPlaying_doesNotAdopt() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/web-ep.mp3",
            episodeGuid: "web-ep",
            positionSec: 300,
            durationSec: 1800,
            title: "Not now-playing",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            nowPlaying: false,
            completed: nil,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        XCTAssertNil(audioManager.currentItem,
                     "A non-now-playing server row must NOT be adopted into an empty player")
    }

    /// CONSTRAINT: a stale (>24h) now-playing state must not be adopted — mirrors the
    /// login-restore staleness guard so a day-old web session doesn't surprise-load.
    func test_reconcile_emptyPlayer_staleState_doesNotAdopt() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let preFetchedState = ProPlaybackState(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/web-ep.mp3",
            episodeGuid: "web-ep",
            positionSec: 300,
            durationSec: 1800,
            title: "Stale web session",
            podcastTitle: "Podcast",
            artUrl: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-25 * 3600)),
            nowPlaying: true,
            completed: nil,
            hidden: nil
        )

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: preFetchedState)

        XCTAssertNil(audioManager.currentItem,
                     "A >24h-old now-playing state must NOT be adopted into an empty player")
    }

    /// CONSTRAINT: nil server state on an empty player stays a no-op (nothing to adopt).
    func test_reconcile_emptyPlayer_serverNil_isNoOp() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        await playerManager.reconcileNowPlayingWithServer(preFetchedState: nil)

        XCTAssertNil(audioManager.currentItem,
                     "Nil server state on an empty player must remain a no-op")
    }

    // MARK: - Bug 2: Post-sync queue cleanup

    /// After episode actions mark an episode as isPlayed in SwiftData,
    /// `clearPlayedEpisodesFromQueue` must remove it from the mini player.
    func test_postSync_clearsPlayedCurrentItem() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Create the episode in SwiftData and mark it as played
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-played",
            title: "Played Episode",
            audioUrl: "https://example.com/ep-played.mp3",
            podcast: podcast
        )
        episode.isPlayed = true
        episode.listenedSeconds = 3600
        context.insert(episode)
        try! context.save()

        // Load the played episode as the current item in the mini player
        audioManager.currentItem = makeQueueItem(
            id: "ep-played",
            title: "Played Episode",
            audioUrl: "https://example.com/ep-played.mp3",
            positionSeconds: 3600,
            durationSeconds: 3600
        )

        // Run post-sync cleanup
        playerManager.clearPlayedEpisodesFromQueue(podcastManager: podcastManager)

        // The played episode must be cleared from the mini player
        XCTAssertNil(audioManager.currentItem,
                     "Post-sync cleanup must clear played episodes from the mini player")
    }

    /// Unplayed episodes must NOT be cleared by post-sync cleanup.
    func test_postSync_preservesUnplayedCurrentItem() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // Create the episode in SwiftData — NOT played
        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-inprog",
            title: "In Progress",
            audioUrl: "https://example.com/ep-inprog.mp3",
            podcast: podcast
        )
        episode.isPlayed = false
        episode.listenedSeconds = 120
        context.insert(episode)
        try! context.save()

        audioManager.currentItem = makeQueueItem(
            id: "ep-inprog",
            title: "In Progress",
            audioUrl: "https://example.com/ep-inprog.mp3",
            positionSeconds: 120,
            durationSeconds: 3600
        )

        playerManager.clearPlayedEpisodesFromQueue(podcastManager: podcastManager)

        XCTAssertNotNil(audioManager.currentItem,
                        "Unplayed episodes must NOT be cleared by post-sync cleanup")
        XCTAssertEqual(audioManager.currentItem?.id, "ep-inprog")
    }

    /// Post-sync cleanup must also remove played episodes from the Up Next queue.
    func test_postSync_removesPlayedQueueItems() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        let podcast = Podcast(url: "https://example.com/feed.xml", title: "Podcast")
        context.insert(podcast)

        // Episode A: played
        let epA = Episode(
            guid: "ep-a",
            title: "Episode A",
            audioUrl: "https://example.com/ep-a.mp3",
            podcast: podcast
        )
        epA.isPlayed = true
        epA.listenedSeconds = 3600
        context.insert(epA)

        // Episode B: not played
        let epB = Episode(
            guid: "ep-b",
            title: "Episode B",
            audioUrl: "https://example.com/ep-b.mp3",
            podcast: podcast
        )
        epB.isPlayed = false
        epB.listenedSeconds = 300
        context.insert(epB)
        try! context.save()

        // Queue has both episodes
        audioManager.replaceQueue([
            makeQueueItem(id: "ep-a", title: "Episode A", audioUrl: "https://example.com/ep-a.mp3"),
            makeQueueItem(id: "ep-b", title: "Episode B", audioUrl: "https://example.com/ep-b.mp3")
        ])

        playerManager.clearPlayedEpisodesFromQueue(podcastManager: podcastManager)

        // Only ep-b should remain
        XCTAssertEqual(audioManager.queue.count, 1,
                       "Played episode must be removed from queue")
        XCTAssertEqual(audioManager.queue.first?.id, "ep-b",
                       "Unplayed episode must remain in queue")
    }

    /// When no episode exists in SwiftData (e.g., server-only queue item),
    /// cleanup must preserve the item — it can't determine played status.
    func test_postSync_preservesItemsWithNoSwiftDataMatch() async {
        let spy = ReconcileSpy()
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        playerManager.setSyncClient(spy, deviceId: "test-device")

        // No episodes in SwiftData
        audioManager.currentItem = makeQueueItem(id: "server-only-ep")

        playerManager.clearPlayedEpisodesFromQueue(podcastManager: podcastManager)

        XCTAssertNotNil(audioManager.currentItem,
                        "Items without SwiftData match must be preserved")
    }
}

// MARK: - Client Event-Time Stamping (AudioManager + model)

/// The device that made the most-recent *change* should win, regardless of who
/// syncs last. iOS stamps each playback push with a client event time:
///   - actively playing → `now` (this device is the live source → wins)
///   - paused / idle / offline → the frozen last-change time (stale → loses)
/// These tests pin the AudioManager stamping + the wire encoding. The server-side
/// "newest event time wins" enforcement is specified separately (clients-first).
@MainActor
final class PlaybackEventTimeTests: XCTestCase {

    private func clearKeys() {
        for k in ["savedQueue", "savedCurrentItem", "savedCurrentPosition", "savedPlaybackEventTime"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func setUp() { super.setUp(); clearKeys() }
    override func tearDown() { clearKeys(); super.tearDown() }

    private func makeItem(id: String = "ep-1") -> QueueItem {
        QueueItem(
            id: id, title: "Ep", podcastTitle: "Pod",
            audioUrl: "https://example.com/\(id).mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed.xml", pubDate: nil
        )
    }

    // MARK: AudioManager stamps the event time on every state change

    func test_playEpisode_stampsEventTime() async {
        let t = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { t })
        await mgr.playEpisode(makeItem())
        XCTAssertEqual(mgr.playbackEventTime, t,
                       "playEpisode must stamp the event time to the action clock")
    }

    func test_pause_stampsEventTime() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { clock })
        await mgr.playEpisode(makeItem())
        clock = Date(timeIntervalSince1970: 2_000)
        mgr.pause()
        XCTAssertEqual(mgr.playbackEventTime, Date(timeIntervalSince1970: 2_000),
                       "pause must re-stamp the event time")
    }

    func test_seek_stampsEventTime() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { clock })
        await mgr.playEpisode(makeItem())
        clock = Date(timeIntervalSince1970: 3_000)
        mgr.seek(to: 120)
        XCTAssertEqual(mgr.playbackEventTime, Date(timeIntervalSince1970: 3_000),
                       "seek must re-stamp the event time")
    }

    func test_stop_stampsEventTime() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { clock })
        await mgr.playEpisode(makeItem())
        clock = Date(timeIntervalSince1970: 5_000)
        mgr.stop()
        XCTAssertEqual(mgr.playbackEventTime, Date(timeIntervalSince1970: 5_000),
                       "stop must re-stamp the event time")
    }

    // MARK: playbackEventTimeForSync — isPlaying-aware

    func test_eventTimeForSync_whilePaused_returnsFrozenLastChange() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { clock })
        mgr.pause()                                    // frozen = 1000, isPlaying=false
        clock = Date(timeIntervalSince1970: 9_000)
        XCTAssertEqual(mgr.playbackEventTimeForSync, Date(timeIntervalSince1970: 1_000),
                       "Paused/idle → report the frozen last-change time (stale loses)")
    }

    func test_eventTimeForSync_whilePlaying_returnsNow() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { clock })
        mgr.pause()                                    // frozen = 1000
        mgr.isPlaying = true                           // simulate active playback
        clock = Date(timeIntervalSince1970: 4_000)
        XCTAssertEqual(mgr.playbackEventTimeForSync, Date(timeIntervalSince1970: 4_000),
                       "Actively playing → this device is the live source → report now")
    }

    // MARK: persistence (force-quit offline device must report its stale time)

    func test_eventTime_persistsAcrossRestore() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let mgr = AudioManager(now: { clock })
        await mgr.playEpisode(makeItem())              // sets currentItem
        clock = Date(timeIntervalSince1970: 1_234)
        mgr.pause()                                    // stamps 1234
        mgr.persistQueueToDisk()

        let restored = AudioManager(now: { Date(timeIntervalSince1970: 9_999) })
        restored.restoreQueue()
        XCTAssertEqual(restored.playbackEventTime, Date(timeIntervalSince1970: 1_234),
                       "Event time must survive relaunch (force-quit offline device reports stale time)")
    }

    // MARK: wire encoding

    func test_ProPlaybackSyncRequest_encodesClientUpdatedAtAsISO8601() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
        let req = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: "g", positionSec: 10, durationSec: 100,
            nowPlaying: true, completed: nil, deviceId: "d", clientUpdatedAt: date)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard let str = dict["clientUpdatedAt"] as? String else {
            return XCTFail("clientUpdatedAt must encode as an ISO8601 string")
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = fmt.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        XCTAssertNotNil(parsed, "clientUpdatedAt must be valid ISO8601: \(str)")
        XCTAssertEqual(parsed!.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func test_ProPlaybackSyncRequest_omitsClientUpdatedAtWhenNil() throws {
        let req = ProPlaybackSyncRequest(
            podcastUrl: "https://example.com/feed",
            episodeUrl: "https://example.com/ep1.mp3",
            episodeGuid: nil, positionSec: 0, durationSec: nil,
            nowPlaying: nil, completed: nil, deviceId: nil, clientUpdatedAt: nil)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(dict["clientUpdatedAt"], "nil clientUpdatedAt must be omitted from the payload")
    }
}

// MARK: - Now-Playing Re-assertion Event Time (clobber prevention)

/// A device that re-asserts now-playing WITHOUT a fresh user action — the
/// scenePhase `.background` lifecycle flush, which fires on the iOS-app-on-Mac
/// every time its window loses focus — must stamp the push with the FROZEN
/// playback event time, not `Date()`. Otherwise a paused, stale device looks
/// "newer" than an actively-listening device and clobbers its now-playing on
/// the server (the event-time guard can't help: the stale device's timestamp
/// genuinely IS `now`). This is the second half of the iOS-app-on-Mac handoff
/// bug — the push side, complementing the pull-side cancellation fix.
@MainActor
final class NowPlayingReassertEventTimeTests: XCTestCase {

    private func clearKeys() {
        for k in ["savedQueue", "savedCurrentItem", "savedCurrentPosition", "savedPlaybackEventTime"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func setUp() { super.setUp(); clearKeys() }
    override func tearDown() { clearKeys(); super.tearDown() }

    private func makeItem(id: String = "ep-stale") -> QueueItem {
        QueueItem(
            id: id, title: "Ep", podcastTitle: "Pod",
            audioUrl: "https://example.com/\(id).mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed.xml", pubDate: nil
        )
    }

    /// Paused/idle device → the re-assertion carries the FROZEN last-change time,
    /// so a newer device wins on the server (no clobber). FAILS against the old
    /// code, which stamped `Date()` (≈ real now) regardless of play state.
    ///
    /// State is set directly (no `playEpisode`) to avoid a real `AVPlayer` URL
    /// load whose async 404 would clear `currentItem` mid-test.
    func test_reassertNowPlaying_whilePaused_stampsFrozenEventTime() async {
        var clock = Date(timeIntervalSince1970: 2_000)
        let audio = AudioManager(now: { clock })
        audio.pause()                                   // frozen = 2000, isPlaying=false
        audio.currentItem = makeItem()                  // load now-playing without network
        clock = Date(timeIntervalSince1970: 9_000)      // device sits idle; time marches on

        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        let player = PlayerManager(audioManager: audio)
        player.setSyncClient(spy, deviceId: "mac-device")
        try? await Task.sleep(for: .milliseconds(200))  // let the login task settle

        let baseline = await spy.playbackSyncCalls.count
        player.syncNowPlayingToProServer()              // .background lifecycle flush
        try? await Task.sleep(for: .milliseconds(200))

        let calls = await spy.playbackSyncCalls
        XCTAssertGreaterThan(calls.count, baseline, "the explicit re-assertion must push to the server")
        let mine = calls.last { $0.episodeGuid == "ep-stale" && $0.nowPlaying == true }
        XCTAssertNotNil(mine, "now-playing re-assertion must reach the server")
        XCTAssertEqual(mine?.clientUpdatedAt, Date(timeIntervalSince1970: 2_000),
                       "Paused re-assertion must stamp the FROZEN event time (stale loses), not Date().")
    }

    /// Actively-playing device → the re-assertion carries `now`, so the live
    /// source still wins (no regression to active-device handoff).
    func test_reassertNowPlaying_whilePlaying_stampsNow() async {
        var clock = Date(timeIntervalSince1970: 2_000)
        let audio = AudioManager(now: { clock })
        audio.pause()                                   // frozen baseline
        audio.currentItem = makeItem()                  // load now-playing without network

        let spy = PlaybackSyncSpy()
        await spy.setSupportsQueue(true)
        let player = PlayerManager(audioManager: audio)
        player.setSyncClient(spy, deviceId: "phone-device")
        try? await Task.sleep(for: .milliseconds(200))  // login task settles (it resets isPlaying)

        // Assert active playback AFTER settle, immediately before the push — the
        // event time is read synchronously at the top of syncNowPlayingToProServer.
        clock = Date(timeIntervalSince1970: 7_000)
        audio.isPlaying = true
        let baseline = await spy.playbackSyncCalls.count
        player.syncNowPlayingToProServer()
        try? await Task.sleep(for: .milliseconds(200))

        let calls = await spy.playbackSyncCalls
        XCTAssertGreaterThan(calls.count, baseline, "the explicit re-assertion must push to the server")
        let mine = calls.last { $0.episodeGuid == "ep-stale" && $0.nowPlaying == true }
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine?.clientUpdatedAt, Date(timeIntervalSince1970: 7_000),
                       "Actively-playing re-assertion must stamp now (live source wins).")
    }
}

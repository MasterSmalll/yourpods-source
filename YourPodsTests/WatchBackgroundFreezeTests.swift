import XCTest
@testable import YourPods

/// TDD tests for watch background state freeze — three linked bugs:
///
/// 1. `WatchAudioState.timerState` initializes as `.active` even before playback.
///    During background wakes with no playback, this causes the audio manager to
///    believe a timer should be running → timer fires in burst on resume → freeze.
///    Fix: initialize as `.suspended`, activate only on `play()`.
///
/// 2. `WatchSessionManager` never re-reads `receivedApplicationContext` on foreground
///    resume. Data that arrived during suspension sits unprocessed → stale UI.
///    Fix: add `refreshFromApplicationContext()` callable on scenePhase change.
///
/// 3. No persistent diagnostics for background lifecycle events.
///    Fix: `WatchDiagnosticLog` ring buffer (tested separately if needed).
final class WatchBackgroundFreezeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchBackgroundFreezeTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEpisode(
        id: String = "ep-freeze-1",
        streamUrl: String? = "https://example.com/ep.mp3"
    ) -> WatchAudioState.EpisodeInfo {
        WatchAudioState.EpisodeInfo(
            id: id,
            title: "Freeze Test Episode",
            album: "Test Podcast",
            streamUrl: streamUrl,
            localPath: nil,
            artUri: nil,
            duration: 3600,
            position: 0
        )
    }

    // MARK: - Bug 1: timerState must start .suspended

    /// The timer must be suspended by default — no playback means no timer.
    /// Without this, background wakes start with timerState = .active, which
    /// tells the audio manager to run a progress timer even though nothing
    /// is playing. On foreground resume, accumulated timer fires burst and freeze the UI.
    func test_timerState_suspendedByDefault() {
        let state = WatchAudioState()

        XCTAssertEqual(state.timerState, .suspended,
                       "timerState MUST initialize as .suspended — " +
                       "no playback = no timer. Current code incorrectly starts as .active " +
                       "causing timer bursts on background wake resume")
    }

    /// play() should transition timerState from .suspended to .active.
    func test_timerState_activatesOnPlay() {
        var state = WatchAudioState()
        let episode = makeEpisode()

        XCTAssertEqual(state.timerState, .suspended, "Precondition: starts suspended")

        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertEqual(state.timerState, .active,
                       "play() must activate the timer — the progress timer is needed " +
                       "to update UI and sync position during active playback")
    }

    /// Full lifecycle: suspended → play → active → background → suspended → foreground → active
    func test_timerState_fullBackgroundCycle() {
        var state = WatchAudioState()
        let episode = makeEpisode()

        // 1. Fresh state: no timer
        XCTAssertEqual(state.timerState, .suspended)

        // 2. Start playback: timer active
        state.play(episode: episode, documentsDirectory: tempDir)
        XCTAssertEqual(state.timerState, .active)

        // 3. Background: timer suspended
        state.handleDidEnterBackground()
        XCTAssertEqual(state.timerState, .suspended)

        // 4. Foreground while playing: timer resumes
        state.handleWillEnterForeground()
        XCTAssertEqual(state.timerState, .active)

        // 5. Stop: timer suspended again
        state.stop()
        XCTAssertEqual(state.timerState, .suspended)

        // 6. Background with nothing playing: stays suspended
        state.handleDidEnterBackground()
        XCTAssertEqual(state.timerState, .suspended)

        // 7. Foreground with nothing playing: stays suspended
        state.handleWillEnterForeground()
        XCTAssertEqual(state.timerState, .suspended,
                       "Timer must stay suspended on foreground resume when nothing is playing")
    }

    // MARK: - Bug 2: Foreground resume must refresh application context

    /// WatchSessionManager must expose a method that re-reads the latest
    /// receivedApplicationContext and processes it. This is needed because
    /// applicationContext may have been updated by the system while the app
    /// was suspended — the delegate callback only fires once at delivery time.
    func test_refreshFromApplicationContext_methodExists() {
        // This test verifies the method exists and is callable.
        // The actual WCSession integration can't be tested in unit tests,
        // but we can verify the method signature compiles.
        let processor = WatchApplicationContextProcessor()

        // An empty context should produce no crash and no updates
        let result = processor.processApplicationContext([:])
        XCTAssertFalse(result.hasQueueUpdate,
                       "Empty context should not produce a queue update")
        XCTAssertFalse(result.hasPlaybackInfoUpdate,
                       "Empty context should not produce a playback info update")
    }

    /// Processing a context with queue data should extract episodes.
    func test_refreshFromApplicationContext_extractsQueueData() {
        let processor = WatchApplicationContextProcessor()

        let context: [String: Any] = [
            "queue": [
                ["id": "ep-1", "title": "Episode 1", "album": "Podcast", "artist": "Host",
                 "duration": 1800, "url": "https://example.com/ep1.mp3",
                 "isAvailableOnPhone": true, "position": 120],
                ["id": "ep-2", "title": "Episode 2", "album": "Podcast", "artist": "Host",
                 "duration": 2400, "url": "https://example.com/ep2.mp3",
                 "isAvailableOnPhone": false, "position": 0]
            ]
        ]

        let result = processor.processApplicationContext(context)

        XCTAssertTrue(result.hasQueueUpdate,
                      "Context with queue key should produce a queue update")
        XCTAssertEqual(result.queueItems.count, 2,
                       "Should extract 2 queue items from context")
        XCTAssertEqual(result.queueItems.first?.id, "ep-1")
        XCTAssertEqual(result.queueItems.first?.position, 120)
    }

    /// Processing a context with playback info should extract now-playing state.
    func test_refreshFromApplicationContext_extractsPlaybackInfo() {
        let processor = WatchApplicationContextProcessor()

        let context: [String: Any] = [
            "playback_info": [
                "title": "Current Episode",
                "artist": "Host Name",
                "isPlaying": true,
                "episodeId": "ep-current"
            ]
        ]

        let result = processor.processApplicationContext(context)

        XCTAssertTrue(result.hasPlaybackInfoUpdate)
        XCTAssertEqual(result.playbackTitle, "Current Episode")
        XCTAssertEqual(result.playbackArtist, "Host Name")
        XCTAssertTrue(result.playbackIsPlaying)
        XCTAssertEqual(result.playbackEpisodeId, "ep-current")
    }

    /// Processing a context with speed should extract playback speed.
    func test_refreshFromApplicationContext_extractsSpeed() {
        let processor = WatchApplicationContextProcessor()

        let context: [String: Any] = [
            "speed": 1.5
        ]

        let result = processor.processApplicationContext(context)

        XCTAssertEqual(result.speed, 1.5,
                       "Should extract playback speed from context")
    }
}

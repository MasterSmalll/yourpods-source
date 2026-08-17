import XCTest
@testable import YourPods

/// TDD tests for watch audio manager freeze fix — Bug #1–#4.
///
/// These test the throttling and resource-management logic added to
/// `WatchAudioState` to prevent watchOS from killing the app due to
/// excessive CPU/memory usage.
final class WatchAudioManagerFreezeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFreezeTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEpisode(
        id: String = "ep-1",
        title: String = "Test Episode",
        album: String = "Test Podcast",
        streamUrl: String? = "https://example.com/ep1.mp3",
        localPath: String? = nil,
        artUri: String? = "https://example.com/art.jpg",
        position: Int = 0,
        duration: Int = 3600
    ) -> WatchAudioState.EpisodeInfo {
        WatchAudioState.EpisodeInfo(
            id: id,
            title: title,
            album: album,
            streamUrl: streamUrl,
            localPath: localPath,
            artUri: artUri,
            duration: duration,
            position: position
        )
    }

    // MARK: - Bug #1: Remote Command Setup Tracking

    /// After playing multiple episodes, `remoteCommandsConfigured` should be true
    /// (meaning the WatchAudioManager can check this to avoid re-adding targets).
    func test_remoteCommandsConfigured_setToTrueAfterFirstPlay() {
        var state = WatchAudioState()
        let episode = makeEpisode()

        XCTAssertFalse(state.remoteCommandsConfigured,
                       "Should be false before any play")

        state.play(episode: episode, documentsDirectory: tempDir)
        state.markRemoteCommandsConfigured()

        XCTAssertTrue(state.remoteCommandsConfigured,
                      "Should be true after marking configured")
    }

    func test_remoteCommandsConfigured_survivesMultiplePlays() {
        var state = WatchAudioState()
        let ep1 = makeEpisode(id: "ep-1")
        let ep2 = makeEpisode(id: "ep-2")

        state.play(episode: ep1, documentsDirectory: tempDir)
        state.markRemoteCommandsConfigured()

        state.play(episode: ep2, documentsDirectory: tempDir)

        XCTAssertTrue(state.remoteCommandsConfigured,
                      "Should remain true across episode transitions — commands are set up once")
    }

    func test_remoteCommandsConfigured_resetsOnStop() {
        var state = WatchAudioState()
        let episode = makeEpisode()

        state.play(episode: episode, documentsDirectory: tempDir)
        state.markRemoteCommandsConfigured()

        state.stop()

        XCTAssertFalse(state.remoteCommandsConfigured,
                       "Should reset to false on stop so commands are re-registered on next play")
    }

    // MARK: - Bug #2: Progress Throttle (≥1s delta)

    /// `shouldPublishProgress` should return false when the change is < 1 second.
    func test_shouldPublishProgress_rejectsTinyDelta() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 100)
        state.play(episode: episode, documentsDirectory: tempDir)

        // First update always publishes
        XCTAssertTrue(state.shouldPublishProgress(newProgress: 100.3),
                      "First update should always publish")
        state.updateProgress(100.3)
        state.recordPublishedProgress()

        // Sub-second change should NOT publish
        XCTAssertFalse(state.shouldPublishProgress(newProgress: 100.8),
                       "0.5s delta should not trigger publish")
    }

    func test_shouldPublishProgress_acceptsOnePlusSecondDelta() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 100)
        state.play(episode: episode, documentsDirectory: tempDir)

        // First update
        XCTAssertTrue(state.shouldPublishProgress(newProgress: 100.0))
        state.updateProgress(100.0)
        state.recordPublishedProgress()

        // ≥1s delta should publish
        XCTAssertTrue(state.shouldPublishProgress(newProgress: 101.1),
                      "1.1s delta should trigger publish")
    }

    func test_shouldPublishProgress_firstCallAlwaysPublishes() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 0)
        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertTrue(state.shouldPublishProgress(newProgress: 0.1),
                      "Very first progress update should always publish")
    }

    // MARK: - Bug #3: Now Playing Info Throttle (~5s)

    /// `shouldUpdateNowPlaying` should throttle to every ~5 seconds.
    func test_shouldUpdateNowPlaying_throttlesToFiveSeconds() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        // First call always allowed
        XCTAssertTrue(state.shouldUpdateNowPlaying(),
                      "First now-playing update should be allowed")
        state.recordNowPlayingUpdate()

        // Immediately after should be denied
        XCTAssertFalse(state.shouldUpdateNowPlaying(),
                       "Should throttle — called too soon after last update")
    }

    func test_shouldUpdateNowPlaying_allowsAfterInterval() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        // First call
        state.recordNowPlayingUpdate()

        // Simulate 6 seconds passing
        state.overrideLastNowPlayingUpdate(Date().addingTimeInterval(-6))

        XCTAssertTrue(state.shouldUpdateNowPlaying(),
                      "Should allow update after 5+ seconds")
    }

    // MARK: - Bug #4: Artwork Cache

    func test_shouldFetchArtwork_returnsTrueForNewURL() {
        var state = WatchAudioState()
        let episode = makeEpisode(artUri: "https://example.com/art1.jpg")
        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertTrue(state.shouldFetchArtwork(url: "https://example.com/art1.jpg"),
                      "Should fetch artwork for a new URL")
    }

    func test_shouldFetchArtwork_returnsFalseForSameURL() {
        var state = WatchAudioState()
        let episode = makeEpisode(artUri: "https://example.com/art1.jpg")
        state.play(episode: episode, documentsDirectory: tempDir)

        state.recordArtworkFetched(url: "https://example.com/art1.jpg")

        XCTAssertFalse(state.shouldFetchArtwork(url: "https://example.com/art1.jpg"),
                       "Should NOT re-fetch artwork for the same URL")
    }

    func test_shouldFetchArtwork_returnsTrueForDifferentURL() {
        var state = WatchAudioState()
        let ep1 = makeEpisode(id: "ep-1", artUri: "https://example.com/art1.jpg")
        state.play(episode: ep1, documentsDirectory: tempDir)
        state.recordArtworkFetched(url: "https://example.com/art1.jpg")

        XCTAssertTrue(state.shouldFetchArtwork(url: "https://example.com/art2.jpg"),
                      "Should fetch artwork for a DIFFERENT URL (new episode)")
    }

    func test_shouldFetchArtwork_clearsOnStop() {
        var state = WatchAudioState()
        let episode = makeEpisode(artUri: "https://example.com/art1.jpg")
        state.play(episode: episode, documentsDirectory: tempDir)
        state.recordArtworkFetched(url: "https://example.com/art1.jpg")

        state.stop()

        XCTAssertTrue(state.shouldFetchArtwork(url: "https://example.com/art1.jpg"),
                      "After stop, same URL should be fetchable again")
    }

    // MARK: - W34: Sleep-timer stall race — twin coverage note
    //
    // Production bug: timerFired()'s sleep-timer expiry called togglePlayPause(),
    // which branched on AVPlayer.timeControlStatus — during a buffer stall
    // (isPlaying == true but timeControlStatus != .playing) that took the
    // "resume" branch instead of pausing, silently defeating the timer. Fixed
    // by extracting a timeControlStatus-independent pausePlayback() helper that
    // timerFired() now calls directly.
    //
    // The twin CANNOT represent this bug: WatchAudioState.togglePlayPause() has
    // no AVPlayer/timeControlStatus concept at all (it's a plain Bool toggle),
    // and the twin has no sleepTimer/timerFired equivalent — the sleep-timer
    // feature was added to production without ever extending the twin. There is
    // no twin-side stall state to fix. This test locks the one thing the twin
    // CAN promise: toggling from isPlaying always lands on paused, with no
    // timeControlStatus-shaped branch that could take a "resume" path instead.

    func test_togglePlayPause_fromPlaying_alwaysPauses_neverResumes() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        XCTAssertTrue(state.isPlaying, "Precondition: playing")

        state.togglePlayPause()

        XCTAssertFalse(state.isPlaying,
                       "From isPlaying, togglePlayPause() must always pause — the twin " +
                       "has no timeControlStatus-style branch that could resume instead " +
                       "(unlike the production bug this mirrors, W34)")
        XCTAssertEqual(state.statusText, "Paused")
    }

    // MARK: - Integration: Multiple plays don't accumulate state

    func test_multipleAutoAdvances_doNotAccumulateThrottleState() {
        var state = WatchAudioState()
        let ep1 = makeEpisode(id: "ep-1", artUri: "https://example.com/art1.jpg")
        let ep2 = makeEpisode(id: "ep-2", artUri: "https://example.com/art1.jpg") // same podcast art
        let ep3 = makeEpisode(id: "ep-3", artUri: "https://example.com/art1.jpg")

        state.loadQueue([ep1, ep2, ep3])

        // Play ep1
        state.play(episode: ep1, documentsDirectory: tempDir)
        state.markRemoteCommandsConfigured()
        state.recordArtworkFetched(url: "https://example.com/art1.jpg")

        // Auto-advance to ep2
        let next = state.handleEpisodeCompleted()
        XCTAssertNotNil(next)
        state.play(episode: next!, documentsDirectory: tempDir)

        // Remote commands should still be configured (not re-setup)
        XCTAssertTrue(state.remoteCommandsConfigured)

        // Same artwork URL should NOT trigger a re-fetch
        XCTAssertFalse(state.shouldFetchArtwork(url: "https://example.com/art1.jpg"))
    }
}

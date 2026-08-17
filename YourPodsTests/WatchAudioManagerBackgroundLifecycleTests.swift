import XCTest
@testable import YourPods

/// TDD tests for watch background lifecycle management — CAROUSEL watchdog prevention.
///
/// Root cause: The watch app freezes in background and won't relaunch because:
/// 1. The 1s progress timer runs forever in background → fires in burst on resume
/// 2. Audio session stays active after stop() → prevents clean suspension
/// 3. No WKExtendedRuntimeSession for audio playback
/// 4. Download stall timers give false stall detection after suspend/resume
/// 5. loadPersistedData() re-runs on every onAppear during background wakes
///
/// After repeated watchdog kills, watchOS penalizes the app with delayed/blocked
/// relaunch — explaining "won't relaunch after force quit."
final class WatchAudioManagerBackgroundLifecycleTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchBackgroundLifecycleTests_\(UUID().uuidString)")
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

    // MARK: - Bug 1: Timer Lifecycle (Background/Foreground)

    /// Timer should be suspended when app enters background to prevent main-thread
    /// work pileup during suspension. Without this, all accumulated timer fires
    /// execute in a burst on resume → watchdog kill.
    func test_timerState_suspendedOnBackground() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertEqual(state.timerState, .active,
                       "Timer should be active during foreground playback")

        state.handleDidEnterBackground()

        XCTAssertEqual(state.timerState, .suspended,
                       "Timer MUST be suspended when app enters background — " +
                       "prevents accumulated timer firings from causing watchdog kill")
    }

    /// Timer should resume when app returns to foreground IF playback is active.
    func test_timerState_resumesOnForegroundWhenPlaying() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        state.handleDidEnterBackground()
        XCTAssertEqual(state.timerState, .suspended)

        state.handleWillEnterForeground()

        XCTAssertEqual(state.timerState, .active,
                       "Timer should resume when returning to foreground during playback")
    }

    /// Timer should NOT resume on foreground if nothing is playing.
    func test_timerState_staysSuspendedOnForegroundWhenNotPlaying() {
        var state = WatchAudioState()

        // Never started playback — go through background/foreground cycle
        state.handleDidEnterBackground()
        state.handleWillEnterForeground()

        XCTAssertEqual(state.timerState, .suspended,
                       "Timer should not activate when nothing is playing")
    }

    /// EDGE: A background auto-advance (handleTrackEnd → play() for the next
    /// episode while still backgrounded) must NOT resurrect the timer. Without
    /// this, the 1Hz UI timer restarts on every track transition and runs for
    /// the rest of the background listening session — the confirmed battery
    /// drain this task fixes. Mirrors WatchAudioManager.startTimer()'s
    /// isInBackground gate.
    func test_timerState_playWhileInBackground_staysSuspended() {
        var state = WatchAudioState()
        let ep1 = makeEpisode(id: "ep-1")
        let ep2 = makeEpisode(id: "ep-2")
        state.play(episode: ep1, documentsDirectory: tempDir)
        XCTAssertEqual(state.timerState, .active)

        state.handleDidEnterBackground()
        XCTAssertEqual(state.timerState, .suspended)

        // Auto-advance while still backgrounded (e.g. track finished mid-session).
        state.play(episode: ep2, documentsDirectory: tempDir)

        XCTAssertEqual(state.timerState, .suspended,
                       "play() reached via background auto-advance must NOT start " +
                       "the timer — it would run unbounded for the rest of the " +
                       "background session, burning battery with the screen off")
    }

    /// Timer should be suspended after stop(), even if we were in foreground.
    func test_timerState_suspendedAfterStop() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        XCTAssertEqual(state.timerState, .active)

        state.stop()

        XCTAssertEqual(state.timerState, .suspended,
                       "Timer should be suspended after playback stops")
    }

    // MARK: - Bug 2: Audio Session Deactivation

    /// shouldDeactivateAudioSession should return true after stop() is called.
    /// An active audio session without playback keeps watchOS from suspending
    /// the app → eventual watchdog kill.
    func test_shouldDeactivateAudioSession_trueAfterStop() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertFalse(state.shouldDeactivateAudioSession,
                       "Audio session should stay active during playback")

        state.stop()

        XCTAssertTrue(state.shouldDeactivateAudioSession,
                      "Audio session MUST be deactivated after stop — " +
                      "keeps watchOS from suspending the app otherwise")
    }

    /// shouldDeactivateAudioSession should return true when nothing has ever played.
    func test_shouldDeactivateAudioSession_trueWhenNothingPlaying() {
        let state = WatchAudioState()

        XCTAssertTrue(state.shouldDeactivateAudioSession,
                      "Audio session should be deactivatable when nothing is playing")
    }

    /// shouldDeactivateAudioSession should return false during active playback.
    func test_shouldDeactivateAudioSession_falseDuringPlayback() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertFalse(state.shouldDeactivateAudioSession,
                       "Audio session must stay active during playback")
    }

    // MARK: - Bug 4: Stall Timer Lifecycle

    /// Stall timers should be suspended when the app enters background.
    func test_stallTimerLifecycle_suspendsOnBackground() {
        var lifecycle = WatchStallTimerLifecycle()

        XCTAssertTrue(lifecycle.isActive, "Stall timers should be active by default")

        lifecycle.suspend()

        XCTAssertFalse(lifecycle.isActive,
                       "Stall timers MUST be suspended in background — " +
                       "prevents false stall detection from stale timestamps on resume")
    }

    /// Stall timers should resume when the app returns to foreground.
    func test_stallTimerLifecycle_resumesOnForeground() {
        var lifecycle = WatchStallTimerLifecycle()

        lifecycle.suspend()
        XCTAssertFalse(lifecycle.isActive)

        lifecycle.resume()

        XCTAssertTrue(lifecycle.isActive,
                      "Stall timers should resume when app returns to foreground")
    }

    // MARK: - Integration: Timer + Stop

    /// Verify that stop() properly cleans up timer and audio session state.
    func test_stopCleansUpAllBackgroundLifecycleState() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)

        XCTAssertEqual(state.timerState, .active)

        state.stop()

        XCTAssertEqual(state.timerState, .suspended,
                       "Timer should be suspended after stop")
        XCTAssertTrue(state.shouldDeactivateAudioSession,
                      "Audio session should be deactivatable after stop")
    }

    // MARK: - WKExtendedRuntimeSession source-scan guard
    //
    // Precedent: WidgetInteractivityGuardTests. An earlier cleanup deleted the (never-functional
    // — watchOS has no extended-runtime session type for audio) WKExtendedRuntimeSession
    // code from production; this file used to carry a twin mirror of that dead code
    // (ExtendedSessionState / handlePlaybackStarted / handlePlaybackStopped), deleted
    // above. This guard makes sure neither the twin nor production regrows it.

    func test_noFileUnderWatchTarget_referencesWKExtendedRuntimeSession() throws {
        // <repo>/YourPodsTests/WatchAudioManagerBackgroundLifecycleTests.swift → <repo>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let watchDir = repoRoot.appendingPathComponent("YourPodsWatch")
        let files = try FileManager.default.contentsOfDirectory(at: watchDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No watch sources found at \(watchDir.path) — scanner is misrooted, fix the path instead of skipping")

        var violations: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.contains("WKExtendedRuntimeSession") {
                violations.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(violations, [],
                       "WKExtendedRuntimeSession must not reappear under YourPodsWatch/ — " +
                       "watchOS has no extended-runtime session type for audio playback " +
                       "(the dead code this class guards against has already been deleted)")
    }
}

import XCTest
@testable import YourPods

/// TDD tests for WatchAudioState — the testable state logic behind the watch
/// audio manager. These verify that playback state persists independent of any
/// SwiftUI view lifecycle (the core bug fix for background audio).
final class WatchAudioManagerTests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAudioManagerTests_\(UUID().uuidString)")
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
        position: Int = 0,
        duration: Int = 3600
    ) -> WatchAudioState.EpisodeInfo {
        WatchAudioState.EpisodeInfo(
            id: id,
            title: title,
            album: album,
            streamUrl: streamUrl,
            localPath: localPath,
            artUri: nil,
            duration: duration,
            position: position
        )
    }
    
    @discardableResult
    private func createFakeDownloadedFile(named filename: String) -> URL {
        let fileURL = tempDir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("fake audio".utf8))
        return fileURL
    }
    
    // MARK: - Play
    
    func test_playEpisode_setsCurrentEpisodeAndIsPlaying() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        
        let resolution = state.play(episode: episode, documentsDirectory: tempDir)
        
        XCTAssertNotNil(resolution)
        XCTAssertEqual(state.currentEpisode, episode)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.playbackSource, .streaming)
        XCTAssertEqual(state.statusText, "Streaming...")
    }
    
    func test_playEpisode_localFile_prefersLocalSource() {
        var state = WatchAudioState()
        let filename = "ep_local.mp3"
        createFakeDownloadedFile(named: filename)
        let episode = makeEpisode(
            streamUrl: "https://example.com/ep1.mp3",
            localPath: filename
        )
        
        let resolution = state.play(episode: episode, documentsDirectory: tempDir)
        
        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.source, .local)
        XCTAssertEqual(state.playbackSource, .local)
        XCTAssertEqual(state.statusText, "Playing")
    }
    
    func test_playEpisode_resumesFromPosition() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 500)
        
        state.play(episode: episode, documentsDirectory: tempDir)
        
        XCTAssertEqual(state.progress, 500)
    }
    
    // MARK: - Toggle Play/Pause
    
    func test_togglePlayPause_togglesIsPlaying() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        
        XCTAssertTrue(state.isPlaying)
        
        state.togglePlayPause()
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.statusText, "Paused")
        
        state.togglePlayPause()
        XCTAssertTrue(state.isPlaying)
    }
    
    // MARK: - Seek
    
    func test_seekForward_advancesPosition() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 100)
        state.play(episode: episode, documentsDirectory: tempDir)
        
        let newPos = state.seekRelative(by: 30)
        
        XCTAssertEqual(newPos, 130)
        XCTAssertEqual(state.progress, 130)
    }
    
    func test_seekBackward_reversesPosition() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 100)
        state.play(episode: episode, documentsDirectory: tempDir)
        
        let newPos = state.seekRelative(by: -15)
        
        XCTAssertEqual(newPos, 85)
        XCTAssertEqual(state.progress, 85)
    }
    
    func test_seekBackward_clampsToZero() {
        var state = WatchAudioState()
        let episode = makeEpisode(position: 5)
        state.play(episode: episode, documentsDirectory: tempDir)
        
        let newPos = state.seekRelative(by: -15)
        
        XCTAssertEqual(newPos, 0)
    }
    
    func test_seekTo_absolutePosition() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        
        let newPos = state.seekTo(600)
        
        XCTAssertEqual(newPos, 600)
        XCTAssertEqual(state.progress, 600)
    }
    
    // MARK: - State Persistence Across Navigation
    
    func test_stateRetainsPlaybackAfterReading() {
        // Key regression test: verifies that the state model retains playback
        // state independent of any view lifecycle. If the AVPlayer were stored
        // as @State in a view, this would fail because navigating away destroys the view.
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        state.updateProgress(300)
        
        // Simulate "navigating away" — read state from a different context
        // The state should still be playing
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.currentEpisode?.id, "ep-1")
        XCTAssertEqual(state.progress, 300)
    }
    
    // MARK: - Play New Episode
    
    func test_playNewEpisode_replacesCurrentEpisode() {
        var state = WatchAudioState()
        let episode1 = makeEpisode(id: "ep-1", title: "First")
        let episode2 = makeEpisode(id: "ep-2", title: "Second")
        
        state.play(episode: episode1, documentsDirectory: tempDir)
        XCTAssertEqual(state.currentEpisode?.id, "ep-1")
        
        state.play(episode: episode2, documentsDirectory: tempDir)
        XCTAssertEqual(state.currentEpisode?.id, "ep-2")
        XCTAssertTrue(state.isPlaying)
    }
    
    // MARK: - No Source
    
    func test_playWithNoSource_doesNotCrash() {
        var state = WatchAudioState()
        let episode = makeEpisode(streamUrl: nil, localPath: nil)
        
        let resolution = state.play(episode: episode, documentsDirectory: tempDir)
        
        XCTAssertNil(resolution)
        XCTAssertEqual(state.playbackSource, .none)
        XCTAssertEqual(state.statusText, "No audio source")
        // Should NOT crash — should gracefully handle missing source
        XCTAssertNil(state.currentEpisode)
    }
    
    // MARK: - Stop
    
    func test_stop_clearsAllState() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        
        state.stop()
        
        XCTAssertNil(state.currentEpisode)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.playbackSource, .none)
    }
    
    // MARK: - Auto-Advance
    
    func test_autoAdvance_playsNextEpisodeInQueue() {
        var state = WatchAudioState()
        let episode1 = makeEpisode(id: "ep-1", title: "First")
        let episode2 = makeEpisode(id: "ep-2", title: "Second")
        let episode3 = makeEpisode(id: "ep-3", title: "Third")
        
        state.play(episode: episode1, documentsDirectory: tempDir)
        state.loadQueue([episode2, episode3])
        
        let next = state.handleEpisodeCompleted()
        
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.id, "ep-2")
        // Queue should now have 1 item remaining
        XCTAssertEqual(state.queue.count, 1)
        XCTAssertEqual(state.queue.first?.id, "ep-3")
    }
    
    func test_autoAdvance_stopsWhenQueueEmpty() {
        var state = WatchAudioState()
        let episode = makeEpisode()
        state.play(episode: episode, documentsDirectory: tempDir)
        // Empty queue
        
        let next = state.handleEpisodeCompleted()
        
        XCTAssertNil(next)
        XCTAssertNil(state.currentEpisode)
        XCTAssertFalse(state.isPlaying)
    }
    
    // MARK: - Queue Management
    
    func test_playEpisode_removesItFromQueue() {
        var state = WatchAudioState()
        let episode1 = makeEpisode(id: "ep-1")
        let episode2 = makeEpisode(id: "ep-2")
        
        state.loadQueue([episode1, episode2])
        XCTAssertEqual(state.queue.count, 2)
        
        state.play(episode: episode1, documentsDirectory: tempDir)
        
        // ep-1 should be removed from queue since it's now playing
        XCTAssertEqual(state.queue.count, 1)
        XCTAssertEqual(state.queue.first?.id, "ep-2")
    }
    
    func test_togglePlayPause_noOpWhenNoEpisode() {
        var state = WatchAudioState()
        
        state.togglePlayPause()
        
        XCTAssertFalse(state.isPlaying)
    }
}

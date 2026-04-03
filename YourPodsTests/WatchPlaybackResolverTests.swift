import XCTest
@testable import YourPods

/// Tests for the watch Now Playing playback resolution logic.
/// Ensures that when an episode is downloaded on the watch, playback uses the
/// local file instead of streaming. Also validates position resumption.
///
/// These tests verify the *logic* used by the watch PlayerView and ContentView
/// to decide whether to play locally or remote-control the iPhone.
final class WatchPlaybackResolverTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchPlaybackResolverTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    @discardableResult
    private func createFakeDownloadedFile(named filename: String) -> URL {
        let fileURL = tempDir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("fake audio".utf8))
        return fileURL
    }
    
    // MARK: - resolvePlaybackURL Tests
    
    func test_resolvePlaybackURL_returnsLocalFile_whenDownloaded() {
        // Given: episode has a localPath and the file exists on disk
        let filename = "episode_123.mp3"
        createFakeDownloadedFile(named: filename)
        
        // When
        let result = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: filename,
            streamUrl: "https://example.com/ep1.mp3",
            position: 120,
            documentsDirectory: tempDir
        )
        
        // Then: should use local file, not stream
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, .local)
        XCTAssertEqual(result?.url, tempDir.appendingPathComponent(filename))
        XCTAssertEqual(result?.resumePosition, 120)
    }
    
    func test_resolvePlaybackURL_returnsStreamURL_whenNotDownloaded() {
        // Given: episode has only a stream URL, no local file
        let result = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: nil,
            streamUrl: "https://example.com/ep2.mp3",
            position: 60,
            documentsDirectory: tempDir
        )
        
        // Then: should use stream URL
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, .streaming)
        XCTAssertEqual(result?.url, URL(string: "https://example.com/ep2.mp3"))
        XCTAssertEqual(result?.resumePosition, 60)
    }
    
    func test_resolvePlaybackURL_returnsNil_whenNoSource() {
        // Given: episode has neither local file nor stream URL
        let result = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: nil,
            streamUrl: nil,
            position: 0,
            documentsDirectory: tempDir
        )
        
        // Then: should return nil
        XCTAssertNil(result)
    }
    
    func test_resolvePlaybackURL_prefersLocalFile_overStream() {
        // Given: episode has both a local file AND a stream URL
        let filename = "episode_both.mp3"
        createFakeDownloadedFile(named: filename)
        
        let result = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: filename,
            streamUrl: "https://example.com/ep4.mp3",
            position: 300,
            documentsDirectory: tempDir
        )
        
        // Then: should prefer local file (no streaming stalls)
        XCTAssertEqual(result?.source, .local)
        XCTAssertEqual(result?.url, tempDir.appendingPathComponent(filename))
    }
    
    func test_resolvePlaybackURL_fallsBackToStream_whenLocalFileMissing() {
        // Given: episode has a localPath set, but the file was deleted from disk
        let result = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: "deleted_file.mp3",
            streamUrl: "https://example.com/ep5.mp3",
            position: 45,
            documentsDirectory: tempDir
        )
        
        // Then: should fall back to stream since local file doesn't exist
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.source, .streaming)
        XCTAssertEqual(result?.url, URL(string: "https://example.com/ep5.mp3"))
    }
    
    func test_resolvePlaybackURL_preservesPosition_forLocalPlayback() {
        // Given: episode downloaded with a saved position of 500 seconds
        let filename = "episode_position.mp3"
        createFakeDownloadedFile(named: filename)
        
        let result = WatchPlaybackResolver.resolvePlaybackURL(
            localPath: filename,
            streamUrl: nil,
            position: 500,
            documentsDirectory: tempDir
        )
        
        // Then: position should be carried through for resumption
        XCTAssertEqual(result?.resumePosition, 500)
        XCTAssertEqual(result?.source, .local)
    }
    
    // MARK: - shouldPlayOnWatch Tests (Now Playing navigation decision)
    
    func test_shouldPlayOnWatch_true_whenEpisodeHasLocalFile() {
        let filename = "episode_local.mp3"
        createFakeDownloadedFile(named: filename)
        
        let result = WatchPlaybackResolver.shouldPlayOnWatch(
            localPath: filename,
            streamUrl: nil,
            documentsDirectory: tempDir
        )
        
        XCTAssertTrue(result)
    }
    
    func test_shouldPlayOnWatch_true_whenEpisodeHasStreamUrl() {
        let result = WatchPlaybackResolver.shouldPlayOnWatch(
            localPath: nil,
            streamUrl: "https://example.com/ep8.mp3",
            documentsDirectory: tempDir
        )
        
        XCTAssertTrue(result)
    }
    
    func test_shouldPlayOnWatch_false_whenNoSource() {
        let result = WatchPlaybackResolver.shouldPlayOnWatch(
            localPath: nil,
            streamUrl: nil,
            documentsDirectory: tempDir
        )
        
        XCTAssertFalse(result)
    }
    
    func test_shouldPlayOnWatch_false_whenLocalPathSet_butFileMissing_andNoStreamUrl() {
        // Edge case: localPath is set but file was deleted, and no stream URL
        let result = WatchPlaybackResolver.shouldPlayOnWatch(
            localPath: "gone.mp3",
            streamUrl: nil,
            documentsDirectory: tempDir
        )
        
        XCTAssertFalse(result)
    }
    
    func test_shouldPlayOnWatch_true_whenLocalPathMissing_butHasStreamUrl() {
        // localPath file doesn't exist, but stream URL available as fallback
        let result = WatchPlaybackResolver.shouldPlayOnWatch(
            localPath: "missing.mp3",
            streamUrl: "https://example.com/stream.mp3",
            documentsDirectory: tempDir
        )
        
        XCTAssertTrue(result)
    }
}

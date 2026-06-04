import XCTest
@testable import YourPods

/// Tests for the episode download context menu feature.
/// Validates that download actions can be triggered from queue items and episodes
/// in any context (library, queue, home).
final class EpisodeDownloadContextMenuTests: XCTestCase {
    
    // MARK: - DownloadManager: Queue Item Download Integration
    
    /// Verifies that starting a download for a QueueItem's GUID creates an active download entry.
    func test_downloadEpisode_createsActiveDownload() async {
        let dm = await DownloadManager()
        let guid = "test-guid-\(UUID().uuidString)"
        let audioUrl = "https://example.com/episode.mp3"
        
        await dm.downloadEpisode(guid: guid, audioUrl: audioUrl)
        
        let hasActive = await dm.activeDownloads[guid] != nil
        XCTAssertTrue(hasActive, "Starting a download should create an active download entry")
    }
    
    /// Verifies that a second download call for the same GUID is a no-op (idempotent).
    func test_downloadEpisode_duplicateCallIsIgnored() async {
        let dm = await DownloadManager()
        let guid = "test-dup-\(UUID().uuidString)"
        let audioUrl = "https://example.com/episode.mp3"
        
        await dm.downloadEpisode(guid: guid, audioUrl: audioUrl)
        await dm.downloadEpisode(guid: guid, audioUrl: audioUrl)
        
        // Should still have exactly one active download
        let activeCount = await dm.activeDownloads.count
        XCTAssertEqual(activeCount, 1, "Duplicate download calls should be ignored")
    }
    
    /// Verifies that an invalid audio URL is handled gracefully (no crash, no active download).
    func test_downloadEpisode_invalidUrl_doesNotCrash() async {
        let dm = await DownloadManager()
        let guid = "test-invalid-\(UUID().uuidString)"
        
        await dm.downloadEpisode(guid: guid, audioUrl: "")
        
        let hasActive = await dm.activeDownloads[guid] != nil
        XCTAssertFalse(hasActive, "Invalid URL should not create an active download")
    }
    
    // MARK: - QueueItem Download Context Menu Helpers
    
    /// Verifies that `EpisodeDownloadHelper.downloadLabel` returns correct label based on download state.
    func test_downloadLabel_whenNotDownloaded_returnsDownload() {
        let label = EpisodeDownloadHelper.downloadLabel(isDownloaded: false)
        XCTAssertEqual(label, "Download")
    }
    
    /// Verifies that `EpisodeDownloadHelper.downloadLabel` returns correct label for downloaded episodes.
    func test_downloadLabel_whenDownloaded_returnsRemoveDownload() {
        let label = EpisodeDownloadHelper.downloadLabel(isDownloaded: true)
        XCTAssertEqual(label, "Remove Download")
    }
    
    /// Verifies that `EpisodeDownloadHelper.downloadIcon` returns correct icon based on download state.
    func test_downloadIcon_whenNotDownloaded_returnsDownloadCircle() {
        let icon = EpisodeDownloadHelper.downloadIcon(isDownloaded: false)
        XCTAssertEqual(icon, "arrow.down.circle")
    }
    
    /// Verifies that `EpisodeDownloadHelper.downloadIcon` returns correct icon for downloaded episodes.
    func test_downloadIcon_whenDownloaded_returnsTrash() {
        let icon = EpisodeDownloadHelper.downloadIcon(isDownloaded: true)
        XCTAssertEqual(icon, "trash")
    }
    
    // MARK: - VoiceOver Accessibility Label
    
    /// Verifies the VoiceOver action name reflects the current download state.
    func test_accessibilityActionName_reflectsDownloadState() {
        let downloadName = EpisodeDownloadHelper.accessibilityActionName(isDownloaded: false)
        XCTAssertEqual(downloadName, "Download")
        
        let removeName = EpisodeDownloadHelper.accessibilityActionName(isDownloaded: true)
        XCTAssertEqual(removeName, "Remove Download")
    }
}

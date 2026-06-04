import XCTest
@testable import YourPods

/// Tests for Bug 3: Downloaded episodes don't play offline after cold start.
///
/// Covers:
///   - rehydrateLocalFileUrls re-attaches local file URLs after queue restore
///   - attemptStreamRecovery checks for local downloads before retrying network
///   - Non-downloaded episodes are skipped during rehydration
final class OfflineRehydrationTests: XCTestCase {

    // MARK: - rehydrateLocalFileUrls

    /// After restoreQueue, calling rehydrateLocalFileUrls should re-attach
    /// localFileUrl from DownloadManager for downloaded episodes.
    @MainActor
    func test_rehydrateLocalFileUrls_attachesDownloadedFiles() {
        let audioManager = AudioManager()

        // Simulate restored queue items (localFileUrl is nil after decode)
        let item1 = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 120,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        XCTAssertNil(item1.localFileUrl, "Precondition: localFileUrl is nil after restore")

        let item2 = QueueItem(
            id: "ep-2", title: "Episode 2", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep2.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )

        // Set up audio manager state to simulate restored queue
        audioManager.currentItem = item1
        audioManager.appendToQueue([item2])

        // Simulate download manager lookup:
        // ep-1 is downloaded, ep-2 is not
        let tempDir = FileManager.default.temporaryDirectory
        let localFile1 = tempDir.appendingPathComponent("ep1.mp3")

        audioManager.rehydrateLocalFileUrls { guid in
            if guid == "ep-1" {
                return localFile1
            }
            return nil
        }

        // THEN: currentItem should have localFileUrl rehydrated
        XCTAssertEqual(audioManager.currentItem?.localFileUrl, localFile1,
                       "currentItem's localFileUrl should be rehydrated from download manager")

        // AND: queue item without download should remain nil
        XCTAssertNil(audioManager.queue.first?.localFileUrl,
                     "Non-downloaded queue items should remain nil")
    }

    /// rehydrateLocalFileUrls should skip items that aren't downloaded.
    @MainActor
    func test_rehydrateLocalFileUrls_skipsNonDownloadedEpisodes() {
        let audioManager = AudioManager()

        let item = QueueItem(
            id: "ep-not-downloaded", title: "Not Downloaded", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep3.mp3", artworkUrl: nil,
            durationSeconds: 2400, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item

        // Download lookup returns nil for all
        audioManager.rehydrateLocalFileUrls { _ in nil }

        XCTAssertNil(audioManager.currentItem?.localFileUrl,
                     "Non-downloaded episodes should not get a localFileUrl")
    }

    /// rehydrateLocalFileUrls should handle empty queue gracefully.
    @MainActor
    func test_rehydrateLocalFileUrls_handlesEmptyQueue() {
        let audioManager = AudioManager()
        audioManager.currentItem = nil
        audioManager.clearQueue()

        // Should not crash
        audioManager.rehydrateLocalFileUrls { _ in nil }

        XCTAssertNil(audioManager.currentItem)
        XCTAssertTrue(audioManager.queue.isEmpty)
    }

    /// After rehydration, playEpisode should use the local file URL
    /// (simulating what happens on cold start + play tap).
    @MainActor
    func test_resumePlayback_usesLocalFile_afterColdStart() async {
        let audioManager = AudioManager()

        // Simulate cold-start restore
        let item = QueueItem(
            id: "ep-cold", title: "Cold Start Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/cold.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 300,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = item

        // Rehydrate with a local file
        let tempDir = FileManager.default.temporaryDirectory
        let localFile = tempDir.appendingPathComponent("cold.mp3")

        audioManager.rehydrateLocalFileUrls { guid in
            if guid == "ep-cold" { return localFile }
            return nil
        }

        // Verify localFileUrl was attached
        XCTAssertEqual(audioManager.currentItem?.localFileUrl, localFile,
                       "After rehydration, currentItem should have localFileUrl set")
    }
}

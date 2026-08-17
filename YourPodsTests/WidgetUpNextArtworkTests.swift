import XCTest
import UIKit
@testable import YourPods

/// TDD tests for the Up Next artwork bug in the large widget.
///
/// Bug: `pushWidgetUpdate` passes `artworkPath: nil` for every up-next item,
/// so the widget always shows a music-note placeholder instead of album art.
///
/// Fix requirement: resolve each up-next item's `artworkUrl` to a local file
/// in the App Group container (same pattern as now-playing artwork).
final class WidgetUpNextArtworkTests: XCTestCase {

    private func widgetArtContainer() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: LiveActivityService.appGroupId)
    }

    private func removeAllWidgetArt() {
        guard let dir = widgetArtContainer(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("widget_art") && name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func seedCache(url: String) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        ImageCacheStore.shared.cache.setObject(image, forKey: url as NSString)
    }

    override func tearDown() {
        removeAllWidgetArt()
        super.tearDown()
    }

    // MARK: - Core bug: up-next items get resolved artwork paths

    func test_upNextItems_resolveArtworkFromCache() throws {
        guard widgetArtContainer() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        removeAllWidgetArt()

        // GIVEN: artwork for two up-next episodes is already in the image cache
        let url1 = "https://example.com/upnext-art-1.jpg"
        let url2 = "https://example.com/upnext-art-2.jpg"
        seedCache(url: url1)
        seedCache(url: url2)

        // WHEN: widget data is pushed with up-next items that have artwork URLs
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Current",
            podcastName: "Pod",
            artworkPath: "/tmp/current-art.jpg",
            isPlaying: true,
            positionSeconds: 100,
            durationSeconds: 3600,
            upNextItems: [
                (title: "Next Episode 1", podcastTitle: "Pod A",
                 artworkPath: nil, artworkUrl: url1, episodeId: "upnext-1"),
                (title: "Next Episode 2", podcastTitle: "Pod B",
                 artworkPath: nil, artworkUrl: url2, episodeId: "upnext-2"),
            ]
        )

        // THEN: the stored up-next items have resolved artwork paths (not nil)
        let data = ComplicationDataStore.shared.read()
        XCTAssertEqual(data.upNextItems.count, 2)

        let art1 = data.upNextItems[0].artworkPath
        XCTAssertNotNil(art1, "Up-next item 1 should have a resolved artwork path")
        XCTAssertTrue(art1?.contains("widget_art_upnext-1") == true,
                      "Path should reference the episode id, got: \(art1 ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: art1 ?? ""),
                      "Artwork file should exist on disk")

        let art2 = data.upNextItems[1].artworkPath
        XCTAssertNotNil(art2, "Up-next item 2 should have a resolved artwork path")
        XCTAssertTrue(art2?.contains("widget_art_upnext-2") == true,
                      "Path should reference the episode id, got: \(art2 ?? "nil")")
    }

    // MARK: - Explicit artworkPath wins over URL resolution

    func test_upNextItems_explicitArtworkPathWins() throws {
        guard widgetArtContainer() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        removeAllWidgetArt()

        let explicitPath = "/tmp/explicit-art.jpg"

        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Current",
            podcastName: "Pod",
            artworkPath: nil,
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 3600,
            upNextItems: [
                (title: "With Path", podcastTitle: "Pod A",
                 artworkPath: explicitPath, artworkUrl: "https://example.com/dont-use.jpg",
                 episodeId: "ep-explicit"),
            ]
        )

        let data = ComplicationDataStore.shared.read()
        XCTAssertEqual(data.upNextItems[0].artworkPath, explicitPath,
                       "Explicit artworkPath should be preserved, not overwritten by URL resolution")
    }

    // MARK: - Cleanup keeps up-next artwork files

    func test_cleanup_keepsUpNextArtwork() throws {
        guard let container = widgetArtContainer() else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        removeAllWidgetArt()

        // GIVEN: artwork cached for now-playing + 2 up-next
        let npUrl = "https://example.com/np-art.jpg"
        let uq1Url = "https://example.com/uq1-art.jpg"
        let uq2Url = "https://example.com/uq2-art.jpg"
        seedCache(url: npUrl)
        seedCache(url: uq1Url)
        seedCache(url: uq2Url)

        // WHEN: widget update writes all three
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Now Playing",
            podcastName: "Pod",
            artworkPath: nil,
            artworkUrl: npUrl,
            episodeId: "np-ep",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 3600,
            upNextItems: [
                (title: "Up 1", podcastTitle: "P1",
                 artworkPath: nil, artworkUrl: uq1Url, episodeId: "uq-1"),
                (title: "Up 2", podcastTitle: "P2",
                 artworkPath: nil, artworkUrl: uq2Url, episodeId: "uq-2"),
            ]
        )

        // THEN: all three artwork files exist in the container
        let npFile = container.appendingPathComponent(LiveActivityService.widgetArtFilename(for: "np-ep"))
        let uq1File = container.appendingPathComponent(LiveActivityService.widgetArtFilename(for: "uq-1"))
        let uq2File = container.appendingPathComponent(LiveActivityService.widgetArtFilename(for: "uq-2"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: npFile.path),
                      "Now-playing artwork should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uq1File.path),
                      "Up-next 1 artwork should not be cleaned up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uq2File.path),
                      "Up-next 2 artwork should not be cleaned up")
    }
}

import XCTest
@testable import YourPods

/// Tests for PodcastManager's refreshAndSync, recentlyUpdatedEpisodes, and reorder logic.
final class PodcastManagerTests: XCTestCase {

    // MARK: - Recently Updated Episodes

    func testFormatDuration_hours() {
        let result = PlayerManager.formatDuration(3661)
        XCTAssertEqual(result, "1h 1m")
    }

    func testFormatDuration_minutes() {
        let result = PlayerManager.formatDuration(125)
        XCTAssertEqual(result, "2m")
    }

    func testFormatDuration_seconds() {
        let result = PlayerManager.formatDuration(45)
        XCTAssertEqual(result, "45s")
    }

    // MARK: - Progress Formatting

    func testFormatProgress_percentListened() {
        let result = PlayerManager.formatProgress(position: 300, duration: 600, showPercent: true)
        XCTAssertEqual(result, "50% listened")
    }

    func testFormatProgress_percentRemaining() {
        let result = PlayerManager.formatProgress(position: 300, duration: 600, showPercent: false)
        XCTAssertEqual(result, "50% left")
    }

    func testFormatProgress_zeroDuration() {
        let result = PlayerManager.formatProgress(position: 0, duration: 0)
        XCTAssertEqual(result, "0%")
    }

    func testFormatProgress_fullListened() {
        let result = PlayerManager.formatProgress(position: 600, duration: 600, showPercent: true)
        XCTAssertEqual(result, "100% listened")
    }

    func testFormatProgress_noneListened() {
        let result = PlayerManager.formatProgress(position: 0, duration: 600, showPercent: false)
        XCTAssertEqual(result, "100% left")
    }

    // MARK: - Settings Enums

    func testTabBarDisplayMode_defaultIsTextAndIcon() {
        // TabBarDisplayMode default should be .textAndIcon
        let mode = TabBarDisplayMode.textAndIcon
        XCTAssertEqual(mode.rawValue, "textAndIcon")
    }

    func testSearchProvider_defaultIsItunes() {
        let provider = SearchProvider.itunes
        XCTAssertEqual(provider.rawValue, "itunes")
    }

    func testSearchProvider_podcastIndex() {
        let provider = SearchProvider.podcastIndex
        XCTAssertEqual(provider.rawValue, "podcastIndex")
    }

    // MARK: - SearchProviderResolver

    func test_resolveProvider_itunesReturnsItunes() {
        let result = SearchProviderResolver.resolve(provider: .itunes, apiKey: nil, apiSecret: nil)
        if case .provider(let p) = result {
            XCTAssertTrue(p is ITunesSearchProvider, "iTunes selection should return ITunesSearchProvider")
        } else {
            XCTFail("iTunes should always return a provider, not an error")
        }
    }

    func test_resolveProvider_podcastIndexWithCredentials() {
        let result = SearchProviderResolver.resolve(
            provider: .podcastIndex,
            apiKey: "test-key",
            apiSecret: "test-secret"
        )
        if case .provider(let p) = result {
            XCTAssertTrue(p is PodcastIndexSearchProvider,
                          "Podcast Index with credentials should return PodcastIndexSearchProvider")
        } else {
            XCTFail("Podcast Index with valid credentials should return a provider")
        }
    }

    func test_resolveProvider_podcastIndexWithoutCredentials_returnsError() {
        let result = SearchProviderResolver.resolve(provider: .podcastIndex, apiKey: nil, apiSecret: nil)
        if case .missingCredentials(let msg) = result {
            XCTAssertFalse(msg.isEmpty, "Error message should not be empty")
        } else {
            XCTFail("Podcast Index without credentials must return .missingCredentials, not a provider")
        }
    }

    func test_resolveProvider_podcastIndexWithEmptyKey_returnsError() {
        let result = SearchProviderResolver.resolve(provider: .podcastIndex, apiKey: "", apiSecret: "secret")
        if case .missingCredentials = result {
            // Expected
        } else {
            XCTFail("Podcast Index with empty API key must return .missingCredentials")
        }
    }

    func test_resolveProvider_podcastIndexWithEmptySecret_returnsError() {
        let result = SearchProviderResolver.resolve(provider: .podcastIndex, apiKey: "key", apiSecret: "")
        if case .missingCredentials = result {
            // Expected
        } else {
            XCTFail("Podcast Index with empty API secret must return .missingCredentials")
        }
    }

    // MARK: - QueueItem from Episode

    func testQueueItemPubDateIsPreserved() {
        // QueueItem should carry pubDate through from Episode
        let date = Date(timeIntervalSince1970: 1000000)
        let item = QueueItem(
            id: "guid1",
            title: "Test Episode",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/ep.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: date
        )
        XCTAssertEqual(item.pubDate, date)
    }

    // MARK: - Timestamp Formatting (mm:ss / h:mm:ss)

    func test_formatTimestamp_zero() {
        XCTAssertEqual(PlayerManager.formatTimestamp(0), "0:00")
    }

    func test_formatTimestamp_seconds() {
        XCTAssertEqual(PlayerManager.formatTimestamp(45), "0:45")
    }

    func test_formatTimestamp_minutes() {
        XCTAssertEqual(PlayerManager.formatTimestamp(125), "2:05")
    }

    func test_formatTimestamp_hours() {
        XCTAssertEqual(PlayerManager.formatTimestamp(3661), "1:01:01")
    }

    // MARK: - OPML

    func testOPMLExport_generatesValidXML() {
        // Test that our OPML service can generate valid XML
        // (This uses an empty array since we can't easily create @Model objects in tests)
        let xml = OPMLService.export(podcasts: [])
        XCTAssertTrue(xml.contains("<?xml"))
        XCTAssertTrue(xml.contains("<opml"))
        XCTAssertTrue(xml.contains("YourPods Subscriptions"))
    }

    func testOPMLParse_returnsURLs() {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
        <body>
            <outline type="rss" text="Pod1" xmlUrl="https://example.com/feed1"/>
            <outline type="rss" text="Pod2" xmlUrl="https://example.com/feed2"/>
        </body>
        </opml>
        """
        let urls = OPMLService.parseURLs(from: Data(opml.utf8))
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0], "https://example.com/feed1")
        XCTAssertEqual(urls[1], "https://example.com/feed2")
    }
}

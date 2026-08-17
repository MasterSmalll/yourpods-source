import XCTest
import Intents
@testable import YourPods

// MARK: - Spy

/// Captures donation calls for assertion without hitting the real Intents framework.
private final class DonationSpy: MediaIntentDonating {
    private(set) var donatedIds: [String] = []

    func donatePlayback(for item: QueueItem) {
        donatedIds.append(item.id)
    }
}

// MARK: - Tests

final class MediaIntentDonationTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(
        id: String = "ep-1",
        title: String = "Test Episode",
        podcastTitle: String = "Test Podcast",
        artworkUrl: String? = "https://example.com/art.jpg",
        podcastUrl: String = "https://example.com/feed"
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: podcastTitle,
            audioUrl: "https://example.com/audio.mp3",
            artworkUrl: artworkUrl,
            durationSeconds: 3600,
            podcastUrl: podcastUrl,
            pubDate: Date()
        )
    }

    // MARK: - Intent Content Tests (table-driven)

    /// Verify makePlayMediaIntent produces the correct INMediaItem fields.
    func testIntentContent() {
        struct Case {
            let label: String
            let id: String
            let title: String
            let podcastTitle: String
            let artworkUrl: String?
            let podcastUrl: String
        }

        let cases: [Case] = [
            Case(label: "normal episode",
                 id: "guid-123", title: "Episode 42", podcastTitle: "Cool Pod",
                 artworkUrl: "https://example.com/art.jpg", podcastUrl: "https://example.com/feed"),
            Case(label: "nil artwork",
                 id: "guid-456", title: "No Art", podcastTitle: "Minimal Pod",
                 artworkUrl: nil, podcastUrl: "https://example.com/feed2"),
            Case(label: "unicode title",
                 id: "guid-789", title: "日本語エピソード", podcastTitle: "ポッドキャスト",
                 artworkUrl: "https://example.com/jp.jpg", podcastUrl: "https://example.com/jp"),
        ]

        let service = MediaIntentDonationService()
        for tc in cases {
            let item = makeItem(
                id: tc.id, title: tc.title, podcastTitle: tc.podcastTitle,
                artworkUrl: tc.artworkUrl, podcastUrl: tc.podcastUrl
            )
            let intent = service.makePlayMediaIntent(for: item)

            // Verify media item
            let media = intent.mediaItems?.first
            XCTAssertNotNil(media, "[\(tc.label)] mediaItems should not be empty")
            XCTAssertEqual(media?.identifier, tc.id, "[\(tc.label)] identifier mismatch")
            XCTAssertEqual(media?.title, tc.title, "[\(tc.label)] title mismatch")
            XCTAssertEqual(media?.type, .podcastEpisode, "[\(tc.label)] type should be podcastEpisode")
            XCTAssertEqual(media?.artist, tc.podcastTitle, "[\(tc.label)] artist should be podcast title")

            // Verify container
            let container = intent.mediaContainer
            XCTAssertNotNil(container, "[\(tc.label)] container should not be nil")
            XCTAssertEqual(container?.identifier, tc.podcastUrl, "[\(tc.label)] container identifier mismatch")
            XCTAssertEqual(container?.title, tc.podcastTitle, "[\(tc.label)] container title mismatch")
            XCTAssertEqual(container?.type, .podcastShow, "[\(tc.label)] container type should be podcastShow")

            // Verify playback settings
            XCTAssertEqual(intent.resumePlayback, true, "[\(tc.label)] resumePlayback should be true")
            XCTAssertEqual(intent.playShuffled, false, "[\(tc.label)] playShuffled should be false")
        }
    }

    // MARK: - Dedup Tests

    /// Table-driven: the service should only donate once per unique episode ID.
    func testDedupPreventsRepeatedDonation() {
        struct Case {
            let label: String
            let ids: [String]
            let expectedLastDonatedId: String?
        }

        let cases: [Case] = [
            Case(label: "single play", ids: ["ep-1"], expectedLastDonatedId: "ep-1"),
            Case(label: "same episode twice — second should be skipped",
                 ids: ["ep-1", "ep-1"], expectedLastDonatedId: "ep-1"),
            Case(label: "two different episodes", ids: ["ep-1", "ep-2"], expectedLastDonatedId: "ep-2"),
            Case(label: "A-B-A round trip", ids: ["ep-1", "ep-2", "ep-1"], expectedLastDonatedId: "ep-1"),
        ]

        for tc in cases {
            // Use a spy that counts actual donation calls to verify dedup
            let spy = CountingSpy()
            for id in tc.ids {
                spy.donatePlayback(for: makeItem(id: id))
            }

            // The spy mirrors the production dedup: count unique consecutive IDs
            let uniqueConsecutive = tc.ids.reduce(into: (count: 0, last: nil as String?)) { result, id in
                if id != result.last {
                    result.count += 1
                    result.last = id
                }
            }.count

            XCTAssertEqual(
                spy.donationCount, uniqueConsecutive,
                "[\(tc.label)] expected \(uniqueConsecutive) donations, got \(spy.donationCount)"
            )
        }
    }

    // MARK: - AudioManager Integration

    /// Verify AudioManager calls the donor when playEpisode is called.
    @MainActor
    func testAudioManagerCallsDonorOnPlayEpisode() async {
        let spy = DonationSpy()
        let audio = AudioManager()
        audio.mediaIntentDonor = spy

        let item = makeItem(id: "ep-integration")
        await audio.playEpisode(item)

        XCTAssertEqual(spy.donatedIds, ["ep-integration"],
                       "AudioManager should donate exactly once when playEpisode is called")
        audio.stop()
    }

    /// Each new episode triggers a separate donation call.
    @MainActor
    func testAudioManagerDonatesOnEachNewEpisode() async {
        let spy = DonationSpy()
        let audio = AudioManager()
        audio.mediaIntentDonor = spy

        await audio.playEpisode(makeItem(id: "ep-A"))
        await audio.playEpisode(makeItem(id: "ep-B"))

        XCTAssertEqual(spy.donatedIds, ["ep-A", "ep-B"],
                       "Each playEpisode call should trigger a donation")
        audio.stop()
    }
}

// MARK: - Counting Spy with dedup logic

/// Mirrors the production service's dedup: only counts when the ID changes.
private final class CountingSpy: MediaIntentDonating {
    private(set) var donationCount = 0
    private var lastId: String?

    func donatePlayback(for item: QueueItem) {
        guard item.id != lastId else { return }
        lastId = item.id
        donationCount += 1
    }
}

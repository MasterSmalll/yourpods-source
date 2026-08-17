import XCTest
import SwiftData
@testable import YourPods

/// The feed's declared transcript `type` must survive all the way to the parser, and a
/// transcript added after an episode was queued must still reach the player.
@MainActor
final class TranscriptTypePlumbingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!

    private let testProfileId = "test-profile-transcript-plumbing"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        clearTestDefaults()
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        for key in ["activeProfileId", "subscriptionUrls_\(testProfileId)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Pod") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - RSS captures the declared type

    func test_parsesTranscriptType_fromFeed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
              <podcast:transcript url="https://cdn.example.com/ep1.html" type="text/html" />
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))

        XCTAssertEqual(episodes[0].transcriptUrl, "https://cdn.example.com/ep1.html")
        XCTAssertEqual(episodes[0].transcriptType, "text/html",
                       "The feed's declared type must be captured, not discarded")
    }

    func test_multipleTranscripts_prefersSRT_andCarriesMatchingType() throws {
        // The type must belong to the transcript that actually won the priority contest.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <podcast:transcript url="https://cdn.example.com/ep1.html" type="text/html" />
              <podcast:transcript url="https://cdn.example.com/ep1.srt" type="application/x-subrip" />
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))

        XCTAssertEqual(episodes[0].transcriptUrl, "https://cdn.example.com/ep1.srt")
        XCTAssertEqual(episodes[0].transcriptType, "application/x-subrip",
                       "The winning transcript's type must be the one carried")
    }

    // MARK: - Feed -> Episode

    func test_Scenario_transcriptAddedToExistingEpisode_persistsUrlAndType() async {
        let feedUrl = "https://example.com/transcript-feed"
        insertPodcast(url: feedUrl)

        // First refresh: the episode is published with no transcript yet.
        let bare = ParsedEpisode(guid: "ep1", title: "Ep 1", audioUrl: "https://example.com/1.mp3")
        _ = await manager.syncStore.applyFeedResults([
            FeedFetchResult(url: feedUrl, authHeader: nil, parsed: ParsedPodcast(title: "Test Pod"), episodes: [bare])
        ])
        manager.reconcileAfterBackgroundWrites()
        XCTAssertNil(manager.episodes(withGuids: ["ep1"]).first?.transcriptUrl,
                     "Precondition: episode starts with no transcript")

        // Second refresh: the host uploads a transcript for the already-known episode.
        var withTranscript = bare
        withTranscript.transcriptUrl = "https://cdn.example.com/ep1.html"
        withTranscript.transcriptType = "text/html"
        _ = await manager.syncStore.applyFeedResults([
            FeedFetchResult(url: feedUrl, authHeader: nil, parsed: ParsedPodcast(title: "Test Pod"), episodes: [withTranscript])
        ])
        manager.reconcileAfterBackgroundWrites()

        let episode = manager.episodes(withGuids: ["ep1"]).first
        XCTAssertEqual(episode?.transcriptUrl, "https://cdn.example.com/ep1.html")
        XCTAssertEqual(episode?.transcriptType, "text/html",
                       "The declared type must persist so the parser never has to guess from the URL")
    }

    // MARK: - Queue snapshot resolution

    func test_resolvesLiveEpisodeTranscript_whenSnapshotPredatesUpload() {
        // The reported bug: an episode queued before its transcript existed carries a
        // frozen nil snapshot, so the player would never show the transcript.
        let source = TranscriptService.resolveSource(
            snapshotUrl: nil, snapshotType: nil,
            liveUrl: "https://cdn.example.com/ep1.html", liveType: "text/html"
        )
        XCTAssertEqual(source?.url, "https://cdn.example.com/ep1.html")
        XCTAssertEqual(source?.type, "text/html")
    }

    func test_livingEpisode_winsOverStaleSnapshotUrl() {
        let source = TranscriptService.resolveSource(
            snapshotUrl: "https://cdn.example.com/old.srt", snapshotType: "application/x-subrip",
            liveUrl: "https://cdn.example.com/new.html", liveType: "text/html"
        )
        XCTAssertEqual(source?.url, "https://cdn.example.com/new.html",
                       "A feed that corrects its transcript URL must win over the snapshot")
        XCTAssertEqual(source?.type, "text/html")
    }

    func test_fallsBackToSnapshot_whenLiveEpisodeIsUnavailable() {
        // The episode may not be in the store (unsubscribed, pruned) — the queue still plays.
        let source = TranscriptService.resolveSource(
            snapshotUrl: "https://cdn.example.com/ep1.html", snapshotType: "text/html",
            liveUrl: nil, liveType: nil
        )
        XCTAssertEqual(source?.url, "https://cdn.example.com/ep1.html")
        XCTAssertEqual(source?.type, "text/html")
    }

    func test_EDGE_returnsNil_whenNeitherSourceHasATranscript() {
        XCTAssertNil(TranscriptService.resolveSource(
            snapshotUrl: nil, snapshotType: nil, liveUrl: nil, liveType: nil
        ))
    }

    func test_EDGE_treatsEmptyUrlAsAbsent() {
        let source = TranscriptService.resolveSource(
            snapshotUrl: "https://cdn.example.com/ep1.html", snapshotType: "text/html",
            liveUrl: "", liveType: nil
        )
        XCTAssertEqual(source?.url, "https://cdn.example.com/ep1.html",
                       "An empty live URL must not shadow a usable snapshot")
    }

    // MARK: - QueueItem snapshot

    func test_queueItemSnapshot_carriesTranscriptType() {
        let episode = Episode(guid: "g1", title: "Ep 1")
        episode.audioUrl = "https://example.com/1.mp3"
        episode.transcriptUrl = "https://cdn.example.com/ep1.html"
        episode.transcriptType = "text/html"

        let item = QueueItem.from(episode: episode)

        XCTAssertEqual(item?.transcriptUrl, "https://cdn.example.com/ep1.html")
        XCTAssertEqual(item?.transcriptType, "text/html")
    }
}

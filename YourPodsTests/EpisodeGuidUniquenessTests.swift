import XCTest
import SwiftData
@testable import YourPods

/// Tests that episodes with the same GUID across different podcasts can coexist
/// without data loss or crashes.
///
/// Episode GUIDs (from RSS <guid>) are only unique within a single feed — different
/// podcasts frequently reuse the same GUID strings (e.g., simple integers "1",
/// URL-based IDs, or auto-generated values).
///
/// Bug: Episode.guid had @Attribute(.unique), which caused a SwiftData assertion
/// crash (ManagedObjectCodingContext.register) during save when two different podcasts
/// shared a GUID. This manifested as a crash on Pro sign-in when many feeds sync
/// simultaneously.
///
/// Fix: Removed @Attribute(.unique) from Episode.guid. Within-feed deduplication is
/// handled by PodcastManager.refreshFeed's existingGuids check.
@MainActor
final class EpisodeGuidUniquenessTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let testProfileId = "test-profile-guid"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_\(testProfileId)")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Cross-Podcast GUID Collision

    /// Two podcasts with episodes sharing the same GUID must both retain their episodes.
    func test_duplicateGuidAcrossPodcasts_bothEpisodesSurvive() {
        let podcast1 = Podcast(url: "https://feed-a.example.com/rss", title: "Podcast A")
        let podcast2 = Podcast(url: "https://feed-b.example.com/rss", title: "Podcast B")
        context.insert(podcast1)
        context.insert(podcast2)

        let ep1 = Episode(
            guid: "episode-1",
            title: "Episode 1 from Feed A",
            audioUrl: "https://feed-a.example.com/ep1.mp3",
            podcast: podcast1
        )
        let ep2 = Episode(
            guid: "episode-1",
            title: "Episode 1 from Feed B",
            audioUrl: "https://feed-b.example.com/ep1.mp3",
            podcast: podcast2
        )

        context.insert(ep1)
        context.insert(ep2)

        XCTAssertNoThrow(try context.save(), "Save should not crash with duplicate GUIDs across podcasts")

        let allEpisodes = try! context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(allEpisodes.count, 2, "Both episodes should exist")
        XCTAssertEqual(podcast1.episodes.count, 1, "Podcast A should have its episode")
        XCTAssertEqual(podcast2.episodes.count, 1, "Podcast B should have its episode")
    }

    /// Five podcasts each with an episode GUID of "1" should all coexist.
    func test_manyPodcastsSharingGuid_allPersist() {
        let sharedGuid = "1"
        var podcasts: [Podcast] = []

        for i in 0..<5 {
            let podcast = Podcast(url: "https://feed-\(i).example.com/rss", title: "Podcast \(i)")
            context.insert(podcast)
            let episode = Episode(
                guid: sharedGuid,
                title: "First Episode of Podcast \(i)",
                audioUrl: "https://feed-\(i).example.com/ep1.mp3",
                podcast: podcast
            )
            context.insert(episode)
            podcasts.append(podcast)
        }

        XCTAssertNoThrow(try context.save(), "Save should not crash with 5 podcasts sharing GUID '1'")

        let allEpisodes = try! context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(allEpisodes.count, 5, "All 5 episodes should exist")

        for podcast in podcasts {
            XCTAssertEqual(podcast.episodes.count, 1, "\(podcast.title) should have exactly 1 episode")
        }
    }

    // MARK: - Within-Feed Dedup (Application-Level)

    /// Within-feed deduplication is handled by PodcastManager's existingGuids check,
    /// not by a SwiftData constraint.
    func test_duplicateGuidWithinSamePodcast_detectedByExistingGuidsCheck() {
        let podcast = Podcast(url: "https://example.com/rss", title: "Test Podcast")
        context.insert(podcast)

        let ep1 = Episode(
            guid: "same-guid",
            title: "Original Episode",
            audioUrl: "https://example.com/ep1.mp3",
            podcast: podcast
        )
        context.insert(ep1)
        try! context.save()

        // This is the same check refreshFeed uses to skip duplicates
        let existingGuids = Set(podcast.episodes.map(\.guid))
        XCTAssertTrue(existingGuids.contains("same-guid"),
                      "existingGuids check should detect the duplicate before insert")
    }

    // MARK: - PodcastManager.persistPodcastFromSync

    /// persistPodcastFromSync should not crash when another podcast already has an
    /// episode with the same GUID.
    func test_persistPodcastFromSync_withGuidCollision_doesNotCrash() {
        let manager = PodcastManager(modelContext: context)

        let podcast1 = Podcast(url: "https://feed-a.com/rss", title: "Feed A")
        context.insert(podcast1)
        let ep1 = Episode(guid: "ep-shared", title: "Shared EP from A",
                          audioUrl: "https://a.com/ep.mp3", podcast: podcast1)
        context.insert(ep1)
        manager.associateWithCurrentProfile(url: podcast1.url)
        try! context.save()

        let parsed = ParsedPodcast(
            title: "Feed B",
            description: "Another podcast",
            logoUrl: nil,
            website: nil,
            author: nil
        )
        let parsedEpisode = ParsedEpisode(
            guid: "ep-shared",
            title: "Shared EP from B",
            description: nil,
            audioUrl: "https://b.com/ep.mp3",
            pubDate: nil,
            imageUrl: nil,
            durationSeconds: nil,
            link: nil,
            chaptersUrl: nil,
            transcriptUrl: nil
        )

        manager.persistPodcastFromSync(url: "https://feed-b.com/rss", parsed: parsed, episodes: [parsedEpisode])

        XCTAssertNoThrow(try context.save(),
                         "Save after persistPodcastFromSync with colliding GUIDs should not crash")

        let allEpisodes = try! context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(allEpisodes.count, 2, "Both episodes should exist")
        XCTAssertEqual(podcast1.episodes.first?.audioUrl, "https://a.com/ep.mp3",
                       "Feed A's episode should not be overwritten by Feed B")
    }
}

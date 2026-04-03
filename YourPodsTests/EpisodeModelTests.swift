import XCTest
import SwiftData
@testable import YourPods

/// Tests for Episode model computed properties.
/// Uses SwiftData in-memory container to avoid needing a persistent store.
final class EpisodeModelTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = ModelContext(container)
    }
    
    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }
    
    private func makeEpisode(
        guid: String = "ep-1",
        title: String = "Test Episode",
        durationSeconds: Int? = 3600,
        listenedSeconds: Int = 0,
        podcast: Podcast? = nil
    ) -> Episode {
        let ep = Episode(
            guid: guid,
            title: title,
            durationSeconds: durationSeconds,
            podcast: podcast
        )
        ep.listenedSeconds = listenedSeconds
        context.insert(ep)
        return ep
    }
    
    // MARK: - listenProgress
    
    func test_listenProgress_noListening() {
        let ep = makeEpisode(durationSeconds: 3600, listenedSeconds: 0)
        XCTAssertEqual(ep.listenProgress, 0.0, accuracy: 0.001)
    }
    
    func test_listenProgress_halfway() {
        let ep = makeEpisode(durationSeconds: 3600, listenedSeconds: 1800)
        XCTAssertEqual(ep.listenProgress, 0.5, accuracy: 0.001)
    }
    
    func test_listenProgress_complete() {
        let ep = makeEpisode(durationSeconds: 3600, listenedSeconds: 3600)
        XCTAssertEqual(ep.listenProgress, 1.0, accuracy: 0.001)
    }
    
    func test_listenProgress_overshot_clamped() {
        let ep = makeEpisode(durationSeconds: 3600, listenedSeconds: 4000)
        XCTAssertEqual(ep.listenProgress, 1.0, accuracy: 0.001,
                       "Progress should clamp to 1.0 when listened > duration")
    }
    
    func test_listenProgress_zeroDuration() {
        let ep = makeEpisode(durationSeconds: 0, listenedSeconds: 100)
        XCTAssertEqual(ep.listenProgress, 0.0,
                       "Zero duration should return 0.0 progress")
    }
    
    func test_listenProgress_nilDuration() {
        let ep = makeEpisode(durationSeconds: nil, listenedSeconds: 500)
        XCTAssertEqual(ep.listenProgress, 0.0,
                       "nil duration should return 0.0 progress")
    }
    
    // MARK: - duration computed property
    
    func test_duration_withSeconds() {
        let ep = makeEpisode(durationSeconds: 3600)
        XCTAssertEqual(ep.duration, 3600.0)
    }
    
    func test_duration_nilSeconds() {
        let ep = makeEpisode(durationSeconds: nil)
        XCTAssertNil(ep.duration)
    }
    
    // MARK: - Defaults
    
    func test_isInteracted_defaultsFalse() {
        let ep = makeEpisode()
        XCTAssertFalse(ep.isInteracted)
    }
    
    func test_isPlayed_defaultsFalse() {
        let ep = makeEpisode()
        XCTAssertFalse(ep.isPlayed)
    }
    
    func test_listenedSeconds_defaultsToZero() {
        let ep = Episode(guid: "test", title: "Test")
        context.insert(ep)
        XCTAssertEqual(ep.listenedSeconds, 0)
    }
    
    // MARK: - Podcast relationship
    
    func test_podcastUrl_fromRelation() {
        let podcast = Podcast(url: "https://example.com/feed", title: "My Podcast")
        context.insert(podcast)
        let ep = makeEpisode(podcast: podcast)
        XCTAssertEqual(ep.podcastUrl, "https://example.com/feed")
    }
    
    func test_podcastTitle_fromRelation() {
        let podcast = Podcast(url: "https://example.com/feed", title: "My Podcast")
        context.insert(podcast)
        let ep = makeEpisode(podcast: podcast)
        XCTAssertEqual(ep.podcastTitle, "My Podcast")
    }
    
    func test_podcastUrl_nilWithoutPodcast() {
        let ep = makeEpisode(podcast: nil)
        XCTAssertNil(ep.podcastUrl)
    }
}

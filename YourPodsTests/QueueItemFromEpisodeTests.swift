import XCTest
import SwiftData
@testable import YourPods

/// Tests for `QueueItem.from(episode:)` — verifying that previously-played
/// episodes reset their position to 0 instead of preserving the played position.
///
/// Root cause: episodes that were fully played have `listenedSeconds ≈ totalDuration`.
/// Without resetting, the player seeks to the end and `AVPlayerItemDidPlayToEndTime`
/// fires immediately, causing episodes to "finish without playing."
final class QueueItemFromEpisodeTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    
    override func setUp() {
        super.setUp()
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }
    
    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func makeEpisode(
        guid: String = "test-guid",
        title: String = "Test Episode",
        audioUrl: String = "https://example.com/episode.mp3",
        durationSeconds: Int = 3600,
        listenedSeconds: Int = 0,
        isPlayed: Bool = false
    ) -> Episode {
        let ep = Episode(
            guid: guid,
            title: title,
            audioUrl: audioUrl,
            durationSeconds: durationSeconds
        )
        ep.listenedSeconds = listenedSeconds
        ep.isPlayed = isPlayed
        context.insert(ep)
        return ep
    }
    
    // MARK: - Tests
    
    /// A fully-played episode should start from position 0 when re-queued.
    /// This is the primary bug fix — previously, the player would seek to 3400s
    /// of a 3600s episode and immediately "complete."
    func test_playedEpisode_resetsPositionToZero() {
        let ep = makeEpisode(
            durationSeconds: 3600,
            listenedSeconds: 3400,
            isPlayed: true
        )
        
        let item = QueueItem.from(episode: ep)
        
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.positionSeconds, 0, "Played episodes must start from 0 for re-listen")
    }
    
    /// A partially-listened (not-played) episode should resume from its saved position.
    func test_partiallyPlayedEpisode_preservesPosition() {
        let ep = makeEpisode(
            durationSeconds: 3600,
            listenedSeconds: 1800,
            isPlayed: false
        )
        
        let item = QueueItem.from(episode: ep)
        
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.positionSeconds, 1800, "Partially-listened episodes should resume from saved position")
    }
    
    /// When an explicit position override is provided for a played episode,
    /// the override takes precedence (used by sync/conflict resolution).
    func test_playedEpisode_withExplicitPosition_usesExplicit() {
        let ep = makeEpisode(
            durationSeconds: 3600,
            listenedSeconds: 3400,
            isPlayed: true
        )
        
        let item = QueueItem.from(episode: ep, positionSeconds: 500)
        
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.positionSeconds, 500, "Explicit position override should take precedence")
    }
    
    /// A fresh (never-listened) episode should start from position 0.
    func test_freshEpisode_startsAtZero() {
        let ep = makeEpisode(
            durationSeconds: 3600,
            listenedSeconds: 0,
            isPlayed: false
        )
        
        let item = QueueItem.from(episode: ep)
        
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.positionSeconds, 0, "Fresh episodes should start from 0")
    }
    
    /// An episode without an audio URL should return nil.
    func test_episodeWithoutAudioUrl_returnsNil() {
        let ep = makeEpisode(audioUrl: "")
        ep.audioUrl = nil
        
        let item = QueueItem.from(episode: ep)
        
        XCTAssertNil(item, "Episodes without audio URL should not create queue items")
    }
    
    /// A played episode with listenedSeconds at exactly the duration should reset to 0.
    func test_playedEpisode_atExactDuration_resetsToZero() {
        let ep = makeEpisode(
            durationSeconds: 3600,
            listenedSeconds: 3600,
            isPlayed: true
        )
        
        let item = QueueItem.from(episode: ep)
        
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.positionSeconds, 0, "Played episode at exact duration should reset to 0")
    }
}

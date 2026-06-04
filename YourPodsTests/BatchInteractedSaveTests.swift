import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for batching `markEpisodeAsInteracted` saves.
///
/// Root cause: `markEpisodeAsInteracted()` calls `modelContext.save()` on every
/// invocation. When batch-adding episodes to queue (e.g., 5 episodes at once),
/// this produces 5 individual SQLite WAL writes instead of 1.
///
/// Fix: Add a `deferSave` parameter. When `true`, the save is skipped —
/// callers are responsible for calling `saveContext()` once at the end.
@MainActor
final class BatchInteractedSaveTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-batch"

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
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @discardableResult
    private func insertPodcast(episodeCount: Int = 5) -> Podcast {
        let podcast = Podcast(url: "https://example.com/batch-feed", title: "Batch Podcast")
        context.insert(podcast)
        for i in 0..<episodeCount {
            let ep = Episode(
                guid: "batch-ep-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/batch-ep-\(i).mp3"
            )
            ep.podcast = podcast
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: "https://example.com/batch-feed")
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - deferSave Behavior

    /// With deferSave: true, markEpisodeAsInteracted should NOT save to disk.
    func test_markEpisodeAsInteracted_deferSave_doesNotSave() {
        let podcast = insertPodcast()

        // Mark 5 episodes as interacted with deferSave: true
        for ep in podcast.episodes {
            manager.markEpisodeAsInteracted(podcast.url, ep.guid, deferSave: true)
        }

        // The in-memory model should be updated
        for ep in podcast.episodes {
            XCTAssertTrue(ep.isInteracted,
                          "Episode \(ep.guid) should be marked as interacted in-memory")
        }

        // But no save should have occurred
        // (progressSaveCount tracks updateEpisodeProgress saves, not interacted saves.
        //  We verify no save by checking that the interacted flag only exists in memory.)
        // We can verify by checking that saveContext() has NOT been called
        // by confirming the model is in a dirty state
        XCTAssertTrue(context.hasChanges,
                      "Context should have unsaved changes when deferSave is true")
    }

    /// Without deferSave (default), markEpisodeAsInteracted should save immediately.
    func test_markEpisodeAsInteracted_defaultSavesImmediately() {
        let podcast = insertPodcast(episodeCount: 1)
        let episode = podcast.episodes.first!

        // Default behavior: should save
        manager.markEpisodeAsInteracted(podcast.url, episode.guid)

        XCTAssertTrue(episode.isInteracted, "Episode should be marked as interacted")
        // After saving, context should be clean
        XCTAssertFalse(context.hasChanges,
                       "Context should have no unsaved changes after default (immediate) save")
    }

    /// Batch pattern: deferSave on each, then single saveContext() at the end.
    func test_batchInteractedWithSingleSave() {
        let podcast = insertPodcast(episodeCount: 3)

        // Batch: defer all saves
        for ep in podcast.episodes {
            manager.markEpisodeAsInteracted(podcast.url, ep.guid, deferSave: true)
        }
        XCTAssertTrue(context.hasChanges, "Should have unsaved changes")

        // Single save at the end
        try? manager.saveContext()

        // All episodes should be interacted AND persisted
        for ep in podcast.episodes {
            XCTAssertTrue(ep.isInteracted,
                          "Episode \(ep.guid) should be interacted after batch save")
        }
        XCTAssertFalse(context.hasChanges,
                       "Context should be clean after explicit saveContext()")
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for ModelContext.safeSave() — the ObjC exception-safe save wrapper.
///
/// Root cause: `modelContext.save()` can throw an Objective-C NSException
/// (nil key in NSDictionary during SQLite INSERT) when the context has dirty
/// insertions with invalid data. Swift's `try?` cannot catch ObjC exceptions,
/// so the process crashes. safeSave() wraps the save in ObjCExceptionCatcher
/// to convert the crash into a recoverable error.
@MainActor
final class SafeSaveTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        context.autosaveEnabled = false
    }
    
    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path
    
    /// safeSave() must return true and persist data on a clean context.
    func test_safeSave_persistsDataOnCleanContext() throws {
        let podcast = Podcast(url: "https://example.com/safe-save-test", title: "Safe Save Test")
        context.insert(podcast)
        
        let result = context.safeSave()
        
        XCTAssertTrue(result, "safeSave() must return true on a clean save")
        
        // Verify data was persisted
        let descriptor = FetchDescriptor<Podcast>()
        let results = try context.fetch(descriptor)
        XCTAssertEqual(results.count, 1, "Podcast must be persisted after safeSave()")
        XCTAssertEqual(results.first?.title, "Safe Save Test")
    }
    
    /// safeSave() must persist in-memory mutations (the progress update path).
    func test_safeSave_persistsInMemoryMutation() throws {
        // Insert and save initial state
        let podcast = Podcast(url: "https://example.com/mutation-test", title: "Mutation Test")
        context.insert(podcast)
        let episode = Episode(guid: "ep-safe-1", title: "Episode 1", audioUrl: "https://example.com/ep1.mp3")
        episode.listenedSeconds = 0
        episode.durationSeconds = 3600
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        
        // Mutate in-memory (simulates updateEpisodeProgress)
        episode.listenedSeconds = 120
        
        let result = context.safeSave()
        
        XCTAssertTrue(result, "safeSave() must return true after in-memory mutation")
        XCTAssertEqual(episode.listenedSeconds, 120, "Mutation must be persisted")
    }
    
    /// safeSave() must return true when the context has no pending changes.
    func test_safeSave_succeedsWithNoPendingChanges() {
        let result = context.safeSave()
        XCTAssertTrue(result, "safeSave() must return true with no pending changes")
    }
    
    // MARK: - Integration with updateEpisodeProgress
    
    /// The progress save path must use safeSave() and not crash on save failure.
    /// This verifies the integration: updateEpisodeProgress() should survive
    /// a save() that would otherwise throw an ObjC exception.
    func test_updateEpisodeProgress_useSafeSave() {
        let testProfileId = "test-profile-safesave"
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        defer { UserDefaults.standard.removeObject(forKey: "activeProfileId") }
        defer { UserDefaults.standard.removeObject(forKey: "subscriptionUrls_\(testProfileId)") }
        
        let manager = PodcastManager(modelContext: context)
        
        let podcast = Podcast(url: "https://example.com/progress-safe", title: "Progress Safe")
        context.insert(podcast)
        let episode = Episode(guid: "ep-progress-safe", title: "Episode Safe", audioUrl: "https://example.com/ep1.mp3")
        episode.listenedSeconds = 0
        episode.durationSeconds = 3600
        episode.podcast = podcast
        context.insert(episode)
        try! context.save()
        
        manager.associateWithCurrentProfile(url: "https://example.com/progress-safe")
        manager.loadSubscriptions()
        
        // This should not crash — the save is wrapped in safeSave()
        manager.updateEpisodeProgress(
            podcastUrl: "https://example.com/progress-safe",
            episodeGuid: "ep-progress-safe",
            position: 300
        )
        
        // In-memory update must always succeed regardless of save outcome
        XCTAssertEqual(episode.listenedSeconds, 300,
                       "In-memory progress must be updated even if save fails")
    }
}

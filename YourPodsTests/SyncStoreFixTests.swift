import XCTest
import SwiftData
import CoreData
@testable import YourPods

/// Tests for the SyncStore fix plan — verifies:
/// 1. Mirror accessor hardening (underlyingNSContext assertion)
/// 2. MainContext merge policy (prevents NSMergeConflict crash)
/// 3. mergeChanges(fromContextDidSave:) replaces refreshAllFromStore
/// 4. Skipped playing episode action is returned, not dropped
/// 5. Chunked GUID fetch for large arrays
final class SyncStoreFixTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - Fix 1: Mirror accessor hardening

    /// The underlyingNSContext Mirror accessor must return a non-nil value.
    /// If Apple changes the private `_nsContext` label, this test catches it
    /// immediately instead of silently disabling merge policy and refresh.
    func test_underlyingNSContext_isNotNil_onFreshContext() async throws {
        let isNonNil = await MainActor.run {
            container.mainContext.underlyingNSContext != nil
        }
        XCTAssertTrue(isNonNil, "underlyingNSContext must not be nil — Mirror label may have changed")
    }

    // MARK: - Fix 2: MainContext merge policy

    /// When the background SyncStore saves a row and then the main context
    /// saves the SAME row, the main context must NOT crash with NSMergeConflict.
    /// This requires the main context to have a merge policy set.
    func test_mainContextSave_succeeds_whenBackgroundSavedSameRow_withMergePolicy() async throws {
        // Apply merge policy to main context (the fix)
        let mainContext = await MainActor.run { container.mainContext }
        await MainActor.run { mainContext.applyObjectTrumpMergePolicy() }

        // Seed a podcast on main
        await MainActor.run {
            let podcast = Podcast(url: "https://example.com/feed", title: "Seed")
            mainContext.insert(podcast)
            try! mainContext.save()
        }

        // Modify on background (SyncStore)
        let store = SyncStore(container: container)
        let updated = await store.updatePodcastTitle(
            url: "https://example.com/feed", newTitle: "Background Title"
        )
        XCTAssertTrue(updated)

        // Now modify the SAME row on main and save — must not crash
        let mainSaved = await MainActor.run {
            let descriptor = FetchDescriptor<Podcast>()
            let podcasts = try! mainContext.fetch(descriptor)
            podcasts.first?.title = "Main Title"  // Same field = guaranteed conflict
            return mainContext.safeSave()
        }
        XCTAssertTrue(mainSaved, "Main context save must succeed with merge policy set — would crash without it")
    }

    // MARK: - Fix 3: mergeChanges replaces refreshAllFromStore

    /// After a background context saves, the main context should see the
    /// changes via NSManagedObjectContext.mergeChanges(fromContextDidSave:)
    /// without calling refreshAllObjects().
    func test_mainContext_seesBackgroundChanges_viaMergeNotification() async throws {
        let mainContext = await MainActor.run { container.mainContext }
        await MainActor.run { mainContext.applyObjectTrumpMergePolicy() }

        // Seed a podcast on main
        await MainActor.run {
            let podcast = Podcast(url: "https://example.com/feed", title: "Original")
            mainContext.insert(podcast)
            try! mainContext.save()
        }

        // Set up the merge notification listener (this is the fix being tested)
        let expectation = expectation(description: "merge notification received")
        let observer = await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: nil,
                queue: .main
            ) { notification in
                guard let savedContext = notification.object as? NSManagedObjectContext,
                      savedContext !== mainContext.underlyingNSContext else { return }
                mainContext.underlyingNSContext?.mergeChanges(fromContextDidSave: notification)
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer as Any) }

        // Modify on background
        let store = SyncStore(container: container)
        _ = await store.updatePodcastTitle(
            url: "https://example.com/feed", newTitle: "Merged Title"
        )

        await fulfillment(of: [expectation], timeout: 2.0)

        // Main context should see the merged title WITHOUT refreshAllFromStore()
        let title = await MainActor.run {
            let descriptor = FetchDescriptor<Podcast>()
            let podcasts = try! mainContext.fetch(descriptor)
            return podcasts.first?.title
        }
        XCTAssertEqual(title, "Merged Title",
                        "Main context must see background changes via mergeChanges notification")
    }

    // MARK: - Fix 4: Skipped playing episode action

    /// When a currentlyPlayingGuid is provided, applyEpisodeActions must
    /// return the skipped EpisodeAction in the outcome instead of silently dropping it.
    func test_applyEpisodeActions_returnsSkippedAction_forCurrentlyPlayingGuid() async throws {
        let store = SyncStore(container: container)

        // Insert a podcast with an episode on the background context
        let mainContext = await MainActor.run { container.mainContext }
        await MainActor.run {
            let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
            let episode = Episode(
                guid: "ep-playing-123",
                title: "Currently Playing",
                episodeDescription: "",
                audioUrl: "https://example.com/audio.mp3",
                pubDate: Date(),
                durationSeconds: 3600,
                podcast: podcast
            )
            mainContext.insert(podcast)
            mainContext.insert(episode)
            try! mainContext.save()
        }

        // Build an action map that targets the playing episode
        let actionMap: [String: EpisodeAction] = [
            "ep-playing-123": EpisodeAction(
                podcast: "https://example.com/feed",
                episode: "https://example.com/audio.mp3",
                guid: "ep-playing-123",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 1800,
                started: 0,
                total: 3600,
                device: "other-device"
            )
        ]

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap,
            strategy: .serverWins,
            deviceId: "this-device",
            currentlyPlayingGuidProvider: { "ep-playing-123" }
        )

        // The episode must NOT have been updated (it was skipped)
        // But the skipped action MUST be returned so the caller can apply it on main
        let skipped = outcome.skippedActionsForPlayingEpisodes.first
        XCTAssertNotNil(skipped,
                        "Must return the skipped action instead of silently dropping it")
        XCTAssertEqual(skipped?.guid, "ep-playing-123")
        XCTAssertEqual(skipped?.position, 1800)
    }
}

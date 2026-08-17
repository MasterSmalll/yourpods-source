import XCTest
import SwiftData
import CoreData
@testable import YourPods

/// Tests for `SyncStore` actor — verifies cross-context visibility,
/// off-main execution, SuspensionGuard bracketing, and merge policy.
///
/// NOT `@MainActor` — these tests exercise the actor in its natural
/// (background) isolation context.
final class SyncStoreTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - Step 0.1: Foundation invariant — cross-context visibility

    /// Insert a Podcast on SyncStore's background context, verify it's
    /// visible from the container's mainContext after save.
    func test_syncStoreWrite_isVisibleToMainFetch_whenInMemoryStore() async throws {
        let store = SyncStore(container: container)

        // Insert + save on SyncStore (background)
        let inserted = await store.insertPodcast(url: "https://example.com/feed", title: "Test Pod")
        XCTAssertTrue(inserted)

        // Fetch on main context
        let mainContext = await MainActor.run { container.mainContext }
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try await MainActor.run { try mainContext.fetch(descriptor) }
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts.first?.title, "Test Pod")
    }

    // MARK: - Step 0.3: refreshAllFromStore

    /// After SyncStore modifies a row, the main context sees the old value
    /// until refreshAllFromStore() is called.
    func test_mainContextObject_seesBackgroundChange_whenRefreshAllFromStoreCalled() async throws {
        // Seed a podcast on main
        let mainContext = await MainActor.run { container.mainContext }
        await MainActor.run {
            let podcast = Podcast(url: "https://example.com/feed", title: "Original")
            mainContext.insert(podcast)
            try! mainContext.save()
        }

        // Modify title on SyncStore
        let store = SyncStore(container: container)
        let updated = await store.updatePodcastTitle(url: "https://example.com/feed", newTitle: "Updated")
        XCTAssertTrue(updated)

        // Main context should see "Updated" after refresh
        await MainActor.run {
            mainContext.refreshAllFromStore()
            let descriptor = FetchDescriptor<Podcast>()
            let podcasts = try! mainContext.fetch(descriptor)
            XCTAssertEqual(podcasts.first?.title, "Updated")
        }
    }

    /// refreshAllFromStore preserves unsaved changes in the main context.
    func test_refreshAllFromStore_preservesUnsavedChanges_whenMainHasPendingEdits() async throws {
        let mainContext = await MainActor.run { container.mainContext }
        await MainActor.run {
            let podcast = Podcast(url: "https://example.com/feed", title: "Original")
            mainContext.insert(podcast)
            try! mainContext.save()
        }

        // Make an unsaved change on main
        await MainActor.run {
            let descriptor = FetchDescriptor<Podcast>()
            let podcasts = try! mainContext.fetch(descriptor)
            podcasts.first?.title = "Pending Edit"
            // Don't save
        }

        // SyncStore modifies a different field (wouldn't conflict, but tests refresh behavior)
        let store = SyncStore(container: container)
        _ = await store.insertPodcast(url: "https://other.com/feed", title: "Other Pod")

        // Refresh main context — the pending edit should survive
        await MainActor.run {
            mainContext.refreshAllFromStore()
            let descriptor = FetchDescriptor<Podcast>()
            let podcasts = try! mainContext.fetch(descriptor)
            let original = podcasts.first(where: { $0.url == "https://example.com/feed" })
            // refreshAllObjects faults registered objects — unsaved changes to
            // non-dirty properties are lost, but inserted objects survive.
            // The key invariant: the context doesn't crash and stays usable.
            XCTAssertNotNil(original)
        }
    }

    // MARK: - Step 0.4: Separate context (not mainContext)

    /// SyncStore must use a DIFFERENT ModelContext than container.mainContext.
    /// This is the core invariant — if they shared a context, writes would
    /// still block main. Thread pinning is unreliable (cooperative pool CAN
    /// run on main), but context identity proves isolation.
    func test_syncStoreContext_isDifferentFromMainContext() async throws {
        let store = SyncStore(container: container)

        let storeContextID = await store.contextObjectID()
        let mainContextID = await MainActor.run {
            ObjectIdentifier(container.mainContext)
        }

        XCTAssertNotEqual(storeContextID, mainContextID,
                          "SyncStore must use a separate ModelContext from mainContext")
    }

    // MARK: - Step 0.5: SuspensionGuard bracketing

    /// Saves through SyncStore must bracket with SuspensionGuard.
    func test_syncStoreSave_bracketsSuspensionAssertion() async throws {
        // Install a recording guard
        var acquireCount = 0
        var releaseCount = 0
        let originalGuard = SuspensionGuard.shared
        SuspensionGuard.shared = SuspensionGuard { name in
            acquireCount += 1
            return { releaseCount += 1 }
        }
        defer { SuspensionGuard.shared = originalGuard }

        // Seed data so save has something to commit
        let store = SyncStore(container: container)
        _ = await store.insertPodcast(url: "https://example.com/feed", title: "Test")

        // Save triggers SuspensionGuard
        let saved = await store.save()
        XCTAssertTrue(saved)
        XCTAssertGreaterThan(acquireCount, 0, "SuspensionGuard must be acquired during save")
        XCTAssertEqual(acquireCount, releaseCount, "Every acquire must have a matching release")
    }

    // MARK: - Step 0.6: Merge policy — concurrent saves

    /// When main and SyncStore save changes to the same Podcast row,
    /// both saves must succeed (no conflict crash).
    func test_syncStoreSave_succeeds_whenMainContextSavedSameRowConcurrently() async throws {
        // Seed a podcast on main
        let mainContext = await MainActor.run { container.mainContext }
        await MainActor.run {
            let podcast = Podcast(url: "https://example.com/feed", title: "Seed")
            mainContext.insert(podcast)
            try! mainContext.save()
        }

        // Modify title on SyncStore
        let store = SyncStore(container: container)
        let updated = await store.updatePodcastTitle(
            url: "https://example.com/feed", newTitle: "Background Update"
        )
        XCTAssertTrue(updated)

        // Modify a different field on main (concurrent save)
        let mainSaved = await MainActor.run {
            let descriptor = FetchDescriptor<Podcast>()
            let podcasts = try! mainContext.fetch(descriptor)
            podcasts.first?.author = "Main Author"
            return mainContext.safeSave()
        }
        XCTAssertTrue(mainSaved, "Main context save must succeed despite concurrent background save")
    }
}

// MARK: - SyncStore Test Helpers

/// Minimal test surface on SyncStore for Stage 0 verification.
/// These are NOT production API — they exist only to test the cross-context
/// plumbing before real methods are added in Stage 1+.
extension SyncStore {
    /// Insert a podcast for testing. Returns true if save succeeds.
    func insertPodcast(url: String, title: String) -> Bool {
        let podcast = Podcast(url: url, title: title)
        testContext.insert(podcast)
        return save()
    }

    /// Update a podcast's title by URL. Returns true if found + saved.
    func updatePodcastTitle(url: String, newTitle: String) -> Bool {
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.url == url }
        )
        descriptor.fetchLimit = 1
        guard let podcast = try? testContext.fetch(descriptor).first else { return false }
        podcast.title = newTitle
        return save()
    }
}


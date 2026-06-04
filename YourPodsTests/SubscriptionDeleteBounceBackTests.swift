import XCTest
import SwiftData
@testable import YourPods

/// Regression tests for the "subscription delete bounce-back" bug.
///
/// Root causes found across multiple sessions:
///   1. Pull-before-push: server overwrites local deletion before POST fires.
///   2. Pro full-list pull: `localSubscriptionsToUpload` re-pushes deleted URL as an add.
///   3. Unconditional pending-removal clear: if push fails (try?), the URL was
///      cleared from pending, so it bounced back on the next sync.
///
/// Fix: persist pending removals, push-first, filter bounce-backs, and only
/// clear pending removals for URLs that were CONFIRMED pushed successfully.
@MainActor
final class SubscriptionDeleteBounceBackTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-delete-bounceback"

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
            "lastSubscriptionSync_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
            "serverProfiles",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - Phase 1: Pending Removal Tracking

    func test_removeSubscription_recordsPendingRemoval() async {
        let url = "https://example.com/hardcore-history"
        let podcast = insertPodcast(url: url, title: "Hardcore History")
        let mockClient = MockSyncClientForDeletion()
        manager.setSyncClient(mockClient, deviceId: "test-device")

        await manager.removeSubscription(podcast)

        let pending = manager.pendingSubscriptionRemovals()
        XCTAssertTrue(pending.contains(url),
                      "Deleted URL must be recorded in pendingSubscriptionRemovals so it can be re-pushed on next sync")
    }

    func test_pendingRemovals_persistAcrossManagerInstances() async {
        let url = "https://example.com/podcast-to-delete"
        let podcast = insertPodcast(url: url)
        let mockClient = MockSyncClientForDeletion()
        manager.setSyncClient(mockClient, deviceId: "test-device")
        await manager.removeSubscription(podcast)

        let manager2 = PodcastManager(modelContext: context)

        let pending = manager2.pendingSubscriptionRemovals()
        XCTAssertTrue(pending.contains(url),
                      "Pending removals must be persisted so they survive app restarts")
    }

    // MARK: - Phase 2: Push-First + Bounce-Back Prevention

    func test_syncSubscriptions_doesNotReAddDeletedPodcast() async throws {
        let deletedUrl = "https://example.com/deleted-podcast"
        let keptUrl    = "https://example.com/kept-podcast"
        manager.addPendingSubscriptionRemoval(deletedUrl)

        let mockClient = MockSyncClientForDeletion()
        await mockClient.setServerSubscriptions([deletedUrl, keptUrl])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        _ = try await manager.syncSubscriptions()

        manager.loadSubscriptions()
        let localUrls = manager.subscriptions.map(\.url)
        XCTAssertFalse(localUrls.contains(deletedUrl),
                       "syncSubscriptions must not re-add a URL that is in pendingSubscriptionRemovals")
    }

    func test_syncSubscriptions_pushesRemovalBeforePull() async throws {
        let deletedUrl = "https://example.com/deleted-podcast"
        manager.addPendingSubscriptionRemoval(deletedUrl)

        let mockClient = MockSyncClientForDeletion()
        await mockClient.setServerSubscriptions([deletedUrl])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        _ = try await manager.syncSubscriptions()

        let removals = await mockClient.pushedRemovals
        let pushIdx  = await mockClient.pushCallIndex
        let pullIdx  = await mockClient.pullCallIndex

        XCTAssertTrue(removals.contains(deletedUrl),
                      "syncSubscriptions must push pending removals to the server")
        XCTAssertLessThan(pushIdx, pullIdx,
                          "Push must happen before pull — push-first invariant")
    }

    func test_syncSubscriptions_clearsPendingRemovalOnSuccess() async throws {
        let deletedUrl = "https://example.com/deleted-podcast"
        manager.addPendingSubscriptionRemoval(deletedUrl)

        let mockClient = MockSyncClientForDeletion()
        manager.setSyncClient(mockClient, deviceId: "test-device")

        _ = try await manager.syncSubscriptions()

        let pending = manager.pendingSubscriptionRemovals()
        XCTAssertFalse(pending.contains(deletedUrl),
                       "Pending removal must be cleared after a confirmed successful push to server")
    }

    /// CRITICAL — root cause of the bug recurring across multiple "fix" attempts.
    /// When the push fails (network hiccup, expired token, server error), the pending
    /// removal must NOT be cleared. Previously `clearAllPendingSubscriptionRemovals()`
    /// was called unconditionally at end-of-sync, wiping the set even on push failure.
    /// On the next sync there was nothing to push, so the server re-added the podcast.
    func test_syncSubscriptions_retainsPendingRemovalWhenPushFails() async throws {
        let deletedUrl = "https://example.com/deleted-podcast"
        manager.addPendingSubscriptionRemoval(deletedUrl)

        let mockClient = MockSyncClientForDeletion()
        await mockClient.setFailPush(true)          // simulate network / auth failure
        manager.setSyncClient(mockClient, deviceId: "test-device")

        _ = try await manager.syncSubscriptions()

        let pending = manager.pendingSubscriptionRemovals()
        XCTAssertTrue(pending.contains(deletedUrl),
                      "REGRESSION: push failure must NOT clear the pending removal — it stays for retry on next sync")
    }

    // MARK: - Phase 3: Pro-Specific Second Vector

    /// For YourPods Pro, `pullSubscriptionChanges` returns the FULL server list as `add`.
    /// A deleted URL absent locally but present on the server would be seen by
    /// `localSubscriptionsToUpload` as "local-only" and re-pushed as an add to the server.
    func test_proSync_doesNotReAddDeletedPodcastViaLocalOnlyPush() async throws {
        let deletedUrl = "https://example.com/hardcore-history"
        let keptUrl    = "https://example.com/kept-podcast"
        manager.addPendingSubscriptionRemoval(deletedUrl)

        insertPodcast(url: keptUrl, title: "Kept Podcast")

        let mockClient = MockSyncClientForDeletion()
        await mockClient.setServerSubscriptions([deletedUrl, keptUrl])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        _ = try await manager.syncSubscriptions()

        let adds = await mockClient.pushedAdds
        XCTAssertFalse(adds.contains(deletedUrl),
                       "Pro bounce-back: deleted URL must not be re-pushed to server as an add via localSubscriptionsToUpload")
    }

    // MARK: - Phase 4: Server-Authoritative Sync (remote deletions)

    /// Server-side deletion (web / another device) must propagate to iOS.
    /// If a podcast exists locally, is NOT on the server, and is NOT in pendingAdds,
    /// it was deleted from another device → the app must remove it locally.
    ///
    /// This is the bug reported: web deletes a podcast, iOS re-adds it because
    /// localSubscriptionsToUpload treated it as a pending add.
    func test_syncSubscriptions_removesLocalPodcastDeletedFromServer() async throws {
        // GIVEN: Two podcasts in local library
        let keptUrl    = "https://example.com/kept-podcast"
        let deletedUrl = "https://example.com/server-deleted-podcast"
        insertPodcast(url: keptUrl,    title: "Kept Podcast")
        insertPodcast(url: deletedUrl, title: "Server Deleted Podcast")

        // Server only has the kept one (simulating a web deletion of deletedUrl)
        let mockClient = MockSyncClientForDeletion()
        await mockClient.setServerSubscriptions([keptUrl])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Sync runs — deletedUrl is NOT in pendingAdds (not added locally)
        _ = try await manager.syncSubscriptions()

        // THEN: The locally-deleted podcast must be removed from the local library
        manager.loadSubscriptions()
        let localUrls = manager.subscriptions.map(\.url)
        XCTAssertFalse(localUrls.contains(deletedUrl),
                       "Server-authoritative sync: podcast deleted from server must be removed locally. " +
                       "Without pendingAdds tracking, localSubscriptionsToUpload re-adds it instead.")
    }

    /// When a podcast was added locally (pendingAdd) but server doesn't have it yet,
    /// the app must push it to server — NOT treat it as a remote deletion and remove it.
    func test_syncSubscriptions_doesNotRemoveLocalPendingAdd() async throws {
        // GIVEN: User added a new podcast locally (not yet synced to server)
        let newLocalUrl = "https://example.com/new-local-podcast"
        insertPodcast(url: newLocalUrl, title: "New Local Podcast")
        manager.addPendingSubscriptionAdd(newLocalUrl)  // marks it as locally-added

        // Server doesn't have this URL yet
        let mockClient = MockSyncClientForDeletion()
        await mockClient.setServerSubscriptions([])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Sync runs
        _ = try await manager.syncSubscriptions()

        // THEN: The new podcast must still be in local library (not removed as "remote deletion")
        manager.loadSubscriptions()
        let localUrls = manager.subscriptions.map(\.url)
        XCTAssertTrue(localUrls.contains(newLocalUrl),
                      "Pending adds must NOT be treated as remote deletions — user just added this locally.")

        // AND: It must have been pushed to the server as an add
        let adds = await mockClient.pushedAdds
        XCTAssertTrue(adds.contains(newLocalUrl),
                      "Pending local add must be pushed to server during sync.")
    }
}

// MARK: - Mock SyncClient (Actor)

actor MockSyncClientForDeletion: SyncClient {
    var serverSubscriptions: [String] = []
    var pushedRemovals: [String] = []
    var pushedAdds: [String] = []
    var pushCallIndex: Int = Int.max
    var pullCallIndex: Int = Int.max
    private var callCounter = 0
    private var shouldFailPush = false

    func setServerSubscriptions(_ urls: [String]) { serverSubscriptions = urls }
    func setFailPush(_ fail: Bool) { shouldFailPush = fail }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        if shouldFailPush {
            throw URLError(.notConnectedToInternet)
        }
        callCounter += 1
        pushCallIndex = min(pushCallIndex, callCounter)
        pushedRemovals.append(contentsOf: remove)
        pushedAdds.append(contentsOf: add)
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        callCounter += 1
        pullCallIndex = min(pullCallIndex, callCounter)
        return SubscriptionDelta(add: serverSubscriptions, remove: [], timestamp: 1000)
    }

    // MARK: Unused protocol stubs
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

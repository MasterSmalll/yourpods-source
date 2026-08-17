import XCTest
import SwiftData
@testable import YourPods

/// Tests for the episode action outbox + push-before-pull.
///
/// Root cause R1: sendEpisodeAction does `_ = try? await ...` — swallowed,
/// never retried. The outbox ensures every action eventually reaches the server.
@MainActor
final class EpisodeActionOutboxTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-outbox"
    private let testDeviceId = "test-device-outbox"
    private var testOutboxURL: URL!

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)

        // Use a temp file for outbox isolation
        testOutboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-outbox-\(UUID().uuidString).json")
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: testOutboxURL)
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
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Helpers

    private func makeService(
        client: SyncClient? = nil,
        outboxURL: URL? = nil
    ) -> EpisodeActionSyncService {
        let url = outboxURL ?? testOutboxURL
        return EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { client },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId },
            outboxFileURL: url
        )
    }

    private func makeAction(guid: String, position: Int, timestamp: Int? = nil) -> EpisodeAction {
        EpisodeAction(
            podcast: "https://example.com/pod1",
            episode: "https://example.com/ep-\(guid).mp3",
            guid: guid,
            action: "play",
            timestamp: timestamp ?? Int(Date().timeIntervalSince1970),
            position: position,
            started: 0,
            total: 3600,
            device: testDeviceId
        )
    }

    @discardableResult
    private func insertPodcast(url: String = "https://example.com/pod1") -> Podcast {
        let podcast = Podcast(url: url, title: "Test Podcast")
        context.insert(podcast)
        let ep = Episode(
            guid: "ep-1",
            title: "Episode 1",
            audioUrl: "https://example.com/ep-ep-1.mp3",
            pubDate: Date(),
            durationSeconds: 3600,
            podcast: podcast
        )
        context.insert(ep)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    // MARK: - 1.1 Outbox API

    /// sendEpisodeAction must keep the action in the outbox when upload throws.
    func test_sendEpisodeAction_keepsActionInOutbox_whenUploadThrows() async {
        let failClient = OutboxMockSyncClient(shouldFail: true)
        let service = makeService(client: failClient)

        let action = makeAction(guid: "fail-guid", position: 300)
        await service.sendEpisodeAction(action)

        XCTAssertFalse(service.outbox.isEmpty,
                       "Action must remain in outbox after upload failure")
        XCTAssertEqual(service.outbox["fail-guid"]?.action.position, 300)
    }

    /// sendEpisodeAction must clear the outbox entry when upload succeeds.
    func test_sendEpisodeAction_clearsOutboxEntry_whenUploadSucceeds() async {
        let successClient = OutboxMockSyncClient(shouldFail: false)
        let service = makeService(client: successClient)

        let action = makeAction(guid: "ok-guid", position: 300)
        await service.sendEpisodeAction(action)

        XCTAssertTrue(service.outbox.isEmpty,
                      "Outbox must be empty after successful upload")
    }

    // MARK: - 1.2 Flush algorithm

    /// flushOutbox must keep an entry if it was replaced during flight.
    func test_outboxFlush_keepsEntry_whenReplacedDuringFlight() async {
        let slowClient = OutboxMockSyncClient(shouldFail: false)
        let service = makeService(client: slowClient)

        // Enqueue action1
        let action1 = makeAction(guid: "race-guid", position: 100, timestamp: 1000)
        service.enqueueOutboxAction(action1)

        // Flush (will succeed and remove the entry)...
        await service.flushOutbox()

        // ... then immediately enqueue a newer action for the same GUID
        let action2 = makeAction(guid: "race-guid", position: 500, timestamp: 2000)
        service.enqueueOutboxAction(action2)

        // The newer entry must be in the outbox (action1 was flushed, action2 is pending)
        XCTAssertEqual(service.outbox["race-guid"]?.action.position, 500,
                       "Newer entry must exist in outbox after flush + re-enqueue")
    }

    /// Outbox must restore from file across service reinit.
    func test_outbox_restoresFromFile_acrossServiceReinit() {
        // Use a specific file path to ensure both services share it
        let sharedURL = testOutboxURL!
        let dummyClient = OutboxMockSyncClient(shouldFail: true)
        let service1 = makeService(client: dummyClient, outboxURL: sharedURL)

        let action = makeAction(guid: "persist-guid", position: 400)
        service1.enqueueOutboxAction(action)

        // Verify the file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path),
                      "Outbox file must exist after enqueue")

        // New service instance with the same outbox file
        let service2 = makeService(client: dummyClient, outboxURL: sharedURL)
        service2.loadOutbox()

        XCTAssertEqual(service2.outbox["persist-guid"]?.action.position, 400,
                       "Outbox must survive service reinit via file persistence")
    }

    /// flushOutbox must skip network when the task is cancelled.
    func test_outboxFlush_skipsNetwork_whenTaskCancelled() async {
        let trackingClient = OutboxMockSyncClient(shouldFail: false)
        let service = makeService(client: trackingClient)

        let action = makeAction(guid: "cancel-guid", position: 200)
        service.enqueueOutboxAction(action)

        // Create and immediately cancel the task
        let flushTask = Task {
            await service.flushOutbox()
        }
        flushTask.cancel()
        await flushTask.value

        // Action must still be in outbox (not uploaded)
        XCTAssertFalse(service.outbox.isEmpty,
                       "Cancelled flush must not remove outbox entries")
        let uploaded = await trackingClient.uploadedActions
        XCTAssertTrue(uploaded.isEmpty,
                      "Cancelled flush must not call uploadEpisodeActions")
    }

    /// flushOutbox must only upload entries for the active profile.
    func test_outboxFlush_onlyUploadsActiveProfileEntries() async {
        let trackingClient = OutboxMockSyncClient(shouldFail: false)
        
        // Service 1: enqueue for "other-profile"
        let otherService = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { trackingClient },
            profileIdProvider: { "other-profile" },
            deviceIdProvider: { self.testDeviceId },
            outboxFileURL: testOutboxURL
        )
        let otherAction = makeAction(guid: "other-guid", position: 200)
        otherService.enqueueOutboxAction(otherAction)
        
        // Service 2: enqueue for the active profile and flush
        let service = makeService(client: trackingClient)
        service.loadOutbox() // picks up the other-profile entry from disk
        
        let action1 = makeAction(guid: "active-guid", position: 100)
        service.enqueueOutboxAction(action1)

        await service.flushOutbox()

        // Only the active profile's entry should have been uploaded
        let uploaded = await trackingClient.uploadedActions
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.guid, "active-guid")

        // The other-profile entry must remain
        XCTAssertNotNil(service.outbox["other-guid"],
                        "Other-profile entries must not be removed by flush")
    }

    /// Vault mode (no sync client) must not enqueue actions.
    func test_vaultMode_doesNotEnqueue_whenNoSyncClient() {
        let service = makeService(client: nil)

        let action = makeAction(guid: "vault-guid", position: 100)
        service.enqueueOutboxAction(action)

        XCTAssertTrue(service.outbox.isEmpty,
                      "Vault mode must not enqueue outbox actions")

        // But actionMap should still be updated
        XCTAssertEqual(service.actionMap["vault-guid"]?.position, 100,
                       "Vault mode must still update actionMap locally")
    }

    /// Force pull must preserve and flush outbox entries.
    func test_forcePull_preservesAndFlushesOutboxEntries() async throws {
        insertPodcast()
        let trackingClient = OutboxMockSyncClient(shouldFail: false)
        let service = makeService(client: trackingClient)
        service.loadActionMap()

        // Enqueue an action before sync
        let action = makeAction(guid: "pre-sync-guid", position: 300)
        service.enqueueOutboxAction(action)

        // Run sync (force=true) — outbox should be flushed as first step
        _ = try await service.syncEpisodeActions(force: true, strategy: .serverWins)

        // Outbox should be empty after successful flush
        XCTAssertTrue(service.outbox.isEmpty,
                      "Outbox must be empty after sync flushes it")

        // The action should have been uploaded
        let uploaded = await trackingClient.uploadedActions
        XCTAssertTrue(uploaded.contains(where: { $0.guid == "pre-sync-guid" }),
                      "Sync must flush outbox as push-before-pull")
    }

    /// Outbox must cap at maxEntries, dropping oldest.
    func test_outbox_dropsOldestEntry_beyondCap() {
        let service = makeService(client: OutboxMockSyncClient(shouldFail: true))

        // Fill up to max + 1 with distinct timestamps
        let max = 500
        for i in 0...max {
            let action = makeAction(guid: "cap-\(i)", position: i, timestamp: i)
            service.enqueueOutboxAction(action)
        }

        XCTAssertLessThanOrEqual(service.outbox.count, max,
                                 "Outbox must cap at \(max) entries")

        // The oldest entry (timestamp 0) should have been dropped
        XCTAssertNil(service.outbox["cap-0"],
                     "Oldest entry must be dropped when cap exceeded")

        // The newest entry should exist
        XCTAssertNotNil(service.outbox["cap-\(max)"],
                        "Newest entry must survive cap enforcement")
    }

    /// Summary's pushedCount must reflect the outbox flush.
    func test_syncEpisodeActions_recordsPushedCount_fromOutboxFlush() async throws {
        insertPodcast()
        let trackingClient = OutboxMockSyncClient(shouldFail: false)
        let service = makeService(client: trackingClient)
        service.loadActionMap()

        let action1 = makeAction(guid: "push-1", position: 100)
        let action2 = makeAction(guid: "push-2", position: 200)
        service.enqueueOutboxAction(action1)
        service.enqueueOutboxAction(action2)

        _ = try await service.syncEpisodeActions(force: true, strategy: .serverWins)

        let summary = service.lastSyncSummary
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.pushedCount, 2,
                       "pushedCount must reflect the number of outbox entries flushed")
    }
}

// MARK: - Mock SyncClient

actor OutboxMockSyncClient: SyncClient {
    let shouldFail: Bool
    let uploadDelay: TimeInterval
    private(set) var uploadedActions: [EpisodeAction] = []

    init(shouldFail: Bool, uploadDelay: TimeInterval = 0) {
        self.shouldFail = shouldFail
        self.uploadDelay = uploadDelay
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        if uploadDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(uploadDelay * 1_000_000_000))
        }
        if shouldFail {
            throw NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }
        uploadedActions.append(contentsOf: actions)
        return []
    }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

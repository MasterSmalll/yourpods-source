import XCTest
import SwiftData
@testable import YourPods

/// Tests for the server-returned since token + echo guard.
///
/// Root cause R2: since advancement uses wall-clock time instead of the
/// server-returned timestamp, causing missed or duplicated actions on
/// clock-skewed devices.
@MainActor
final class EpisodeActionSinceTokenTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-since-token"
    private let testDeviceId = "test-device-since"
    private var testOutboxURL: URL!

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
        testOutboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-since-\(UUID().uuidString).json")
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
        client: SyncClient? = nil
    ) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { client },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId },
            outboxFileURL: testOutboxURL
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

    // MARK: - 2.1 EpisodeActionsPage

    /// The default extension method should wrap getEpisodeActions with nil timestamp.
    func test_getEpisodeActionsPage_defaultExtension_wrapsWithNilTimestamp() async throws {
        let client = SinceTokenMockSyncClient(
            actions: [makeAction(guid: "a", position: 100)],
            serverTimestamp: nil
        )
        let page = try await client.getEpisodeActionsPage(since: 0)
        XCTAssertEqual(page.actions.count, 1)
        XCTAssertNil(page.serverTimestamp,
                     "Default extension must return nil serverTimestamp")
    }

    // MARK: - 2.2 Since advancement

    /// When the server provides a timestamp, use it verbatim (not wall-clock).
    func test_nextSince_usesServerTimestamp_whenProvided() async throws {
        insertPodcast()
        let serverTs = 999_888_777
        let client = SinceTokenMockSyncClient(
            actions: [makeAction(guid: "ep-1", position: 100)],
            serverTimestamp: serverTs
        )
        let service = makeService(client: client)
        service.loadActionMap()

        _ = try await service.syncEpisodeActions(force: true, strategy: .serverWins)

        let savedSince = UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(testProfileId)")
        XCTAssertEqual(savedSince, serverTs,
                       "Since must use server timestamp, not wall-clock")
    }

    /// When the server doesn't provide a timestamp, advance to the newest action timestamp.
    func test_nextSince_advancesToNewestActionTimestamp_whenServerTimestampAbsent() async throws {
        insertPodcast()
        let newestTs = 1_500_000_000
        let client = SinceTokenMockSyncClient(
            actions: [
                makeAction(guid: "ep-1", position: 100, timestamp: 1_400_000_000),
                makeAction(guid: "ep-2", position: 200, timestamp: newestTs),
            ],
            serverTimestamp: nil
        )
        let service = makeService(client: client)
        service.loadActionMap()

        UserDefaults.standard.set(1_300_000_000, forKey: "lastEpisodeActionSync_\(testProfileId)")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)

        let savedSince = UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(testProfileId)")
        XCTAssertEqual(savedSince, newestTs,
                       "Without server timestamp, since must advance to newest action timestamp")
    }

    /// Empty response without server timestamp must not advance since.
    func test_nextSince_doesNotAdvance_whenEmptyResponseWithoutServerTimestamp() async throws {
        insertPodcast()
        let client = SinceTokenMockSyncClient(
            actions: [],
            serverTimestamp: nil
        )
        let service = makeService(client: client)
        service.loadActionMap()

        let originalSince = 1_000_000
        UserDefaults.standard.set(originalSince, forKey: "lastEpisodeActionSync_\(testProfileId)")
        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)

        let savedSince = UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(testProfileId)")
        XCTAssertEqual(savedSince, originalSince,
                       "Empty response without server timestamp must keep since unchanged")
    }

    // MARK: - 2.3 Echo guard

    /// Pull echo (same position) must not create a conflict.
    func test_pullEcho_samePosition_createsNoConflict() async throws {
        insertPodcast()
        let client = SinceTokenMockSyncClient(
            actions: [makeAction(guid: "ep-1", position: 500, timestamp: 2000)],
            serverTimestamp: 3000
        )
        let service = makeService(client: client)
        service.loadActionMap()

        // Pre-seed actionMap with same position
        let localAction = makeAction(guid: "ep-1", position: 500, timestamp: 1000)
        service.replaceActionMap(["ep-1": localAction])

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)
        XCTAssertTrue(conflicts.isEmpty,
                      "Echo (same position) must never generate a conflict")
    }

    /// Pull echo must adopt the newer server timestamp.
    func test_pullEcho_adoptsNewerServerTimestamp() async throws {
        insertPodcast()
        let client = SinceTokenMockSyncClient(
            actions: [makeAction(guid: "ep-1", position: 500, timestamp: 2000)],
            serverTimestamp: 3000
        )
        let service = makeService(client: client)
        service.loadActionMap()

        // Pre-seed with same position but older timestamp
        let localAction = makeAction(guid: "ep-1", position: 500, timestamp: 1000)
        service.replaceActionMap(["ep-1": localAction])

        _ = try await service.syncEpisodeActions(force: true, strategy: .serverWins)

        XCTAssertEqual(service.actionMap["ep-1"]?.timestamp, 2000,
                       "Echo must adopt the newer server timestamp")
    }

    /// preservingDevice should copy device from existing when incoming is nil.
    func test_preservingDevice_copiesDeviceFromExisting() {
        let incoming = EpisodeAction(
            podcast: "https://ex.com/pod", episode: "https://ex.com/ep.mp3",
            guid: "ep-1", action: "play",
            timestamp: 2000, position: 500, started: 0, total: 3600, device: nil
        )
        let existing = EpisodeAction(
            podcast: "https://ex.com/pod", episode: "https://ex.com/ep.mp3",
            guid: "ep-1", action: "play",
            timestamp: 1000, position: 500, started: 0, total: 3600, device: "my-device"
        )
        let result = incoming.preservingDevice(from: existing)
        XCTAssertEqual(result.device, "my-device",
                       "preservingDevice must copy device from existing when incoming.device is nil")
        XCTAssertEqual(result.timestamp, 2000,
                       "preservingDevice must keep the incoming timestamp")
    }

    // MARK: - Helpers

    private func makeAction(guid: String, position: Int, timestamp: Int = 0) -> EpisodeAction {
        EpisodeAction(
            podcast: "https://example.com/pod1",
            episode: "https://example.com/ep-\(guid).mp3",
            guid: guid,
            action: "play",
            timestamp: timestamp == 0 ? Int(Date().timeIntervalSince1970) : timestamp,
            position: position,
            started: 0,
            total: 3600,
            device: testDeviceId
        )
    }
}

// MARK: - Mock SyncClient with server timestamp support

actor SinceTokenMockSyncClient: SyncClient {
    let actions: [EpisodeAction]
    let serverTimestamp: Int?

    init(actions: [EpisodeAction], serverTimestamp: Int?) {
        self.actions = actions
        self.serverTimestamp = serverTimestamp
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { actions }

    func getEpisodeActionsPage(since: Int) async throws -> EpisodeActionsPage {
        EpisodeActionsPage(actions: actions, serverTimestamp: serverTimestamp)
    }

    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

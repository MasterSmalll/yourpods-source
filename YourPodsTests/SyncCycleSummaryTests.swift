import XCTest
import SwiftData
@testable import YourPods

/// Tests for sync observability:
/// - SyncThresholds named constants
/// - SyncCycleSummary tracking
/// - actionMap `.bak` file recovery
@MainActor
final class SyncCycleSummaryTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-observability"
    private let testDeviceId = "test-device-obs"

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
        cleanupTestFiles()
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

    private func cleanupTestFiles() {
        let fm = FileManager.default
        let bakURL = EpisodeActionSyncService.actionMapFileURL(forProfile: testProfileId)
            .appendingPathExtension("bak")
        try? fm.removeItem(at: EpisodeActionSyncService.actionMapFileURL(forProfile: testProfileId))
        try? fm.removeItem(at: bakURL)
    }

    // MARK: - Helpers

    private func makeService() -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { nil },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId }
        )
    }

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast") -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        let ep = Episode(
            guid: "ep-1-\(url.hashValue)",
            title: "Episode 1",
            audioUrl: "https://example.com/ep1-\(url.hashValue).mp3",
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

    // MARK: - 0.1 SyncThresholds named constants

    /// SyncThresholds enum must exist with the 4 named constants.
    func test_syncThresholds_hasExpectedConstants() {
        XCTAssertEqual(SyncThresholds.pullConflictGapSeconds, 5)
        XCTAssertEqual(SyncThresholds.applyConflictGapSeconds, 5)
        XCTAssertEqual(SyncThresholds.reconcilePositionGapSeconds, 10)
        XCTAssertEqual(SyncThresholds.liveForwardSeekGapSeconds, 5)
    }

    // MARK: - 0.2 SyncCycleSummary

    /// SyncCycleSummary struct must exist and be constructable with defaults.
    func test_syncCycleSummary_defaultValues() {
        let summary = SyncCycleSummary()
        XCTAssertEqual(summary.pushedCount, 0)
        XCTAssertEqual(summary.pulledCount, 0)
        XCTAssertEqual(summary.appliedCount, 0)
        XCTAssertEqual(summary.conflictCount, 0)
        XCTAssertEqual(summary.sinceOld, 0)
        XCTAssertEqual(summary.sinceNew, 0)
        XCTAssertEqual(summary.profileId, "")
    }

    /// After syncEpisodeActions, lastSyncSummary must be populated with counts.
    func test_syncEpisodeActions_recordsPulledAndAppliedCounts() async throws {
        insertPodcast(url: "https://example.com/summary-test")

        let mockClient = ObservabilityMockSyncClient()
        let action = EpisodeAction(
            podcast: "https://example.com/summary-test",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1-test",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 300,
            started: 0,
            total: 3600,
            device: "other-device"
        )
        await mockClient.setActions([action])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId }
        )
        service.loadActionMap()

        _ = try await service.syncEpisodeActions(force: true, strategy: .serverWins)

        let summary = service.lastSyncSummary
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.pulledCount, 1)
        XCTAssertEqual(summary?.conflictCount, 0)
    }

    /// Since transition must be recorded in the summary.
    func test_syncEpisodeActions_recordsSinceTransition() async throws {
        insertPodcast(url: "https://example.com/since-test")

        // Set a prior since value
        UserDefaults.standard.set(1000, forKey: "lastEpisodeActionSync_\(testProfileId)")

        let mockClient = ObservabilityMockSyncClient()
        // Provide a server timestamp so since advances (spec-compliant behavior)
        await mockClient.setServerTimestamp(2000)

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.testDeviceId }
        )
        service.loadActionMap()

        _ = try await service.syncEpisodeActions(force: false, strategy: .serverWins)

        let summary = service.lastSyncSummary
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.sinceOld, 1000)
        XCTAssertEqual(summary?.sinceNew, 2000,
                       "sinceNew must match the server-provided timestamp")
    }

    // MARK: - 0.3 actionMap .bak recovery

    /// persistActionMap must create a .bak copy of the previous file.
    func test_persistActionMap_preservesPreviousFileAsBak() {
        let service = makeService()

        // Write initial actionMap — replaceActionMap calls persistActionMap internally
        let action1 = EpisodeAction(
            podcast: "https://example.com/pod1",
            episode: "https://example.com/ep1.mp3",
            guid: "guid-1",
            action: "play",
            timestamp: 1000,
            position: 100,
            started: 0,
            total: 3600,
            device: testDeviceId
        )
        service.replaceActionMap(["guid-1": action1])

        // Write updated actionMap — should create .bak from the first version
        let action2 = EpisodeAction(
            podcast: "https://example.com/pod1",
            episode: "https://example.com/ep1.mp3",
            guid: "guid-1",
            action: "play",
            timestamp: 2000,
            position: 500,
            started: 0,
            total: 3600,
            device: testDeviceId
        )
        service.replaceActionMap(["guid-1": action2])

        // .bak file must exist and contain the PREVIOUS state (position=100)
        let bakURL = EpisodeActionSyncService.actionMapFileURL(forProfile: testProfileId).appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakURL.path),
                      ".bak file must exist after second persist")

        if let bakData = try? Data(contentsOf: bakURL),
           let bakMap = try? JSONDecoder().decode([String: EpisodeAction].self, from: bakData) {
            XCTAssertEqual(bakMap["guid-1"]?.position, 100,
                           ".bak must contain the previous state")
        } else {
            XCTFail(".bak file must be decodable")
        }
    }

    /// loadActionMap must recover from .bak when primary file is corrupt.
    func test_loadActionMap_recoversFromBak_whenPrimaryCorrupt() {
        let service = makeService()
        let fileURL = EpisodeActionSyncService.actionMapFileURL(forProfile: testProfileId)
        let bakURL = fileURL.appendingPathExtension("bak")

        // Create a valid .bak file with a known action
        let action = EpisodeAction(
            podcast: "https://example.com/pod1",
            episode: "https://example.com/ep1.mp3",
            guid: "bak-guid",
            action: "play",
            timestamp: 1000,
            position: 300,
            started: 0,
            total: 3600,
            device: testDeviceId
        )
        let bakMap: [String: EpisodeAction] = ["bak-guid": action]
        let bakData = try! JSONEncoder().encode(bakMap)

        let fm = FileManager.default
        try! fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try! bakData.write(to: bakURL)

        // Write corrupt data to primary file
        try! "NOT_VALID_JSON{{{".data(using: .utf8)!.write(to: fileURL)

        // loadActionMap should recover from .bak
        service.loadActionMap()

        XCTAssertEqual(service.actionMap["bak-guid"]?.position, 300,
                       "Must recover actionMap from .bak when primary is corrupt")
    }

    /// loadActionMap must start empty when both primary and .bak are corrupt.
    func test_loadActionMap_startsEmpty_whenPrimaryAndBakCorrupt() {
        let service = makeService()
        let fileURL = EpisodeActionSyncService.actionMapFileURL(forProfile: testProfileId)
        let bakURL = fileURL.appendingPathExtension("bak")

        let fm = FileManager.default
        try! fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        // Both files are corrupt
        try! "NOT_VALID_JSON{{{".data(using: .utf8)!.write(to: fileURL)
        try! "ALSO_NOT_VALID}}}".data(using: .utf8)!.write(to: bakURL)

        service.loadActionMap()

        XCTAssertTrue(service.actionMap.isEmpty,
                      "Must start with empty actionMap when both primary and .bak are corrupt")
    }
}

// MARK: - Mock SyncClient

actor ObservabilityMockSyncClient: SyncClient {
    private var actions: [EpisodeAction] = []
    private var _serverTimestamp: Int? = nil

    func setActions(_ actions: [EpisodeAction]) { self.actions = actions }
    func setServerTimestamp(_ ts: Int?) { self._serverTimestamp = ts }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { actions }
    func getEpisodeActionsPage(since: Int) async throws -> EpisodeActionsPage {
        EpisodeActionsPage(actions: actions, serverTimestamp: _serverTimestamp)
    }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for same-device conflict suppression.
///
/// Bug: After a crash during DriftOff background playback, the app shows a
/// false sync conflict (8+ minute gap) even though only ONE device is active.
///
/// Root cause: iOS RunLoop throttling in the background causes the SwiftData
/// disk save (60s throttle) to lag far behind the actionMap (UserDefaults,
/// updated on every syncProgress). After a crash, applyActionsForPodcast()
/// compares the stale SwiftData position with the actionMap position and
/// detects a "conflict" that both originated from this device.
///
/// Fix: When `action.device == deviceId`, the gap is a persistence artifact —
/// silently adopt max(local, server) instead of generating a conflict.
@MainActor
final class SameDeviceConflictSuppressionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-same-device"
    private let thisDeviceId = "my-iphone-15"

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
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast", episodeCount: Int = 1) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i)-\(url.hashValue).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    private func makeService(deviceId: String? = nil) -> EpisodeActionSyncService {
        let devId = deviceId ?? thisDeviceId
        return EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { nil },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { devId }
        )
    }

    private func buildAction(
        for episode: Episode,
        podcast: Podcast,
        position: Int,
        device: String?,
        timestamp: Int? = nil
    ) -> EpisodeAction {
        EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: timestamp ?? Int(Date().timeIntervalSince1970),
            position: position,
            started: 0,
            total: episode.durationSeconds ?? 3600,
            device: device
        )
    }

    // MARK: - Test 1: Same device → suppress conflict, adopt max

    /// When the actionMap entry was written by THIS device (action.device == deviceId),
    /// applyActionsForPodcast must NOT generate a conflict. Instead, it should
    /// silently adopt max(localPosition, serverPosition).
    ///
    /// Scenario: DriftOff crash — SwiftData has 200s (stale), actionMap has 680s
    /// (from this device's syncProgress), delta = 480s > 10s threshold.
    func test_applyActions_sameDevice_silentlyAdoptsMax() {
        let podcast = insertPodcast(url: "https://example.com/same-device")
        let episode = podcast.episodes.first!

        // Simulate stale SwiftData position (last disk save before crash)
        episode.listenedSeconds = 200
        try! context.save()

        // ActionMap has much newer position from THIS device's syncProgress
        let action = buildAction(for: episode, podcast: podcast, position: 680, device: thisDeviceId)
        seedActionMap([episode.guid: action])

        // Create service with the SAME device ID as the action
        let service = makeService(deviceId: thisDeviceId)
        service.loadActionMap()

        let conflicts = service.applyEpisodeActions(strategy: .ask)

        // MUST NOT generate a conflict — both positions are from this device
        XCTAssertTrue(conflicts.isEmpty,
                      "Same-device position gap must NOT generate a conflict (got \(conflicts.count))")

        // MUST adopt the higher position (the more recent one)
        XCTAssertEqual(episode.listenedSeconds, 680,
                       "Same-device: must adopt max(200, 680) = 680")
    }

    // MARK: - Test 2: Different device → DOES generate conflict (preserve existing behavior)

    /// When the actionMap entry was written by a DIFFERENT device,
    /// the conflict must still be generated (real cross-device conflict).
    func test_applyActions_differentDevice_generatesConflict() {
        let podcast = insertPodcast(url: "https://example.com/diff-device")
        let episode = podcast.episodes.first!

        episode.listenedSeconds = 200
        try! context.save()

        // ActionMap has position from a DIFFERENT device
        let action = buildAction(for: episode, podcast: podcast, position: 680, device: "other-ipad")
        seedActionMap([episode.guid: action])

        // Service is running on thisDeviceId — different from action's device
        let service = makeService(deviceId: thisDeviceId)
        service.loadActionMap()

        let conflicts = service.applyEpisodeActions(strategy: .ask)

        // MUST generate a conflict — positions are from different devices
        XCTAssertEqual(conflicts.count, 1,
                       "Cross-device position gap MUST generate a conflict")

        if let conflict = conflicts.first {
            XCTAssertEqual(conflict.localPosition, 200)
            XCTAssertEqual(conflict.serverPosition, 680)
        }

        // Episode position must NOT be changed (unresolved)
        XCTAssertEqual(episode.listenedSeconds, 200,
                       "Unresolved conflict: position must stay at local value")
    }

    // MARK: - Test 3: nil device → DOES generate conflict (gPodder compat)

    /// When the action has device=nil (e.g., gPodder server that doesn't echo device),
    /// the conflict must still be generated — we can't prove it's from this device.
    func test_applyActions_nilDevice_generatesConflict() {
        let podcast = insertPodcast(url: "https://example.com/nil-device")
        let episode = podcast.episodes.first!

        episode.listenedSeconds = 200
        try! context.save()

        // ActionMap entry has NO device field (nil)
        let action = buildAction(for: episode, podcast: podcast, position: 680, device: nil)
        seedActionMap([episode.guid: action])

        let service = makeService(deviceId: thisDeviceId)
        service.loadActionMap()

        let conflicts = service.applyEpisodeActions(strategy: .ask)

        // MUST generate a conflict — nil device can't be proven same-device
        XCTAssertEqual(conflicts.count, 1,
                       "nil device MUST generate a conflict (gPodder compat)")
    }

    // MARK: - Test 4: syncEpisodeActions path — same device actionMap entry, no conflict

    /// When syncEpisodeActions pulls a server action that matches an existing
    /// actionMap entry, and both are from this device, no conflict should be generated.
    func test_syncActions_sameDevice_existingAction_noConflict() async throws {
        let podcast = insertPodcast(url: "https://example.com/sync-same")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 200
        try! context.save()

        // Seed actionMap with position from THIS device (e.g., sent during syncProgress)
        let existingAction = buildAction(
            for: episode, podcast: podcast, position: 680,
            device: thisDeviceId, timestamp: 1000
        )
        seedActionMap([episode.guid: existingAction])

        // Server returns an older action from this same device at position 200
        // (e.g., the forceSyncProgress position from background transition)
        let mockClient = SameDeviceMockSyncClient()
        let serverAction = buildAction(
            for: episode, podcast: podcast, position: 200,
            device: thisDeviceId, timestamp: 500
        )
        await mockClient.setActions([serverAction])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.thisDeviceId }
        )
        service.loadActionMap()

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // MUST NOT generate any conflicts — both positions from this device
        XCTAssertTrue(conflicts.isEmpty,
                      "Same-device actionMap vs server pull must NOT conflict (got \(conflicts.count))")
    }

    // MARK: - Test 5: syncEpisodeActions path — different device DOES conflict

    /// When the existing actionMap entry is from this device but the server
    /// returns an action from a DIFFERENT device, a conflict MUST be generated.
    func test_syncActions_differentDevice_existingAction_generatesConflict() async throws {
        let podcast = insertPodcast(url: "https://example.com/sync-diff")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 680
        try! context.save()

        // Seed actionMap with position from THIS device
        let existingAction = buildAction(
            for: episode, podcast: podcast, position: 680,
            device: thisDeviceId, timestamp: 1000
        )
        seedActionMap([episode.guid: existingAction])

        // Server returns an action from a DIFFERENT device at a different position
        let mockClient = SameDeviceMockSyncClient()
        let serverAction = buildAction(
            for: episode, podcast: podcast, position: 200,
            device: "other-ipad", timestamp: 2000
        )
        await mockClient.setActions([serverAction])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { self.thisDeviceId }
        )
        service.loadActionMap()

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // MUST generate a conflict — the server action is from a different device
        XCTAssertFalse(conflicts.isEmpty,
                       "Cross-device actionMap vs server pull MUST generate a conflict")
    }
}

// MARK: - Mock SyncClient

actor SameDeviceMockSyncClient: SyncClient {
    private var actions: [EpisodeAction] = []

    func setActions(_ actions: [EpisodeAction]) { self.actions = actions }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { actions }
    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

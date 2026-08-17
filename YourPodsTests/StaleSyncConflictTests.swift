import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the stale actionMap sync conflict bug.
///
/// Bug: After listening on the web and opening the iOS app, the first sync
/// shows a conflict (correct). Dismissing the conflict and re-syncing shows
/// a SECOND conflict with swapped Device/Server labels — "Device" shows the
/// web position and "Server" shows the old device position.
///
/// Root cause: `syncEpisodeActions` processes ALL historical actions on full
/// pull (since=0). After the first sync updates the actionMap with the newest
/// server position, a re-sync encounters the old device action from history
/// and creates a conflict where localPosition (from actionMap) is actually the
/// web-originated position and serverPosition is the old device position.
@MainActor
final class StaleSyncConflictTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-stale-conflict"

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
        // Also clean the file-based action map (now profile-scoped)
        try? FileManager.default.removeItem(at: EpisodeActionSyncService.actionMapFileURL(forProfile: testProfileId))
        try? FileManager.default.removeItem(at: EpisodeActionSyncService.actionMapFileURL)
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPodcast(url: String, title: String = "Test Podcast") -> (Podcast, Episode) {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        let ep = Episode(
            guid: "ep-stale-\(url.hashValue)",
            title: "Test Episode",
            audioUrl: "https://example.com/ep-stale-\(url.hashValue).mp3",
            pubDate: Date(),
            durationSeconds: 3600,
            podcast: podcast
        )
        context.insert(ep)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return (podcast, ep)
    }

    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    // MARK: - Test 1: Stale action from full pull must NOT produce conflict

    /// When the actionMap already has a newer position (from a previous sync),
    /// a re-sync that returns an older action from history must NOT create a
    /// conflict. The older action is stale — the actionMap already reflects
    /// the authoritative state.
    func test_resync_doesNotProduceConflictFromStaleAction() async throws {
        let (podcast, episode) = insertPodcast(url: "https://example.com/stale-1")
        episode.listenedSeconds = 300
        try! context.save()

        // ActionMap already has the NEWER position (900) from a previous sync
        // (e.g., the web player updated it to 900, and the first sync stored it)
        let newerAction = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: 2000,
            position: 900,
            started: 0,
            total: 3600,
            device: "web-player"
        )
        seedActionMap([episode.guid: newerAction])

        // The mock client returns the OLD device action (position=300, T1=1000)
        // which is older than the actionMap entry (T2=2000).
        // This simulates a full pull (since=0) returning historical actions.
        let mockClient = StaleSyncMockClient()
        await mockClient.setActions([
            EpisodeAction(
                podcast: podcast.url,
                episode: episode.audioUrl ?? "",
                guid: episode.guid,
                action: "play",
                timestamp: 1000, // OLDER than actionMap's 2000
                position: 300,
                started: 0,
                total: 3600,
                device: "ios-device"
            )
        ])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "ios-device" }
        )
        // Load the actionMap we seeded (has the newer position)
        service.loadActionMap()

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // THEN: The sync-loop must NOT produce a swapped conflict from the stale
        // action. The apply path may still produce a legitimate conflict
        // (device=300 vs actionMap=900), but there must be no conflict where
        // serverPosition=300 (the stale action's position used as "Server").
        let swappedConflict = conflicts.first {
            $0.episodeGuid == episode.guid &&
            $0.serverPosition == 300  // Stale action position wrongly shown as "Server"
        }
        XCTAssertNil(swappedConflict,
                     "Stale action (timestamp 1000 < 2000) must NOT appear as serverPosition. " +
                     "Got conflicts: \(conflicts.map { "local=\($0.localPosition) server=\($0.serverPosition)" })")
        
        // Any conflict that DOES exist must have the correct orientation:
        // localPosition = device (300), serverPosition = server (900)
        if let conflict = conflicts.first(where: { $0.episodeGuid == episode.guid }) {
            XCTAssertEqual(conflict.localPosition, 300,
                           "Conflict localPosition must be the device's episode.listenedSeconds (300)")
            XCTAssertEqual(conflict.serverPosition, 900,
                           "Conflict serverPosition must be the newer action's position (900)")
        }
    }

    // MARK: - Test 2: Dismiss + resync must not produce swapped-label conflict

    /// Full flow: first sync produces a conflict, user dismisses it, re-sync
    /// must NOT produce a duplicate conflict with swapped labels.
    func test_resync_afterDismissal_noSwappedLabels() async throws {
        let (podcast, episode) = insertPodcast(url: "https://example.com/stale-2")
        episode.listenedSeconds = 300  // Device was at 300
        try! context.save()

        // ActionMap has the device's own position (300) from when the app last backgrounded
        let deviceAction = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: 1000,
            position: 300,
            started: 0,
            total: 3600,
            device: "ios-device"
        )
        seedActionMap([episode.guid: deviceAction])

        // Server has BOTH actions: old device (300, T1=1000) and new web (900, T2=2000)
        let mockClient = StaleSyncMockClient()
        let oldDeviceAction = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: 1000,
            position: 300,
            started: 0,
            total: 3600,
            device: "ios-device"
        )
        let newWebAction = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: 2000,
            position: 900,
            started: 0,
            total: 3600,
            device: "web-player"
        )
        await mockClient.setActions([oldDeviceAction, newWebAction])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "ios-device" }
        )
        service.loadActionMap()

        // --- First sync ---
        let firstConflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // First sync should produce exactly 1 conflict: device=300, server=900
        let firstConflict = firstConflicts.first { $0.episodeGuid == episode.guid }
        XCTAssertNotNil(firstConflict, "First sync should produce a conflict for this episode")

        // Simulate user dismissing the conflict sheet (no resolution applied)
        // episode.listenedSeconds stays at 300, actionMap now has 900 (from web)

        // --- Re-sync (same full pull) ---
        let secondConflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // THEN: Re-sync must NOT produce a conflict with swapped labels.
        // The old device action (300, T1=1000) is stale relative to the
        // actionMap (900, T2=2000) — it should be skipped entirely.
        let swappedConflict = secondConflicts.first {
            $0.episodeGuid == episode.guid &&
            $0.serverPosition == 300  // "Server" showing the OLD device position = swapped
        }
        XCTAssertNil(swappedConflict,
                     "Re-sync must NOT produce a conflict with swapped labels (Server=300). " +
                     "Got: \(secondConflicts.map { "local=\($0.localPosition) server=\($0.serverPosition)" })")
    }

    // MARK: - Test 3: Conflict localPosition must use episode model, not actionMap

    /// When the actionMap contains a server-originated position (from a previous sync)
    /// but episode.listenedSeconds has the actual device position, the conflict's
    /// localPosition must use the episode model value — not the actionMap value.
    func test_conflictLocalPosition_usesEpisodeModel_notActionMap() async throws {
        let (podcast, episode) = insertPodcast(url: "https://example.com/stale-3")

        // The actual device position is 500 (what the user last listened to on-device)
        episode.listenedSeconds = 500
        try! context.save()

        // ActionMap has a STALE value (200) from a previous sync cycle.
        // This does NOT represent the current device position.
        let staleAction = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: 1000,
            position: 200,
            started: 0,
            total: 3600,
            device: "web-player"
        )
        seedActionMap([episode.guid: staleAction])

        // Server sends a NEW action at position 900 (very different from both)
        let mockClient = StaleSyncMockClient()
        await mockClient.setActions([
            EpisodeAction(
                podcast: podcast.url,
                episode: episode.audioUrl ?? "",
                guid: episode.guid,
                action: "play",
                timestamp: 2000, // Newer than actionMap's 1000
                position: 900,
                started: 0,
                total: 3600,
                device: "web-player"
            )
        ])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "ios-device" }
        )
        service.loadActionMap()

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // Find the conflict for our episode
        let conflict = conflicts.first { $0.episodeGuid == episode.guid }
        XCTAssertNotNil(conflict, "Should produce a conflict for |500 - 900| > 5")

        if let conflict {
            // THEN: localPosition must be the Episode model value (500),
            // NOT the stale actionMap value (200). The user expects "Device"
            // to show what they actually heard on this device.
            XCTAssertEqual(conflict.localPosition, 500,
                           "Conflict localPosition must be episode.listenedSeconds (500), " +
                           "not stale actionMap value (200). Got: \(conflict.localPosition)")
            XCTAssertEqual(conflict.serverPosition, 900,
                           "Conflict serverPosition must be the new server action's position (900). Got: \(conflict.serverPosition)")
        }
    }
}

// MARK: - Mock SyncClient for stale conflict tests

actor StaleSyncMockClient: SyncClient {
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

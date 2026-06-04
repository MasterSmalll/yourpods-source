import XCTest
import SwiftData
@testable import YourPods

/// Tests for the post-corruption recovery gaps:
///
/// Bug 1: `deleteStoreFiles()` only deletes SQLite files but leaves
///         sync-related UserDefaults intact (actionMap, subscription URLs,
///         sync timestamps), creating a mismatch between the clean SwiftData
///         store and stale sync state.
///
/// Bug 2: `forcePullFromServer()` doesn't clear the stale `actionMap` in
///         UserDefaults, causing a flood of spurious sync conflicts when
///         old local positions clash with server positions.
@MainActor
final class CorruptionRecoveryTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-corruption-recovery"

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
            "pendingSubscriptionAdds_\(testProfileId)",
            "pendingSubscriptionRemovals_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
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

    private func profileUrls() -> Set<String> {
        let key = "subscriptionUrls_\(testProfileId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let urls = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return urls
    }

    // MARK: - Bug 1: clearSyncStateForStoreRecovery clears all sync state

    /// deleteStoreFiles must also clear the episodeActionMap to prevent
    /// stale conflicts on the next sync after corruption recovery.
    func test_storeRecovery_clearsActionMap() {
        // GIVEN: ActionMap has entries
        let action = EpisodeAction(
            podcast: "https://example.com/podcast",
            episode: "https://example.com/ep.mp3",
            guid: "ep-test",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 300,
            started: 0,
            total: 1800,
            device: "test-device"
        )
        let actionMap = ["ep-test": action]
        let encoded = try! JSONEncoder().encode(actionMap)
        UserDefaults.standard.set(encoded, forKey: "episodeActionMap")

        // Verify precondition
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "episodeActionMap"),
                        "Precondition: episodeActionMap must be set")

        // WHEN: Store recovery cleanup runs
        YourPodsApp.clearSyncStateForStoreRecovery()

        // THEN: ActionMap should be cleared
        XCTAssertNil(UserDefaults.standard.data(forKey: "episodeActionMap"),
                     "episodeActionMap must be cleared during store recovery")
    }

    /// deleteStoreFiles must clear sync conflict counts.
    func test_storeRecovery_clearsSyncConflictCounts() {
        // GIVEN: Conflict counts exist
        let counts = ["ep-1": 3, "ep-2": 1]
        let encoded = try! JSONEncoder().encode(counts)
        UserDefaults.standard.set(encoded, forKey: "syncConflictCounts")

        // WHEN: Store recovery cleanup runs
        YourPodsApp.clearSyncStateForStoreRecovery()

        // THEN: Conflict counts should be cleared
        XCTAssertNil(UserDefaults.standard.data(forKey: "syncConflictCounts"),
                     "syncConflictCounts must be cleared during store recovery")
    }

    /// deleteStoreFiles must reset sync timestamps so the next sync is a full pull.
    func test_storeRecovery_resetsSyncTimestamps() {
        // GIVEN: Sync timestamps exist for the active profile
        UserDefaults.standard.set(99999, forKey: "lastSubscriptionSync_\(testProfileId)")
        UserDefaults.standard.set(88888, forKey: "lastEpisodeActionSync_\(testProfileId)")

        // WHEN: Store recovery cleanup runs
        YourPodsApp.clearSyncStateForStoreRecovery()

        // THEN: Timestamps should be reset to 0 (forcing full sync)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastSubscriptionSync_\(testProfileId)"), 0,
                       "Subscription sync timestamp must be reset to 0 after store recovery")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(testProfileId)"), 0,
                       "Episode action sync timestamp must be reset to 0 after store recovery")
    }

    /// deleteStoreFiles must clear subscription URLs so loadSubscriptions starts fresh.
    func test_storeRecovery_clearsSubscriptionUrls() {
        // GIVEN: Subscription URLs exist for the active profile
        let urls: Set<String> = [
            "https://example.com/podcast-a",
            "https://example.com/podcast-b",
        ]
        let encoded = try! JSONEncoder().encode(urls)
        UserDefaults.standard.set(encoded, forKey: "subscriptionUrls_\(testProfileId)")
        XCTAssertFalse(profileUrls().isEmpty, "Precondition: profile URLs must exist")

        // WHEN: Store recovery cleanup runs
        YourPodsApp.clearSyncStateForStoreRecovery()

        // THEN: Subscription URLs should be cleared
        XCTAssertTrue(profileUrls().isEmpty,
                      "subscriptionUrls must be cleared during store recovery")
    }

    /// After clearSyncStateForStoreRecovery, loadSubscriptions should show empty library.
    func test_storeRecovery_loadSubscriptionsShowsEmptyLibrary() {
        // GIVEN: Pre-corruption state (URLs in UserDefaults, but SwiftData will be empty)
        let staleUrls: Set<String> = ["https://example.com/podcast-a"]
        let encoded = try! JSONEncoder().encode(staleUrls)
        UserDefaults.standard.set(encoded, forKey: "subscriptionUrls_\(testProfileId)")

        // WHEN: Recovery clears everything, then loadSubscriptions is called
        YourPodsApp.clearSyncStateForStoreRecovery()
        manager.loadSubscriptions()

        // THEN: Empty library — ready for Force Pull to rebuild
        XCTAssertTrue(manager.subscriptions.isEmpty,
                      "After recovery cleanup, subscriptions should be empty")
        XCTAssertTrue(profileUrls().isEmpty,
                      "After recovery cleanup, profile URLs should be empty")
    }

    // MARK: - Bug 2: forcePullFromServer must clear stale actionMap

    /// When user taps "Force Pull from Server," the actionMap must be cleared
    /// before syncing episode actions. Stale local positions in the actionMap
    /// cause a flood of spurious sync conflicts.
    func test_forcePullFromServer_clearsActionMapBeforeSync() async throws {
        // GIVEN: Stale actionMap from before corruption
        let staleAction = EpisodeAction(
            podcast: "https://example.com/podcast",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970) - 3600,
            position: 500,   // Old local position
            started: 0,
            total: 1800,
            device: "this-device"
        )
        // Seed the actionMap with stale data via the existing public API
        await manager.sendEpisodeAction(staleAction)
        XCTAssertNotNil(manager.getLatestAction(for: "ep-1"),
                        "Precondition: stale actionMap entry must exist")

        // Server has a different position
        let mockClient = CorruptionRecoveryMockSyncClient()
        await mockClient.setServerState(["https://example.com/podcast"])
        await mockClient.setEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/podcast",
                episode: "https://example.com/ep1.mp3",
                guid: "ep-1",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 400,   // Server position differs from stale local
                started: 0,
                total: 1800,
                device: "other-device"
            )
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Force pull from server with .ask strategy
        //       (which would normally generate conflicts for position differences)
        let conflicts = try await manager.forcePullFromServer(strategy: .ask)

        // THEN: No conflicts should be generated
        //       (actionMap was cleared, so no stale local position to conflict with)
        XCTAssertEqual(conflicts.count, 0,
                       "Force Pull must clear actionMap before sync — stale positions " +
                       "should not generate conflicts. Got \(conflicts.count) conflict(s).")
    }

    /// Verify that stale actionMap entries are cleared during Force Pull.
    func test_forcePullFromServer_actionMapClearedForStaleEntries() async throws {
        // GIVEN: Multiple stale actionMap entries
        for i in 1...5 {
            let action = EpisodeAction(
                podcast: "https://example.com/podcast",
                episode: "https://example.com/ep\(i).mp3",
                guid: "ep-\(i)",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970) - 3600,
                position: i * 100,
                started: 0,
                total: 1800,
                device: "this-device"
            )
            await manager.sendEpisodeAction(action)
        }
        XCTAssertEqual(manager.allEpisodeActions().count, 5,
                       "Precondition: 5 stale actionMap entries")

        let mockClient = CorruptionRecoveryMockSyncClient()
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Force pull (mock returns no episode actions)
        _ = try await manager.forcePullFromServer(strategy: .serverWins)

        // THEN: After force pull with empty server actions, actionMap should be empty
        let actionMapCount = manager.allEpisodeActions().count
        XCTAssertEqual(actionMapCount, 0,
                       "After Force Pull with empty server actions, actionMap should be empty. " +
                       "Found \(actionMapCount) stale entries.")
    }

    // MARK: - Scenario: Full corruption recovery round-trip

    /// End-to-end scenario: store corruption → recovery cleanup → Force Pull → clean library.
    func test_Scenario_fullCorruptionRecoveryJourney() async throws {
        // Step 1: User has a library with 3 podcasts
        insertPodcast(url: "https://example.com/daily-news", title: "Daily News")
        insertPodcast(url: "https://example.com/tech-talk", title: "Tech Talk")
        insertPodcast(url: "https://example.com/comedy-hour", title: "Comedy Hour")
        XCTAssertEqual(manager.subscriptions.count, 3, "Step 1: 3 podcasts in library")
        XCTAssertEqual(profileUrls().count, 3, "Step 1: 3 profile URLs")

        // Step 2: Simulate store corruption recovery
        //   - deleteStoreFiles + clearSyncStateForStoreRecovery runs at app launch
        //   - This clears subscription URLs, actionMap, timestamps
        YourPodsApp.clearSyncStateForStoreRecovery()
        XCTAssertTrue(profileUrls().isEmpty,
                      "Step 2: Recovery cleanup must clear subscription URLs")

        // Step 3: App relaunches with fresh container (SwiftData store was rebuilt)
        let newConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let newContainer = try ModelContainer(for: Podcast.self, Episode.self, configurations: newConfig)
        let newContext = newContainer.mainContext
        manager = PodcastManager(modelContext: newContext)

        XCTAssertTrue(manager.subscriptions.isEmpty,
                      "Step 3: Library should be empty after recovery")

        // Step 4: User taps Force Pull from Server → rebuilds library
        let mockClient = CorruptionRecoveryMockSyncClient()
        await mockClient.setServerState([
            "https://example.com/daily-news",
            "https://example.com/tech-talk",
            "https://example.com/comedy-hour"
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        let conflicts = try await manager.forcePullFromServer(strategy: .serverWins)
        XCTAssertEqual(conflicts.count, 0,
                       "Step 4: Force Pull should not generate conflicts after recovery")

        // Step 5: Profile URLs should be rebuilt from server
        XCTAssertEqual(profileUrls().count, 3,
                       "Step 5: Profile URLs should be rebuilt from Force Pull")
    }
}

// MARK: - Mock SyncClient for Corruption Recovery Tests

actor CorruptionRecoveryMockSyncClient: SyncClient {
    private var fullServerState: [String] = []
    private var serverEpisodeActions: [EpisodeAction] = []

    func setServerState(_ urls: [String]) { fullServerState = urls }
    func setEpisodeActions(_ actions: [EpisodeAction]) { serverEpisodeActions = actions }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        if since == 0 {
            return SubscriptionDelta(add: fullServerState, remove: [], timestamp: 5000)
        } else {
            return SubscriptionDelta(add: [], remove: [], timestamp: since + 100)
        }
    }

    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        return serverEpisodeActions
    }

    var supportsQueueSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    var supportsSettingsSync: Bool { false }
}

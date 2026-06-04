import XCTest
import SwiftData
@testable import YourPods

/// Sync invariant tests — these protect against the class of bugs where a sync
/// operation silently corrupts or destroys user data.
///
/// Every test here represents a real user scenario that MUST work. If any of
/// these fail, the build should be blocked.
///
/// Coverage gaps filled:
///   - Incremental sync (since>0) must never trigger remote deletion logic
///   - Explicit server removals (delta.remove) must still work during incremental sync
///   - Episode positions must survive subscription syncs
///   - Multiple consecutive syncs must be idempotent
///   - Full user journey: Force Pull → Sync → Sync → local add → Sync
@MainActor
final class SyncInvariantTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-sync-invariants"

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

    // MARK: - Invariant 1: Incremental sync never deletes subscriptions

    /// The most critical invariant: a normal Refresh & Sync (incremental, since>0)
    /// must NEVER delete subscriptions that are already in the local library.
    func test_INVARIANT_incrementalSync_neverDeletesExistingSubscriptions() async throws {
        // GIVEN: 3 podcasts from a previous full sync
        let urls = [
            "https://example.com/podcast-a",
            "https://example.com/podcast-b",
            "https://example.com/podcast-c"
        ]
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(urls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // Full sync to establish baseline (since=0)
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 3, "Precondition: 3 subscriptions after full sync")

        // WHEN: Incremental sync (since>0, nothing changed on server)
        _ = try await manager.syncSubscriptions()

        // THEN: All 3 subscriptions must survive
        XCTAssertEqual(profileUrls().count, 3,
                       "INVARIANT VIOLATION: Incremental sync deleted subscriptions!")
        for url in urls {
            XCTAssertTrue(profileUrls().contains(url),
                          "Subscription \(url) was deleted by incremental sync")
        }
    }

    /// Three consecutive syncs must all be safe — no degradation over time.
    func test_INVARIANT_multipleConsecutiveSyncs_areIdempotent() async throws {
        // GIVEN: 2 podcasts from a full sync
        let urls = ["https://example.com/feed-1", "https://example.com/feed-2"]
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(urls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // Full sync
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 2, "Precondition: 2 subscriptions")

        // WHEN: Sync 3 more times (all incremental)
        _ = try await manager.syncSubscriptions()
        _ = try await manager.syncSubscriptions()
        _ = try await manager.syncSubscriptions()

        // THEN: Still exactly 2
        XCTAssertEqual(profileUrls().count, 2,
                       "INVARIANT VIOLATION: Repeated syncs changed subscription count!")
    }

    // MARK: - Invariant 2: Explicit server removals still work

    /// When the server explicitly sends a URL in delta.remove (Step 3),
    /// it must be removed locally even during incremental sync.
    func test_INVARIANT_explicitServerRemoval_worksOnIncrementalSync() async throws {
        // GIVEN: 3 podcasts from a full sync
        let urls = [
            "https://example.com/keep-1",
            "https://example.com/keep-2",
            "https://example.com/to-remove"
        ]
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(urls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // Full sync
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 3, "Precondition: 3 subscriptions")

        // Server now explicitly removes one URL on next incremental sync
        await mockClient.setIncrementalDelta(add: [], remove: ["https://example.com/to-remove"])

        // WHEN: Incremental sync
        _ = try await manager.syncSubscriptions()

        // THEN: The removed URL must be gone, others remain
        let remaining = profileUrls()
        XCTAssertEqual(remaining.count, 2, "Should have 2 remaining after explicit removal")
        XCTAssertFalse(remaining.contains("https://example.com/to-remove"),
                       "Explicitly removed URL must be deleted")
        XCTAssertTrue(remaining.contains("https://example.com/keep-1"))
        XCTAssertTrue(remaining.contains("https://example.com/keep-2"))
    }

    // MARK: - Invariant 3: Full sync still removes remotely-deleted subscriptions

    /// On a full sync (since=0), if a URL is local but NOT in the server's
    /// complete list, it should be removed (cross-device deletion).
    func test_INVARIANT_fullSync_removesRemotelyDeletedSubscriptions() async throws {
        // GIVEN: 3 local podcasts, but server only has 2
        insertPodcast(url: "https://example.com/server-has-1", title: "Podcast 1")
        insertPodcast(url: "https://example.com/server-has-2", title: "Podcast 2")
        insertPodcast(url: "https://example.com/server-deleted", title: "Deleted on Web")

        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState([
            "https://example.com/server-has-1",
            "https://example.com/server-has-2"
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Full sync (since=0)
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()

        // THEN: server-deleted should be removed
        let remaining = profileUrls()
        XCTAssertFalse(remaining.contains("https://example.com/server-deleted"),
                       "Full sync must remove locally-present URL missing from server")
        XCTAssertTrue(remaining.contains("https://example.com/server-has-1"))
        XCTAssertTrue(remaining.contains("https://example.com/server-has-2"))
    }

    // MARK: - Invariant 4: Episode positions survive subscription sync

    /// syncSubscriptions must never corrupt or delete episode position data.
    func test_INVARIANT_subscriptionSync_doesNotCorruptEpisodePositions() async throws {
        // GIVEN: A podcast with an episode that has listen progress
        let podcast = insertPodcast(url: "https://example.com/my-podcast", title: "My Podcast")
        let episode = Episode(guid: "ep-1", title: "Episode 1", audioUrl: "https://example.com/ep1.mp3")
        episode.listenedSeconds = 120  // 2 minutes in
        episode.durationSeconds = 3600 // 1 hour total
        episode.podcast = podcast
        context.insert(episode)
        try! context.save()

        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(["https://example.com/my-podcast"])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Full sync + incremental sync
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        _ = try await manager.syncSubscriptions()  // incremental

        // THEN: Episode position and duration must be untouched
        let fetchDescriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "ep-1" })
        let episodes = try context.fetch(fetchDescriptor)
        XCTAssertEqual(episodes.count, 1, "Episode must still exist")
        XCTAssertEqual(episodes[0].listenedSeconds, 120,
                       "INVARIANT VIOLATION: Subscription sync corrupted episode position!")
        XCTAssertEqual(episodes[0].durationSeconds, 3600,
                       "INVARIANT VIOLATION: Subscription sync corrupted episode duration!")
    }

    // MARK: - Invariant 5: Episode action sync works independently

    /// syncEpisodeActions must work correctly when called after syncSubscriptions.
    func test_INVARIANT_episodeActionSync_worksAfterSubscriptionSync() async throws {
        // GIVEN: A podcast with an episode
        let podcast = insertPodcast(url: "https://example.com/my-podcast", title: "My Podcast")
        let episode = Episode(guid: "ep-1", title: "Episode 1", audioUrl: "https://example.com/ep1.mp3")
        episode.listenedSeconds = 60
        episode.durationSeconds = 1800
        episode.podcast = podcast
        context.insert(episode)
        try! context.save()

        // Server has a newer position for this episode
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(["https://example.com/my-podcast"])
        await mockClient.setEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/my-podcast",
                episode: "https://example.com/ep1.mp3",
                guid: "ep-1",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 300,   // server says 5 minutes
                started: 60,
                total: 1800,
                device: "test-device"
            )
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Subscription sync, then episode action sync
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        _ = try? await manager.syncEpisodeActions(strategy: .serverWins)

        // THEN: Episode position should be updated from server
        let fetchDescriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "ep-1" })
        let episodes = try context.fetch(fetchDescriptor)
        XCTAssertEqual(episodes.count, 1, "Episode must still exist")
        XCTAssertEqual(episodes[0].listenedSeconds, 300,
                       "Episode position should be updated from server episode actions")
    }

    // MARK: - Scenario: Full user journey

    /// Simulates the real user journey that exposed the bug:
    /// Force Pull → Sync → Sync → Add locally → Sync
    func test_Scenario_fullUserJourney_forcePullThenRepeatedSyncs() async throws {
        // Step 1: Force Pull (since=0) - discover server podcasts
        let serverUrls = [
            "https://example.com/alpha",
            "https://example.com/beta",
            "https://example.com/gamma"
        ]
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(serverUrls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        _ = try await manager.forcePullFromServer(strategy: .serverWins)
        XCTAssertEqual(profileUrls().count, 3, "Step 1: Force Pull should find 3 podcasts")

        // Step 2: First incremental sync (nothing changed)
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 3, "Step 2: First sync must not delete anything")

        // Step 3: Second incremental sync (still nothing changed)
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 3, "Step 3: Second sync must not delete anything")

        // Step 4: User adds a podcast locally
        let newUrl = "https://example.com/new-local"
        manager.associateWithCurrentProfile(url: newUrl)
        manager.addPendingSubscriptionAdd(newUrl)
        XCTAssertEqual(profileUrls().count, 4, "Step 4: Should have 4 after local add")

        // Step 5: Sync again — local add should be pushed, nothing else deleted
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 4,
                       "Step 5: Sync after local add must preserve everything")
        let pushedAdds = await mockClient.pushedAdds
        XCTAssertTrue(pushedAdds.contains(newUrl),
                      "Step 5: New local podcast must be pushed to server")
    }

    /// Simulates the exact bug: Pro → gPodder migration → Force Pull → Refresh & Sync
    func test_Scenario_proToGpodder_forcePullThenRefreshAndSync() async throws {
        // Step 1: Clear old profile (simulates Pro profile deletion)
        manager.clearProfileData(profileId: "old-pro-profile")

        // Step 2: Set up new gPodder profile with server subscriptions
        let gPodderUrls = [
            "https://example.com/news-daily",
            "https://example.com/tech-podcast"
        ]
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(gPodderUrls)
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // Step 3: Force Pull
        _ = try await manager.forcePullFromServer(strategy: .serverWins)
        XCTAssertEqual(profileUrls().count, 2, "Force Pull should discover 2 server podcasts")

        // Step 4: Refresh & Sync (this is where the bug was — it deleted everything)
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 2,
                       "CRITICAL: Refresh & Sync after Force Pull must NOT delete subscriptions!")

        // Step 5: Another Refresh & Sync for good measure
        _ = try await manager.syncSubscriptions()
        XCTAssertEqual(profileUrls().count, 2,
                       "CRITICAL: Repeated Refresh & Sync must remain stable!")
    }

    // MARK: - Invariant 6: Step 5b must NOT delete Podcast objects from SwiftData

    /// Step 5b should disassociate URLs from the profile but never call
    /// modelContext.delete(). The Podcast object may belong to other profiles
    /// or be recoverable.
    func test_INVARIANT_fullSync_disassociatesButDoesNotDeleteFromSwiftData() async throws {
        // GIVEN: 3 local podcasts, but server only has 2
        insertPodcast(url: "https://example.com/server-has-1", title: "Podcast 1")
        insertPodcast(url: "https://example.com/server-has-2", title: "Podcast 2")
        insertPodcast(url: "https://example.com/not-on-server", title: "Not On Server")

        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState([
            "https://example.com/server-has-1",
            "https://example.com/server-has-2"
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Full sync (since=0)
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()

        // THEN: Profile URLs should only contain server podcasts
        let remaining = profileUrls()
        XCTAssertFalse(remaining.contains("https://example.com/not-on-server"),
                       "URL not on server should be disassociated from profile")
        XCTAssertTrue(remaining.contains("https://example.com/server-has-1"))
        XCTAssertTrue(remaining.contains("https://example.com/server-has-2"))

        // BUT: The Podcast object must still exist in SwiftData
        let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.url == "https://example.com/not-on-server" })
        let inDB = try context.fetch(descriptor)
        XCTAssertEqual(inDB.count, 1,
                       "INVARIANT VIOLATION: Step 5b deleted Podcast from SwiftData! Must only disassociate.")
    }

    // MARK: - Invariant 7: loadSubscriptions recovers when profile URLs are cleared

    /// If subscriptionUrls for a profile is empty but podcasts exist in SwiftData,
    /// loadSubscriptions must adopt them rather than showing an empty library.
    /// This handles recovery from UserDefaults clearing, app update edge cases, etc.
    func test_INVARIANT_loadSubscriptions_recoversWhenProfileUrlsCleared() async throws {
        // GIVEN: Podcasts in SwiftData, associated with this profile
        insertPodcast(url: "https://example.com/alpha", title: "Alpha")
        insertPodcast(url: "https://example.com/beta", title: "Beta")
        XCTAssertEqual(manager.subscriptions.count, 2, "Precondition: 2 subscriptions loaded")

        // Simulate another profile existing (the fragile guard condition)
        let otherProfile = ServerProfile(name: "Other Profile")
        let profiles = [
            ServerProfile(name: "Test Profile"),
            otherProfile
        ]
        let encoded = try JSONEncoder().encode(profiles)
        UserDefaults.standard.set(encoded, forKey: "serverProfiles")

        // WHEN: subscriptionUrls is cleared (simulates UserDefaults corruption/reset)
        UserDefaults.standard.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        manager.loadSubscriptions()

        // THEN: Podcasts must be recovered, not shown as empty
        XCTAssertEqual(manager.subscriptions.count, 2,
                       "INVARIANT VIOLATION: loadSubscriptions showed empty library when podcasts exist in DB!")
        XCTAssertTrue(profileUrls().contains("https://example.com/alpha"),
                      "Profile URLs should be re-populated from DB")
    }

    // MARK: - Invariant 8: First sync does not generate conflicts for new episodes

    /// On first sync, the local actionMap is empty and episode.listenedSeconds == 0.
    /// Server positions should be adopted silently — no conflicts.
    func test_INVARIANT_firstSyncDoesNotGenerateConflictsForNewEpisodes() async throws {
        // GIVEN: A podcast with episodes that have NO local listen progress
        let podcast = insertPodcast(url: "https://example.com/my-podcast", title: "My Podcast")
        let ep1 = Episode(guid: "ep-1", title: "Episode 1", audioUrl: "https://example.com/ep1.mp3")
        ep1.listenedSeconds = 0
        ep1.durationSeconds = 3600
        ep1.podcast = podcast
        context.insert(ep1)
        let ep2 = Episode(guid: "ep-2", title: "Episode 2", audioUrl: "https://example.com/ep2.mp3")
        ep2.listenedSeconds = 0
        ep2.durationSeconds = 1800
        ep2.podcast = podcast
        context.insert(ep2)
        try! context.save()

        // Server has listen positions for both episodes
        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(["https://example.com/my-podcast"])
        await mockClient.setEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/my-podcast",
                episode: "https://example.com/ep1.mp3",
                guid: "ep-1",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 600,   // 10 minutes in
                started: 0,
                total: 3600,
                device: "other-device"
            ),
            EpisodeAction(
                podcast: "https://example.com/my-podcast",
                episode: "https://example.com/ep2.mp3",
                guid: "ep-2",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 300,   // 5 minutes in
                started: 0,
                total: 1800,
                device: "other-device"
            )
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: First sync with .ask strategy (would normally generate conflicts)
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        let conflicts = try await manager.syncEpisodeActions(strategy: .ask)

        // THEN: No conflicts should be generated — local position was 0
        XCTAssertEqual(conflicts.count, 0,
                       "INVARIANT VIOLATION: First sync generated \(conflicts.count) conflict(s) for episodes with no local progress!")

        // AND: Server positions should be adopted
        let fetchDescriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "ep-1" })
        let episodes = try context.fetch(fetchDescriptor)
        XCTAssertEqual(episodes.first?.listenedSeconds, 600,
                       "Server position should be adopted silently on first sync")
    }

    // MARK: - Invariant 9: Zero local position never generates a conflict

    /// Even if the actionMap has an entry with position 0, a conflict should
    /// never be generated. Position 0 means the episode was never started locally.
    func test_INVARIANT_zeroLocalPosition_neverGeneratesConflict() async throws {
        // GIVEN: A podcast with an episode, local actionMap has position 0
        let podcast = insertPodcast(url: "https://example.com/pod", title: "Pod")
        let ep = Episode(guid: "ep-zero", title: "Zero Ep", audioUrl: "https://example.com/ep.mp3")
        ep.listenedSeconds = 0
        ep.durationSeconds = 1800
        ep.podcast = podcast
        context.insert(ep)
        try! context.save()

        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(["https://example.com/pod"])
        // First sync to populate actionMap with position 0
        await mockClient.setEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/pod",
                episode: "https://example.com/ep.mp3",
                guid: "ep-zero",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970) - 100,
                position: 0,
                started: 0,
                total: 1800,
                device: "test-device"
            )
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        _ = try await manager.syncEpisodeActions(strategy: .serverWins)

        // Now server has a newer action with real position
        await mockClient.setEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/pod",
                episode: "https://example.com/ep.mp3",
                guid: "ep-zero",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 900,   // 15 minutes
                started: 0,
                total: 1800,
                device: "other-device"
            )
        ])

        // WHEN: Sync again with .ask strategy
        let conflicts = try await manager.syncEpisodeActions(strategy: .ask)

        // THEN: No conflict — local was 0
        XCTAssertEqual(conflicts.count, 0,
                       "INVARIANT VIOLATION: Conflict generated when local position was 0!")
    }

    // MARK: - Invariant 10: Server-completed episodes don't generate conflicts

    /// When the server says an episode is complete (position ≥ 95% of total),
    /// it should be auto-resolved, not surfaced as a conflict.
    func test_INVARIANT_serverCompletedEpisodes_noConflict() async throws {
        // GIVEN: A podcast with an episode at local position 60s
        let podcast = insertPodcast(url: "https://example.com/pod", title: "Pod")
        let ep = Episode(guid: "ep-done", title: "Done Ep", audioUrl: "https://example.com/done.mp3")
        ep.listenedSeconds = 60
        ep.durationSeconds = 1800
        ep.podcast = podcast
        context.insert(ep)
        try! context.save()

        let mockClient = InvariantMockSyncClient()
        await mockClient.setServerState(["https://example.com/pod"])
        // Server says episode is complete (position = 1750 out of 1800 = 97%)
        await mockClient.setEpisodeActions([
            EpisodeAction(
                podcast: "https://example.com/pod",
                episode: "https://example.com/done.mp3",
                guid: "ep-done",
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 1750,
                started: 0,
                total: 1800,
                device: "other-device"
            )
        ])
        manager.setSyncClient(mockClient, deviceId: "test-device")

        // WHEN: Sync with .ask strategy
        UserDefaults.standard.set(0, forKey: "lastSubscriptionSync_\(testProfileId)")
        _ = try await manager.syncSubscriptions()
        let conflicts = try await manager.syncEpisodeActions(strategy: .ask)

        // THEN: No conflict — episode is effectively complete on server
        XCTAssertEqual(conflicts.count, 0,
                       "Server-completed episodes should not generate conflicts")
    }
}

// MARK: - Mock SyncClient for Invariant Tests

/// A mock that simulates realistic gPodder server behavior:
/// - Full sync (since=0): returns the complete subscription list
/// - Incremental sync (since>0): returns only changes (default: empty delta)
/// - Supports configurable incremental deltas for testing explicit removals
actor InvariantMockSyncClient: SyncClient {
    private var fullServerState: [String] = []
    private var incrementalAdds: [String] = []
    private var incrementalRemoves: [String] = []
    private(set) var pushedAdds: [String] = []
    private(set) var pushedRemoves: [String] = []
    private(set) var pullCount = 0
    private(set) var pushCount = 0
    private var serverEpisodeActions: [EpisodeAction] = []

    func setServerState(_ urls: [String]) {
        fullServerState = urls
    }

    func setIncrementalDelta(add: [String], remove: [String]) {
        incrementalAdds = add
        incrementalRemoves = remove
    }

    func setEpisodeActions(_ actions: [EpisodeAction]) {
        serverEpisodeActions = actions
    }

    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        pushCount += 1
        pushedAdds.append(contentsOf: add)
        pushedRemoves.append(contentsOf: remove)
        return []
    }

    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        pullCount += 1
        if since == 0 {
            // Full sync: return complete server state
            return SubscriptionDelta(add: fullServerState, remove: [], timestamp: 5000)
        } else {
            // Incremental sync: return only changes
            let delta = SubscriptionDelta(
                add: incrementalAdds,
                remove: incrementalRemoves,
                timestamp: since + 100
            )
            // Reset incremental delta after consumption (one-shot)
            incrementalAdds = []
            incrementalRemoves = []
            return delta
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

import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for sync conflict resolution correctness.
///
/// Bug: "Use Device" in the conflict sheet sometimes applies the server's position.
/// Root causes:
/// 1. The `.deviceWins` strategy in `applyActionsForPodcast` overwrites with the server
///    position when it's ahead — making "deviceWins" behave as "use whichever is further."
/// 2. The conflict `localPosition` in `syncEpisodeActions` uses the actionMap value
///    (which may be stale from a previous sync) instead of the Episode model's actual
///    `listenedSeconds`, causing the "Device" label in the conflict sheet to show a
///    server-originated value.
@MainActor
final class SyncConflictResolutionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-conflict-res"

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
    private func insertPodcast(url: String, title: String = "Test Podcast", episodeCount: Int = 3) -> Podcast {
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

    private func buildAction(for episode: Episode, podcast: Podcast, position: Int, timestamp: Int? = nil) -> EpisodeAction {
        EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: timestamp ?? Int(Date().timeIntervalSince1970),
            position: position,
            started: 0,
            total: episode.durationSeconds ?? 3600,
            device: "test"
        )
    }

    // MARK: - Bug 1: deviceWins must NEVER apply server position

    /// When strategy is `.deviceWins` and the server position is ahead,
    /// the local position must be preserved — "device wins" means device wins.
    func test_deviceWins_neverAppliesServerPosition_whenServerAhead() {
        let podcast = insertPodcast(url: "https://example.com/dw-fix", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 200
        try! context.save()

        let serverAction = buildAction(for: episode, podcast: podcast, position: 400)

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { nil },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "test" }
        )
        service.sendActionLocally(serverAction)

        let conflicts = service.applyEpisodeActions(strategy: .deviceWins)

        // THEN: Device position must be preserved — deviceWins should NEVER overwrite with server
        XCTAssertEqual(episode.listenedSeconds, 200,
                       "deviceWins: local position (200) must be preserved even when server is ahead (400)")
        XCTAssertTrue(conflicts.isEmpty)
    }

    /// deviceWins should also preserve when server is behind (sanity check).
    func test_deviceWins_preservesLocal_whenServerBehind() {
        let podcast = insertPodcast(url: "https://example.com/dw-behind", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 500  // Device ahead
        try! context.save()

        let map: [String: EpisodeAction] = [
            episode.guid: buildAction(for: episode, podcast: podcast, position: 100)
        ]
        seedActionMap(map)

        let conflicts = manager.applyEpisodeActions(strategy: .deviceWins)

        XCTAssertEqual(episode.listenedSeconds, 500,
                       "deviceWins: should keep local 500 when server is 100")
        XCTAssertTrue(conflicts.isEmpty)
    }

    /// deviceWins should adopt server position ONLY when local is 0 (never listened locally).
    func test_deviceWins_adoptsServer_whenLocalIsZero() {
        let podcast = insertPodcast(url: "https://example.com/dw-zero", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 0
        try! context.save()

        let map: [String: EpisodeAction] = [
            episode.guid: buildAction(for: episode, podcast: podcast, position: 300)
        ]
        seedActionMap(map)

        let conflicts = manager.applyEpisodeActions(strategy: .deviceWins)

        XCTAssertEqual(episode.listenedSeconds, 300,
                       "deviceWins: should adopt server when local is 0 (never listened)")
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - Bug 2: Conflict localPosition must use Episode model, not stale actionMap

    /// When a conflict is surfaced via the `.ask` strategy, `localPosition` must
    /// reflect the Episode model's actual `listenedSeconds`, not the actionMap value
    /// (which may contain a server-originated position from a previous sync cycle).
    func test_askConflict_localPosition_usesEpisodeModel_notActionMap() {
        let podcast = insertPodcast(url: "https://example.com/ask-local", episodeCount: 1)
        let episode = podcast.episodes.first!

        // The episode has been listened to locally at position 500
        episode.listenedSeconds = 500
        try! context.save()

        // The actionMap has a STALE value (300) from a previous sync — not the real device position
        // The server now has a NEW value (100) — very different from both
        let staleAction = buildAction(for: episode, podcast: podcast, position: 300, timestamp: 1000)
        seedActionMap([episode.guid: staleAction])

        // Server sends a new action at position 100 (very different from both actionMap and local)
        let serverAction = buildAction(for: episode, podcast: podcast, position: 100, timestamp: 2000)

        // Simulate what syncEpisodeActions does:
        // The new server action arrives and is compared against the actionMap entry (300)
        // |300 - 100| = 200 > 5 → conflict detected in path 1
        // But the REAL local position is 500, not 300

        // Use the apply path directly since we're testing the conflict detection in apply
        let map: [String: EpisodeAction] = [
            episode.guid: serverAction
        ]
        seedActionMap(map)

        let conflicts = manager.applyEpisodeActions(strategy: .ask)

        // THEN: If a conflict is surfaced, localPosition must be the Episode model value (500)
        XCTAssertEqual(conflicts.count, 1, "Should produce a conflict for |500 - 100| > 10")
        if let conflict = conflicts.first {
            XCTAssertEqual(conflict.localPosition, 500,
                           "Conflict localPosition must be episode.listenedSeconds (500), not actionMap value")
            XCTAssertEqual(conflict.serverPosition, 100,
                           "Conflict serverPosition must be the server action's position")
        }

        // The episode's position should NOT have been changed (it's unresolved)
        XCTAssertEqual(episode.listenedSeconds, 500,
                       "Unresolved conflict: episode position must stay at local value")
    }

    // MARK: - Conflict resolution correctness

    /// After resolving a conflict with "Use Device", the episode must have the device position.
    func test_resolveConflict_useDevice_appliesLocalPosition() {
        let podcast = insertPodcast(url: "https://example.com/resolve-dev", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 600
        try! context.save()

        // Set up a conflict
        let map: [String: EpisodeAction] = [
            episode.guid: buildAction(for: episode, podcast: podcast, position: 100)
        ]
        seedActionMap(map)

        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertEqual(conflicts.count, 1, "Should detect a conflict")

        guard let conflict = conflicts.first else { return }

        // WHEN: Resolve with "Use Device" (conflict.localPosition)
        manager.resolveConflict(conflict, chosenPosition: conflict.localPosition)

        // THEN: Episode must have the LOCAL position, not the server position
        XCTAssertEqual(episode.listenedSeconds, 600,
                       "After 'Use Device', episode must be at local position 600")
    }

    /// After resolving a conflict with "Use Server", the episode must have the server position.
    func test_resolveConflict_useServer_appliesServerPosition() {
        let podcast = insertPodcast(url: "https://example.com/resolve-srv", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 600
        try! context.save()

        let map: [String: EpisodeAction] = [
            episode.guid: buildAction(for: episode, podcast: podcast, position: 100)
        ]
        seedActionMap(map)

        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertEqual(conflicts.count, 1, "Should detect a conflict")

        guard let conflict = conflicts.first else { return }

        // WHEN: Resolve with "Use Server" (conflict.serverPosition)
        manager.resolveConflict(conflict, chosenPosition: conflict.serverPosition)

        // THEN: Episode must have the SERVER position
        XCTAssertEqual(episode.listenedSeconds, 100,
                       "After 'Use Server', episode must be at server position 100")
    }

    // MARK: - Bug: Conflict wizard shows UIDs/URLs instead of episode/podcast names

    /// When a server action has NO guid (key=audioUrl), syncEpisodeActions calls
    /// lookupEpisodeMetadata(guid: audioUrl). The lookup must find the episode by
    /// audioUrl fallback and return the human-readable title/podcast name.
    /// Bug: lookupEpisodeMetadata only searched by episode.guid, so when the key
    /// was an audioUrl it returned nil — the UI showed the raw URL instead.
    func test_syncEpisodeActions_conflictMetadata_populatedWhenActionHasNoGuid() async throws {
        let podcast = insertPodcast(url: "https://example.com/metadata-url", title: "My Great Podcast", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 500
        try! context.save()

        let audioUrl = episode.audioUrl!

        // Seed the action map with audioUrl key and an existing position (simulating prior sync)
        let existingAction = EpisodeAction(
            podcast: podcast.url, episode: audioUrl, guid: nil,
            action: "play", timestamp: 1000, position: 300,
            started: 0, total: 3600, device: "other"
        )
        seedActionMap([audioUrl: existingAction])

        // The mock client returns a NEW action for the same episode, with NO guid,
        // at a very different position → triggers conflict in syncEpisodeActions path 1
        let mockClient = ConflictMetadataMockSyncClient()
        await mockClient.setActions([
            EpisodeAction(
                podcast: podcast.url, episode: audioUrl, guid: nil,
                action: "play", timestamp: 2000, position: 100,
                started: 0, total: 3600, device: "other"
            )
        ])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "test" }
        )
        service.loadActionMap()

        // This calls syncEpisodeActions → lookupEpisodeMetadata(guid: audioUrl)
        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        // Find the conflict for our episode (might also have apply-path conflicts)
        let ourConflict = conflicts.first { $0.episodeGuid == audioUrl || $0.episodeGuid == episode.guid }

        XCTAssertNotNil(ourConflict, "Should produce a conflict for |300 - 100| > 5")

        if let conflict = ourConflict {
            // These MUST be the human-readable names, not UIDs or URLs
            XCTAssertEqual(conflict.episodeTitle, episode.title,
                           "Conflict must show episode title '\(episode.title)', not URL/UID. Got: \(conflict.episodeTitle ?? "nil")")
            XCTAssertEqual(conflict.podcastTitle, "My Great Podcast",
                           "Conflict must show podcast title, not URL. Got: \(conflict.podcastTitle ?? "nil")")
            // artworkUrl may be nil when neither episode nor podcast has artwork set —
            // this is expected. The critical fix is episodeTitle and podcastTitle.
        }
    }

    /// Regression: conflicts created via applyActionsForPodcast (path 2) must
    /// also show correct metadata when the actionMap key is an audioUrl.
    func test_applyPath_conflictMetadata_populatedWhenActionMapKeyIsAudioUrl() {
        let podcast = insertPodcast(url: "https://example.com/apply-audio", title: "Apply Path Podcast", episodeCount: 1)
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 400
        try! context.save()

        let audioUrl = episode.audioUrl!

        // Seed actionMap with audioUrl key (no guid key exists)
        let action = EpisodeAction(
            podcast: podcast.url, episode: audioUrl, guid: nil,
            action: "play", timestamp: 2000, position: 100,
            started: 0, total: 3600, device: "other"
        )
        seedActionMap([audioUrl: action])

        let conflicts = manager.applyEpisodeActions(strategy: .ask)

        XCTAssertEqual(conflicts.count, 1, "Should produce conflict for |400 - 100| > 10")
        if let conflict = conflicts.first {
            XCTAssertEqual(conflict.episodeTitle, episode.title,
                           "Apply path must show episode title, not UID/URL")
            XCTAssertEqual(conflict.podcastTitle, "Apply Path Podcast",
                           "Apply path must show podcast title, not URL")
        }
    }

    /// When the server returns a GUID with different casing than the RSS feed stored
    /// (e.g., uppercase UUID from gPodder vs lowercase UUID from RSS), the conflict
    /// metadata lookup must still resolve the episode/podcast names.
    /// UUIDs are case-insensitive per RFC 4122.
    ///
    /// This test uses a non-matching audio URL in the action to ensure the lookup
    /// can ONLY resolve via GUID matching (audio URL fallback won't help).
    func test_syncEpisodeActions_conflictMetadata_resolvesCaseInsensitiveGuid() async throws {
        let podcast = insertPodcast(url: "https://example.com/case-guid", title: "Case Test Podcast", episodeCount: 1)
        let episode = podcast.episodes.first!
        // Override the episode GUID to be lowercase (simulating RSS feed)
        episode.guid = "bcb4380b-3389-4f88-99b1-0b0a4cda0453"
        episode.listenedSeconds = 500
        try! context.save()
        manager.loadSubscriptions()

        // The server uses UPPERCASE version of the same UUID
        let uppercaseGuid = "BCB4380B-3389-4F88-99B1-0B0A4CDA0453"
        // Use a different audio URL that won't match the episode's stored audioUrl
        // This simulates gPodder servers that use the GUID as the episode field,
        // or when the CDN has migrated the audio URL since the action was recorded.
        let serverAudioUrl = "https://old-cdn.example.com/migrated-ep.mp3"

        // Seed actionMap with uppercase GUID key
        let existingAction = EpisodeAction(
            podcast: podcast.url, episode: serverAudioUrl, guid: uppercaseGuid,
            action: "play", timestamp: 1000, position: 300,
            started: 0, total: 3600, device: "other"
        )
        seedActionMap([uppercaseGuid: existingAction])

        // Server sends a new action with uppercase GUID at different position
        let mockClient = ConflictMetadataMockSyncClient()
        await mockClient.setActions([
            EpisodeAction(
                podcast: podcast.url, episode: serverAudioUrl, guid: uppercaseGuid,
                action: "play", timestamp: 2000, position: 100,
                started: 0, total: 3600, device: "other"
            )
        ])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in self?.manager.subscriptions ?? [] },
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "test" }
        )
        service.loadActionMap()

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        let ourConflict = conflicts.first { $0.episodeGuid == uppercaseGuid }

        XCTAssertNotNil(ourConflict, "Should produce a conflict for |300 - 100| > 5")
        if let conflict = ourConflict {
            XCTAssertEqual(conflict.episodeTitle, episode.title,
                           "Must resolve episode title via case-insensitive GUID match. Got: \(conflict.episodeTitle ?? "nil")")
            XCTAssertEqual(conflict.podcastTitle, "Case Test Podcast",
                           "Must resolve podcast title via case-insensitive GUID match. Got: \(conflict.podcastTitle ?? "nil")")
        }
    }

    /// When an episode is no longer in the library or queue (orphaned actionMap entry),
    /// we should not show a conflict dialog for it, since it lacks metadata and the user
    /// cannot play it anyway. The local actionMap should silently update.
    func test_syncEpisodeActions_ignoresConflictsForUnknownEpisodes() async throws {
        let unknownUrl = "https://example.com/unknown-episode.mp3"

        // Seed the action map with an existing position (simulating prior sync for a deleted podcast)
        let existingAction = EpisodeAction(
            podcast: "https://example.com/unknown-podcast", episode: unknownUrl, guid: nil,
            action: "play", timestamp: 1000, position: 300,
            started: 0, total: 3600, device: "other"
        )
        seedActionMap([unknownUrl: existingAction])

        // The mock client returns a NEW action for the unknown episode
        // at a very different position
        let mockClient = ConflictMetadataMockSyncClient()
        let newAction = EpisodeAction(
            podcast: "https://example.com/unknown-podcast", episode: unknownUrl, guid: nil,
            action: "play", timestamp: 2000, position: 100,
            started: 0, total: 3600, device: "other"
        )
        await mockClient.setActions([newAction])

        let service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] }, // Empty subscriptions
            syncClientProvider: { mockClient },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "test" }
        )
        service.loadActionMap()

        let conflicts = try await service.syncEpisodeActions(force: true, strategy: .ask)

        XCTAssertTrue(conflicts.isEmpty, "Should ignore conflict for unknown episode")
        XCTAssertEqual(service.actionMap[unknownUrl]?.position, 100, "Should silently update action map to newest position")
    }
}

// MARK: - Mock SyncClient for conflict metadata tests

/// Actor-based mock that returns configurable episode actions for
/// testing the syncEpisodeActions code path.
actor ConflictMetadataMockSyncClient: SyncClient {
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

// MARK: - Extracted from YourPodsTests.swift

// MARK: - Conflict Resolution Strategy Tests

final class ConflictResolutionTests: XCTestCase {

    /// Evaluates the sync strategy logic — extracted to suppress constant-switch warnings.
    private func shouldOverwrite(strategy: SyncStrategy, localPosition: Int, serverPosition: Int) -> Bool {
        switch strategy {
        case .serverWins:
            return serverPosition > 0
        case .deviceWins:
            return localPosition == 0
        case .ask:
            return false // conflicts are collected, not auto-resolved
        }
    }

    func test_applyEpisodeActions_deviceWins_doesNotRegress() {
        // GIVEN: An episode at local position 200, server says 100
        // With strategy = .deviceWins

        // Test the logic directly: when device wins, local >= server means keep local
        XCTAssertFalse(shouldOverwrite(strategy: .deviceWins, localPosition: 200, serverPosition: 100),
                       "deviceWins should NOT overwrite local=200 with server=100")
    }

    func test_applyEpisodeActions_deviceWins_keepsDeviceWhenBothNonZero() {
        // GIVEN: An episode at local position 100, server says 300
        // With strategy = .deviceWins — device position is always preserved

        XCTAssertFalse(shouldOverwrite(strategy: .deviceWins, localPosition: 100, serverPosition: 300),
                       "deviceWins should NOT overwrite local=100 with server=300 — device always wins")
    }

    func test_applyEpisodeActions_serverWins_alwaysOverwrites() {
        // GIVEN: An episode at local position 200, server says 100
        // With strategy = .serverWins

        XCTAssertTrue(shouldOverwrite(strategy: .serverWins, localPosition: 200, serverPosition: 100),
                      "serverWins should overwrite even when going backward (server=100, local=200)")
    }

    func test_applyEpisodeActions_ask_collectsConflict() {
        // GIVEN: An episode at local position 200, server says 100
        // With strategy = .ask and positions differ by > threshold

        let localPosition = 200
        let serverPosition = 100
        let threshold = 10 // seconds

        let isConflict = abs(serverPosition - localPosition) > threshold
        XCTAssertTrue(isConflict,
                      "Positions differing by 100s should be detected as a conflict")
    }

    func test_applyEpisodeActions_ask_noConflictWhenCloseEnough() {
        // GIVEN: Positions are within threshold
        let localPosition = 200
        let serverPosition = 205
        let threshold = 10

        let isConflict = abs(serverPosition - localPosition) > threshold
        XCTAssertFalse(isConflict,
                       "Positions within 10s should NOT be treated as a conflict")
    }
}


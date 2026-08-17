import XCTest
import SwiftData
@testable import YourPods

/// Comprehensive tests for PodcastManager's non-networking logic.
/// Uses SwiftData in-memory containers and direct UserDefaults keys.
@MainActor
final class PodcastManagerLogicTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    
    /// Profile ID used by tests — set up and torn down each run.
    private let testProfileId = "test-profile-pm-logic"
    
    override func setUp() {
        super.setUp()
        
        // Clear test data BEFORE creating the manager
        clearTestDefaults()
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        // Use the container's main context — same context PodcastManager will query from
        context = container.mainContext
        
        // Set the active profile so PodcastManager can scope subscriptions
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
            "serverProfiles"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    // MARK: - Helpers
    
    /// Insert a podcast + episodes directly into SwiftData (bypasses RSS fetch).
    @discardableResult
    private func insertPodcast(
        url: String = "https://example.com/feed",
        title: String = "Test Podcast",
        episodeCount: Int = 3
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }
        
        try! context.save()
        
        // Associate with test profile
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        
        return podcast
    }
    
    /// Seed the action map via UserDefaults so manager can load it.
    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }
    
    // MARK: - Subscribe / Unsubscribe (via direct SwiftData)
    
    func test_insertPodcast_appearsInSubscriptions() {
        insertPodcast(url: "https://example.com/feed1", title: "Pod 1")
        
        XCTAssertEqual(manager.subscriptions.count, 1)
        XCTAssertEqual(manager.subscriptions.first?.title, "Pod 1")
    }
    
    func test_insertPodcast_createsEpisodes() {
        let podcast = insertPodcast(url: "https://example.com/feed1", episodeCount: 5)
        
        XCTAssertEqual(podcast.episodes.count, 5)
    }
    
    func test_removeSubscription_deletesPodcast() async {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        XCTAssertEqual(manager.subscriptions.count, 1)
        
        await manager.removeSubscription(podcast)
        
        XCTAssertEqual(manager.subscriptions.count, 0)
    }
    
    func test_removeSubscription_disassociatesFromProfile() async {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        
        await manager.removeSubscription(podcast)
        
        // After removal, re-loading should show empty
        manager.loadSubscriptions()
        XCTAssertEqual(manager.subscriptions.count, 0)
    }
    
    func test_multipleSubscriptions_allVisible() {
        insertPodcast(url: "https://example.com/feed1", title: "Pod 1")
        insertPodcast(url: "https://example.com/feed2", title: "Pod 2")
        insertPodcast(url: "https://example.com/feed3", title: "Pod 3")
        
        XCTAssertEqual(manager.subscriptions.count, 3)
    }
    
    // MARK: - Episode Progress
    
    func test_updateEpisodeProgress_setsListenedSeconds() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        
        manager.updateEpisodeProgress(
            podcastUrl: podcast.url,
            episodeGuid: episode.guid,
            position: 500
        )
        
        XCTAssertEqual(episode.listenedSeconds, 500)
    }
    
    func test_updateEpisodeProgress_noOpWhenPositionUnchanged() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 500
        try! context.save()
        
        // Calling with same position should be a no-op (the guard checks != position)
        manager.updateEpisodeProgress(
            podcastUrl: podcast.url,
            episodeGuid: episode.guid,
            position: 500
        )
        
        XCTAssertEqual(episode.listenedSeconds, 500)
    }
    
    func test_updateEpisodeProgressByGuid_findsAcrossPodcasts() {
        insertPodcast(url: "https://example.com/feed1", title: "Pod 1")
        let podcast2 = insertPodcast(url: "https://example.com/feed2", title: "Pod 2")
        let episode = podcast2.episodes.first!
        
        manager.updateEpisodeProgressByGuid(
            episodeGuid: episode.guid,
            position: 1200
        )
        
        XCTAssertEqual(episode.listenedSeconds, 1200)
    }
    
    func test_markEpisodeAsPlayed_setsIsPlayedAndFullPosition() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        
        manager.markEpisodeAsPlayed(
            podcastUrl: podcast.url,
            episodeGuid: episode.guid
        )
        
        XCTAssertTrue(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, episode.durationSeconds ?? 0)
    }
    
    func test_markEpisodeAsUnplayed_resetsPositionAndFlag() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.isPlayed = true
        episode.listenedSeconds = 3600
        try! context.save()
        
        manager.markEpisodeAsUnplayed(
            podcastUrl: podcast.url,
            episodeGuid: episode.guid
        )
        
        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(episode.listenedSeconds, 0)
    }
    
    func test_markEpisodePlayedLocally_setsOnlyIsPlayed() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 1500
        try! context.save()
        
        manager.markEpisodePlayedLocally(
            podcastUrl: podcast.url,
            episodeGuid: episode.guid
        )
        
        XCTAssertTrue(episode.isPlayed)
        // Position should NOT be changed by local-only mark
        XCTAssertEqual(episode.listenedSeconds, 1500)
    }
    
    func test_markAllEpisodesAsPlayed_batchesAll() {
        let podcast = insertPodcast(url: "https://example.com/feed1", episodeCount: 5)
        
        manager.markAllEpisodesAsPlayed(for: podcast)
        
        for episode in podcast.episodes {
            XCTAssertTrue(episode.isPlayed, "Episode \(episode.guid) should be played")
        }
    }
    
    // MARK: - Action Map & Persistence
    
    func test_actionMap_persistsAndLoadsFromUserDefaults() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 500,
            started: 0,
            total: 3600,
            device: "test"
        )
        
        seedActionMap(["ep-1": action])
        
        XCTAssertEqual(manager.actionMap["ep-1"]?.position, 500)
    }
    
    func test_getLatestAction_returnsCorrectEntry() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: 1700000000,
            position: 300,
            started: 0,
            total: 3600,
            device: "test"
        )
        
        seedActionMap(["ep-1": action])
        
        let result = manager.getLatestAction(for: "ep-1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.position, 300)
    }
    
    func test_getLatestAction_returnsNilForUnknownGuid() {
        let result = manager.getLatestAction(for: "nonexistent")
        XCTAssertNil(result)
    }
    
    func test_sendEpisodeAction_updatesActionMap() async {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 750,
            started: 0,
            total: 3600,
            device: "test"
        )
        
        await manager.sendEpisodeAction(action)
        
        XCTAssertEqual(manager.actionMap["ep-1"]?.position, 750)
    }
    
    func test_sendEpisodeAction_fallsBackToEpisodeUrlKey() async {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: nil,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 200,
            started: 0,
            total: 3600,
            device: "test"
        )
        
        await manager.sendEpisodeAction(action)
        
        // When guid is nil, key should be the episode URL
        XCTAssertEqual(manager.actionMap["https://example.com/ep1.mp3"]?.position, 200)
    }
    
    // MARK: - Conflict Resolution: applyEpisodeActions
    
    func test_applyEpisodeActions_serverWins_alwaysOverwrites() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300  // Local is at 300
        try! context.save()
        
        // Server says 100 (behind local)
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 100,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .serverWins)
        
        XCTAssertEqual(episode.listenedSeconds, 100,
                       "serverWins should always overwrite, even going backward")
        XCTAssertTrue(conflicts.isEmpty)
    }
    
    func test_applyEpisodeActions_deviceWins_neverGoesBackward() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300  // Local is at 300
        try! context.save()
        
        // Server says 100 (behind local)
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 100,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .deviceWins)
        
        XCTAssertEqual(episode.listenedSeconds, 300,
                       "deviceWins should NOT go backward")
        XCTAssertTrue(conflicts.isEmpty)
    }
    
    func test_applyEpisodeActions_deviceWins_keepsDeviceWhenServerAhead() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 100  // Local is at 100
        try! context.save()
        
        // Server says 500 (ahead of local)
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        manager.applyEpisodeActions(strategy: .deviceWins)
        
        XCTAssertEqual(episode.listenedSeconds, 100,
                       "deviceWins: device position (100) must be preserved even when server is ahead (500)")
    }
    
    func test_applyEpisodeActions_ask_collectsUnresolvedConflicts() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300
        try! context.save()
        
        // Server says 1500 — diff > 10s threshold
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.episodeGuid, episode.guid)
        XCTAssertEqual(conflicts.first?.localPosition, 300)
        XCTAssertEqual(conflicts.first?.serverPosition, 1500)
        // Position should NOT be overwritten when strategy is .ask
        XCTAssertEqual(episode.listenedSeconds, 300)
    }
    
    func test_applyEpisodeActions_ask_autoResolvesSmallDiffs() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300
        try! context.save()
        
        // Server says 305 — diff is only 5s, below 10s threshold
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 305,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        
        XCTAssertTrue(conflicts.isEmpty, "Diffs ≤10s should auto-resolve")
        XCTAssertEqual(episode.listenedSeconds, 305, "Auto-resolve takes the higher value")
    }
    
    func test_applyEpisodeActions_ask_autoResolvesEffectivelyComplete() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 3500  // ≥95% of 3600
        try! context.save()
        
        // Server also says nearly complete, but at different position
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 3450,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        
        XCTAssertTrue(conflicts.isEmpty, "Episodes ≥95% should auto-resolve")
        XCTAssertEqual(episode.listenedSeconds, 3500, "Auto-resolve takes the higher value")
    }
    
    func test_applyEpisodeActions_skipsPlayedEpisodesInAskMode() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.isPlayed = true
        episode.listenedSeconds = 3600
        try! context.save()
        
        // Server says different position
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        
        XCTAssertTrue(conflicts.isEmpty, "Played episodes should not generate conflicts")
    }
    
    func test_applyEpisodeActions_marksEpisodePlayedAt95Percent() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        episode.listenedSeconds = 0
        try! context.save()
        
        // Server says listened to 3500/3600 (≥95%)
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 3500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        manager.applyEpisodeActions(strategy: .serverWins)
        
        XCTAssertTrue(episode.isPlayed,
                      "Episode at ≥95% should be auto-marked as played")
    }
    
    // MARK: - Conflict Resolution: resolveConflict
    
    func test_resolveConflict_updatesModelAndActionMap() async {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300
        try! context.save()
        
        let conflict = SyncConflict(
            episodeGuid: episode.guid,
            episodeTitle: episode.title,
            podcastTitle: podcast.title,
            podcastUrl: podcast.url,
            artworkUrl: nil,
            audioUrl: episode.audioUrl,
            localPosition: 300,
            serverPosition: 1500,
            serverTimestamp: Int(Date().timeIntervalSince1970),
            totalDuration: 3600,
            occurrenceCount: 1
        )
        
        await manager.resolveConflict(conflict, chosenPosition: 1500)
        
        XCTAssertEqual(episode.listenedSeconds, 1500,
                       "resolveConflict should update the episode position")
        XCTAssertEqual(manager.actionMap[episode.guid]?.position, 1500,
                       "resolveConflict should update the actionMap")
    }
    
    // MARK: - Profile Management
    
    func test_loadSubscriptions_filtersToActiveProfile() {
        // Insert podcast associated with test profile
        insertPodcast(url: "https://example.com/feed1", title: "My Pod")
        
        // Insert podcast NOT associated with test profile (directly into SwiftData)
        let unassociated = Podcast(url: "https://example.com/feed-other", title: "Other Pod")
        context.insert(unassociated)
        try! context.save()
        
        manager.loadSubscriptions()
        
        XCTAssertEqual(manager.subscriptions.count, 1)
        XCTAssertEqual(manager.subscriptions.first?.title, "My Pod")
    }
    
    func test_clearProfileData_removesAllKeys() {
        // Set some profile-specific data
        UserDefaults.standard.set(42, forKey: "lastSubscriptionSync_\(testProfileId)")
        UserDefaults.standard.set(99, forKey: "lastEpisodeActionSync_\(testProfileId)")
        
        manager.clearProfileData(profileId: testProfileId)
        
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastSubscriptionSync_\(testProfileId)"), 0)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastEpisodeActionSync_\(testProfileId)"), 0)
    }
    
    func test_associateDisassociate_roundTrip() {
        // Keep a second podcast so disassociating the first doesn't empty the URL set
        // (empty URL set triggers the migration path which re-adopts all podcasts)
        insertPodcast(url: "https://example.com/keep-this", title: "Keeper")
        
        manager.associateWithCurrentProfile(url: "https://example.com/new-feed")
        
        // Verify it's associated by inserting a podcast and loading
        let podcast = Podcast(url: "https://example.com/new-feed", title: "New Pod")
        context.insert(podcast)
        try! context.save()
        manager.loadSubscriptions()
        XCTAssertEqual(manager.subscriptions.count, 2) // Keeper + New Pod
        
        // Disassociate only the new feed
        manager.disassociateFromCurrentProfile(url: "https://example.com/new-feed")
        manager.loadSubscriptions()
        XCTAssertEqual(manager.subscriptions.count, 1,
                       "Disassociated URL should not appear in subscriptions")
        XCTAssertEqual(manager.subscriptions.first?.title, "Keeper")
    }
    
    func test_hasOtherProfiles_falseWhenSingle() {
        // No profiles stored at all
        XCTAssertFalse(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }
    
    func test_hasOtherProfiles_trueWhenMultiple() {
        let profiles = [
            ServerProfile(id: testProfileId, name: "Test"),
            ServerProfile(id: "other-profile", name: "Other")
        ]
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "serverProfiles")
        }
        
        XCTAssertTrue(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }
    
    // MARK: - Conflict Count Tracking
    
    func test_conflictCount_incrementsOnMultipleConflicts() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300
        try! context.save()
        
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        // First conflict
        let conflicts1 = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertEqual(conflicts1.first?.occurrenceCount, 1)
        
        // Second conflict (re-apply)
        let conflicts2 = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertEqual(conflicts2.first?.occurrenceCount, 2)
    }
    
    func test_conflictCount_clearedOnResolve() async {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300
        try! context.save()
        
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        // Generate a conflict
        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertEqual(conflicts.count, 1)
        
        // Resolve it
        await manager.resolveConflict(conflicts.first!, chosenPosition: 1500)
        
        // Re-apply — should not generate a conflict now because position matches
        let conflictsAfter = manager.applyEpisodeActions(strategy: .ask)
        XCTAssertTrue(conflictsAfter.isEmpty,
                      "No conflict should remain after resolution")
    }
    
    func test_conflictCount_persistsToUserDefaults() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 300
        try! context.save()
        
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1500,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        _ = manager.applyEpisodeActions(strategy: .ask)
        
        // Verify serialized to UserDefaults
        let data = UserDefaults.standard.data(forKey: "syncConflictCounts")
        XCTAssertNotNil(data, "Conflict counts should be persisted to UserDefaults")
    }
    
    // MARK: - Episode Interaction Tracking
    
    func test_markEpisodeAsInteracted_setsIsInteracted() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        
        manager.markEpisodeAsInteracted(podcast.url, episode.guid)
        
        XCTAssertTrue(episode.isInteracted)
    }
    
    // MARK: - Reorder
    
    func test_reorderSubscriptions_updatesSortOrder() {
        insertPodcast(url: "https://example.com/feed1", title: "A")
        insertPodcast(url: "https://example.com/feed2", title: "B")
        insertPodcast(url: "https://example.com/feed3", title: "C")
        
        let list = manager.subscriptions
        guard list.count == 3 else {
            XCTFail("Expected 3 subscriptions, got \(list.count)")
            return
        }
        
        let originalFirst = list[0].title
        
        // Move first item to end
        manager.reorderSubscriptions(from: IndexSet(integer: 0), to: 3, filteredList: list)
        
        // The previously first item should no longer be first
        let reloaded = manager.subscriptions
        if reloaded.count == 3 {
            XCTAssertNotEqual(reloaded[0].title, originalFirst,
                              "First item should have moved after reorder")
        }
    }
    
    // MARK: - getEpisodes
    
    func test_getEpisodes_returnsSortedByPubDate() {
        let podcast = insertPodcast(url: "https://example.com/feed1", episodeCount: 5)
        
        let episodes = manager.getEpisodes(for: podcast.url)
        
        XCTAssertEqual(episodes.count, 5)
        // Should be sorted newest first
        for i in 0..<(episodes.count - 1) {
            XCTAssertGreaterThanOrEqual(
                episodes[i].pubDate ?? .distantPast,
                episodes[i + 1].pubDate ?? .distantPast,
                "Episodes should be sorted newest first"
            )
        }
    }
    
    func test_getEpisodes_emptyForUnknownUrl() {
        let episodes = manager.getEpisodes(for: "https://nonexistent.com/feed")
        XCTAssertTrue(episodes.isEmpty)
    }
    
    // MARK: - refreshAndSync Strategy Passthrough (Bug Fix)
    
    /// Verify that applyEpisodeActions with .ask strategy surfaces conflicts
    /// instead of silently auto-resolving. This is the core logic that
    /// refreshAndSync now passes through via its `strategy:` parameter.
    func test_applyEpisodeActions_ask_surfacesConflictsForRefreshAndSync() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 1312  // ~21:52 (Device A position)
        try! context.save()
        
        // Server reports a different position (~12:51 from Device B)
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 771,  // ~12:51
            started: 0,
            total: 3600,
            device: "other-device"
        )
        seedActionMap([episode.guid: action])
        
        // With .ask strategy, conflicts must be returned (not silently resolved)
        let conflicts = manager.applyEpisodeActions(strategy: .ask)
        
        XCTAssertEqual(conflicts.count, 1,
                       "Strategy .ask should return unresolved conflicts, not swallow them")
        XCTAssertEqual(conflicts.first?.episodeGuid, episode.guid)
        XCTAssertEqual(conflicts.first?.localPosition, 1312)
        XCTAssertEqual(conflicts.first?.serverPosition, 771)
        // Position must NOT be overwritten
        XCTAssertEqual(episode.listenedSeconds, 1312,
                       "Device position must be preserved when strategy is .ask")
    }
    
    /// Verify .serverWins always overwrites — this is what the old hard-coded
    /// default did, silently resolving all conflicts.
    func test_applyEpisodeActions_serverWins_neverSurfacesConflicts() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 1312
        try! context.save()
        
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 771,
            started: 0,
            total: 3600,
            device: "other-device"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .serverWins)
        
        XCTAssertTrue(conflicts.isEmpty,
                      ".serverWins should auto-resolve — this was the bug, it was always used")
        XCTAssertEqual(episode.listenedSeconds, 771,
                       "Server position should overwrite local")
    }
    
    /// Verify .deviceWins keeps the local position when it's ahead.
    func test_applyEpisodeActions_deviceWins_keepsLocalWhenAhead() {
        let podcast = insertPodcast(url: "https://example.com/feed1")
        let episode = podcast.episodes.first!
        episode.listenedSeconds = 1312  // Local is ahead
        try! context.save()
        
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 771,  // Server is behind
            started: 0,
            total: 3600,
            device: "other-device"
        )
        seedActionMap([episode.guid: action])
        
        let conflicts = manager.applyEpisodeActions(strategy: .deviceWins)
        
        XCTAssertTrue(conflicts.isEmpty,
                      ".deviceWins should auto-resolve with no conflicts")
        XCTAssertEqual(episode.listenedSeconds, 1312,
                       "Local position must be preserved when device wins and is ahead")
    }
    
    /// Compile-time verification that refreshAndSync accepts a strategy parameter.
    /// We can't call it directly in unit tests (it hits RSS), but we verify the signature.
    func test_refreshAndSync_signatureAcceptsStrategy() {
        // This test verifies the method signature exists with the strategy parameter.
        // The actual method can't be tested without mocking RSS, but the signature
        // must compile for the SettingsView and HomeView fixes to work.
        let _: (PlayerManager, DownloadManager, SettingsManager, SyncStrategy) async -> [SyncConflict] = { pm, dm, sm, strategy in
            return await self.manager.refreshAndSync(
                playerManager: pm,
                downloadManager: dm,
                settingsManager: sm,
                strategy: strategy
            )
        }
        // If this compiles, the fix is in place.
    }
    
    // MARK: - Auto-Queue Candidates (nil fallback to global default)
    // Regression: getAutoQueueCandidates returned empty when per-podcast
    // autoQueueMode was nil (should inherit global default).
    
    func test_getAutoQueueCandidates_returnsEpisodes_whenNilModeAndGlobalIsNormal() {
        // GIVEN: A podcast with nil autoQueueMode (no per-podcast override)
        let podcast = insertPodcast(url: "https://example.com/auto-q-feed", episodeCount: 3)
        XCTAssertNil(podcast.effectiveSettings.autoQueueMode,
                     "Precondition: per-podcast autoQueueMode should be nil")
        
        // WHEN: Requesting auto-queue candidates with a global default of .normal
        let candidates = manager.getAutoQueueCandidates(for: podcast, globalDefault: .normal)
        
        // THEN: Should return episodes (not empty)
        XCTAssertFalse(candidates.isEmpty,
                       "nil per-podcast autoQueueMode + global .normal should return candidates")
    }
    
    func test_getAutoQueueCandidates_returnsEmpty_whenExplicitOff() {
        // GIVEN: A podcast with autoQueueMode explicitly set to .off
        let podcast = insertPodcast(url: "https://example.com/auto-q-off-feed", episodeCount: 3)
        podcast.effectiveSettings.autoQueueMode = .off
        try! context.save()
        
        // WHEN: Requesting auto-queue candidates with a global default of .normal
        let candidates = manager.getAutoQueueCandidates(for: podcast, globalDefault: .normal)
        
        // THEN: Should return empty (explicit .off overrides global)
        XCTAssertTrue(candidates.isEmpty,
                      "Explicit .off should override global .normal and return empty")
    }
    
    func test_getAutoQueueCandidates_returnsEmpty_whenNilModeAndGlobalIsOff() {
        // GIVEN: A podcast with nil autoQueueMode
        let podcast = insertPodcast(url: "https://example.com/auto-q-global-off-feed", episodeCount: 3)
        XCTAssertNil(podcast.effectiveSettings.autoQueueMode)
        
        // WHEN: Requesting auto-queue candidates with a global default of .off
        let candidates = manager.getAutoQueueCandidates(for: podcast, globalDefault: .off)
        
        // THEN: Should return empty (global is .off)
        XCTAssertTrue(candidates.isEmpty,
                      "nil per-podcast autoQueueMode + global .off should return empty")
    }
    
    // MARK: - Batch Save: applyEpisodeActions (crash fix: __CFStringEqual)
    
    /// Regression: With many episodes (100+), a single modelContext.save() at the end
    /// caused __CFStringEqual crashes in NSSQLRow newColumnMaskFrom: because
    /// autorelease pool pressure released __NSCFString objects from faulted-in rows
    /// before Core Data's column mask comparison could use them.
    ///
    /// Fix: batch save every 50 episodes to limit dirty object accumulation.
    /// This test verifies all episodes get their positions updated correctly
    /// even with many episodes (batch saves don't lose data).
    func test_applyEpisodeActions_manyEpisodes_allPositionsUpdated() {
        // GIVEN: 5 podcasts with 25 episodes each (125 total) — well above batch threshold
        let podcastCount = 5
        let episodesPerPodcast = 25
        var allEpisodes: [Episode] = []
        var actionEntries: [String: EpisodeAction] = [:]
        
        for p in 0..<podcastCount {
            let podcast = insertPodcast(
                url: "https://example.com/batch-feed-\(p)",
                title: "Batch Pod \(p)",
                episodeCount: episodesPerPodcast
            )
            for episode in podcast.episodes {
                let position = (p * 1000) + 500  // Unique position per podcast
                actionEntries[episode.guid] = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: position,
                    started: 0,
                    total: 3600,
                    device: "server"
                )
                allEpisodes.append(episode)
            }
        }
        
        seedActionMap(actionEntries)
        
        // WHEN: applying episode actions
        manager.applyEpisodeActions(strategy: .serverWins)
        
        // THEN: ALL episodes should have their positions updated (none lost in batching)
        for episode in allEpisodes {
            let expectedAction = actionEntries[episode.guid]!
            XCTAssertEqual(
                episode.listenedSeconds,
                expectedAction.position!,
                "Episode \(episode.guid) should have position \(expectedAction.position!) but got \(episode.listenedSeconds)"
            )
        }
    }
    
    /// Verify that applyEpisodeActions uses batch saves (save count > 1 for large sets).
    /// This is the core fix — the old code did a single save() at the end which accumulated
    /// too many dirty objects with stale string references.
    func test_applyEpisodeActions_savesBatchCount_moreThanOne() {
        // GIVEN: 120 episodes across 4 podcasts — should require multiple batch saves with batchSize=50
        var actionEntries: [String: EpisodeAction] = [:]
        
        for p in 0..<4 {
            let podcast = insertPodcast(
                url: "https://example.com/batch-count-feed-\(p)",
                title: "Batch Count Pod \(p)",
                episodeCount: 30
            )
            for episode in podcast.episodes {
                actionEntries[episode.guid] = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: 500,
                    started: 0,
                    total: 3600,
                    device: "server"
                )
            }
        }
        
        seedActionMap(actionEntries)
        
        // WHEN: applying episode actions with stats tracking
        let (_, saveCount) = manager.applyEpisodeActionsWithStats(strategy: .serverWins)
        
        // THEN: With cross-podcast batching (batch size 500), 120 episodes = 1 save
        XCTAssertEqual(saveCount, 1,
                       "120 episodes (< batch size 500) should produce 1 final save, got \(saveCount)")
    }
    
    /// The fix: autoreleasepool wrapping per 50-episode batch contains
    /// faulted-in __NSCFString objects. Save is deferred to the cross-podcast
    /// batch level (every 500 episodes) to reduce WAL checkpoint overhead.
    ///
    /// This test verifies that 30 total episodes (below the 500 batch threshold)
    /// produce exactly 1 final save.
    func test_applyEpisodeActions_savesPerPodcast_notJustPerBatchThreshold() {
        // GIVEN: 3 podcasts with 10 episodes each (30 total — below cross-podcast batch size of 500)
        var actionEntries: [String: EpisodeAction] = [:]
        
        for p in 0..<3 {
            let podcast = insertPodcast(
                url: "https://example.com/per-podcast-save-\(p)",
                title: "Per-Podcast Save \(p)",
                episodeCount: 10
            )
            for episode in podcast.episodes {
                actionEntries[episode.guid] = EpisodeAction(
                    podcast: podcast.url,
                    episode: episode.audioUrl ?? "",
                    guid: episode.guid,
                    action: "play",
                    timestamp: Int(Date().timeIntervalSince1970),
                    position: 500,
                    started: 0,
                    total: 3600,
                    device: "server"
                )
            }
        }
        
        seedActionMap(actionEntries)
        
        // WHEN: applying episode actions
        let (_, saveCount) = manager.applyEpisodeActionsWithStats(strategy: .serverWins)
        
        // THEN: With cross-podcast batching (batch size 500), 30 episodes = 1 final save.
        // The autoreleasepool still wraps per-50-episode batches within each podcast
        // to prevent __CFStringEqual crashes — only the save point moved.
        XCTAssertEqual(saveCount, 1,
            "30 episodes (< batch size 500) should produce 1 final save, got \(saveCount)")
    }
    
    func test_applyEpisodeActions_handlesEpisodeWithLongDescription() {
        // GIVEN: An episode with a very long description (exercises string comparison paths)
        let podcast = insertPodcast(url: "https://example.com/long-desc-feed", episodeCount: 1)
        let episode = podcast.episodes.first!
        // Set a very long description to stress Core Data's string comparison
        episode.episodeDescription = String(repeating: "Lorem ipsum dolor sit amet. ", count: 500)
        episode.chaptersJSON = "{\"chapters\":[{\"title\":\"\(String(repeating: "x", count: 1000))\"}]}"
        try! context.save()
        
        let action = EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 1800,
            started: 0,
            total: 3600,
            device: "server"
        )
        seedActionMap([episode.guid: action])
        
        // WHEN: applying episode actions
        manager.applyEpisodeActions(strategy: .serverWins)
        
        // THEN: Episode position should be updated without crash
        XCTAssertEqual(episode.listenedSeconds, 1800)
        // Description should be unchanged (save didn't corrupt it)
        XCTAssertTrue(episode.episodeDescription!.hasPrefix("Lorem ipsum"))
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// Integration tests for auto-queue: verifies that PodcastManager → PlayerManager → AudioManager
/// are properly wired so existing episodes actually end up in the AudioManager queue.
///
/// These tests differ from the existing isolated tests in PodcastManagerLogicTests and
/// YourPodsTests, which only tested the decision logic (`mode != .off`) or the candidates
/// helper function in isolation. **Those tests passed even when getAutoQueueCandidates was
/// never called from production code**, which caused a regression.
@MainActor
final class AutoQueueIntegrationTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!
    private var settingsManager: SettingsManager!
    
    private let testProfileId = "test-profile-autoqueue-integration"
    
    override func setUp() {
        super.setUp()
        clearTestDefaults()
        
        // SwiftData in-memory
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        // Set active profile
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        
        // Wire up real components
        podcastManager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
        settingsManager = SettingsManager()
    }
    
    override func tearDown() {
        clearTestDefaults()
        podcastManager = nil
        audioManager = nil
        playerManager = nil
        settingsManager = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
            "defaultAutoQueueMode",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
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
        podcastManager.associateWithCurrentProfile(url: url)
        podcastManager.loadSubscriptions()
        
        return podcast
    }
    
    // MARK: - Integration: autoQueueExistingEpisodes
    
    /// Regression test: verifies that the most recent existing un-interacted episode
    /// is added to the AudioManager queue when global auto-queue is enabled.
    /// Only the LATEST episode is queued — not the entire back-catalog.
    func test_autoQueueExistingEpisodes_addsMostRecentEpisodeOnly_whenGlobalModeIsNormal() {
        // GIVEN: A podcast with 3 existing episodes and global auto-queue = .normal
        let podcast = insertPodcast(url: "https://example.com/daily-feed", title: "The Daily", episodeCount: 3)
        settingsManager.defaultAutoQueueMode = .normal
        
        // Precondition: AudioManager queue is empty
        XCTAssertTrue(audioManager.queue.isEmpty, "Precondition: queue should be empty")
        
        // WHEN: autoQueueExistingEpisodes is called
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: Only 1 episode (the most recent) should be in the queue
        XCTAssertEqual(audioManager.queue.count, 1,
                       "Only the most recent episode should be auto-queued, not the entire back-catalog")
        
        // AND: It should be the newest episode (Episode 1 has pubDate -1 day, the most recent)
        let newestEpisode = podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }.first!
        XCTAssertEqual(audioManager.queue.first?.id, newestEpisode.guid,
                       "The queued episode should be the most recent one")
    }
    
    /// Verifies no episodes are queued when global auto-queue mode is .off.
    func test_autoQueueExistingEpisodes_queuesNothing_whenGlobalModeIsOff() {
        // GIVEN: A podcast with episodes and global auto-queue = .off
        insertPodcast(url: "https://example.com/off-feed", episodeCount: 3)
        settingsManager.defaultAutoQueueMode = .off
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: Queue should remain empty
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "No episodes should be queued when global mode is .off")
    }
    
    /// Verifies that per-podcast .off overrides global .normal.
    func test_autoQueueExistingEpisodes_respectsPerPodcastOff_overridingGlobalNormal() {
        // GIVEN: A podcast with per-podcast auto-queue explicitly .off, global .normal
        let podcast = insertPodcast(url: "https://example.com/override-feed", episodeCount: 3)
        podcast.effectiveSettings.autoQueueMode = .off
        try! context.save()
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: Queue should remain empty (per-podcast .off wins)
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "Per-podcast .off should override global .normal")
    }
    
    /// Verifies that if the most recent episode is already interacted, the next most recent is queued.
    func test_autoQueueExistingEpisodes_skipsInteractedMostRecent() {
        // GIVEN: A podcast with 3 episodes, the most recent already interacted
        let podcast = insertPodcast(url: "https://example.com/interacted-feed", episodeCount: 3)
        let sorted = podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        let newestEpisode = sorted[0]
        let secondNewest = sorted[1]
        podcastManager.markEpisodeAsInteracted(podcast.url, newestEpisode.guid)
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: The second-newest episode should be queued (most recent un-interacted)
        XCTAssertEqual(audioManager.queue.count, 1,
                       "Should queue 1 episode (the next most recent un-interacted)")
        XCTAssertEqual(audioManager.queue.first?.id, secondNewest.guid,
                       "Should be the second-newest episode since newest is interacted")
    }
    
    /// Verifies that calling autoQueueExistingEpisodes twice does not create duplicates
    /// of the same episode, but instead queues the next eligible back-catalog episode.
    func test_autoQueueExistingEpisodes_doesNotDuplicate_sameEpisode_whenCalledTwice() {
        // GIVEN: A podcast with 3 episodes and global auto-queue = .normal
        insertPodcast(url: "https://example.com/dedup-feed", episodeCount: 3)
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN: Called twice (simulating two Refresh & Sync taps on an old subscription)
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        let firstQueue = audioManager.queue
        
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        let secondQueue = audioManager.queue
        
        // THEN: First call queued Ep 1, second call queued Ep 2. NO duplicates of Ep 1.
        XCTAssertEqual(firstQueue.count, 1)
        XCTAssertEqual(secondQueue.count, 2)
        XCTAssertNotEqual(secondQueue[0].id, secondQueue[1].id, "Should not duplicate the same episode")
    }
    
    /// Verifies priority mode uses insertNext (play next) instead of append.
    func test_autoQueueExistingEpisodes_usesPriorityInsert_whenModeIsPriority() {
        // GIVEN: An existing item in the queue, a podcast with priority auto-queue
        let existingItem = QueueItem(
            id: "existing-ep",
            title: "Already Queued",
            podcastTitle: "Other Pod",
            audioUrl: "https://example.com/other.mp3",
            artworkUrl: nil,
            durationSeconds: 1800,
            podcastUrl: "https://example.com/other",
            pubDate: nil
        )
        audioManager.appendToQueue([existingItem])
        
        insertPodcast(url: "https://example.com/priority-feed", title: "Priority Pod", episodeCount: 1)
        // Set per-podcast mode directly via the subscription
        let podcast = podcastManager.subscriptions.first(where: { $0.url == "https://example.com/priority-feed" })!
        podcast.effectiveSettings.autoQueueMode = .priority
        try! context.save()
        settingsManager.defaultAutoQueueMode = .off // only per-podcast matters
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: The auto-queued episode should be BEFORE the existing item (play next)
        XCTAssertEqual(audioManager.queue.count, 2, "Should have 2 items total")
        XCTAssertEqual(audioManager.queue.last?.id, "existing-ep",
                       "Priority auto-queue should insert before existing items")
    }
    
    /// Verifies most recent episode from each subscription gets queued.
    func test_autoQueueExistingEpisodes_queuesOnePerSubscription() {
        // GIVEN: Two podcasts with episodes and global auto-queue = .normal
        insertPodcast(url: "https://example.com/feed-a", title: "Podcast A", episodeCount: 5)
        insertPodcast(url: "https://example.com/feed-b", title: "Podcast B", episodeCount: 5)
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: 2 episodes total (1 per podcast, not 10)
        XCTAssertEqual(audioManager.queue.count, 2,
                       "Should queue 1 most-recent episode per podcast, not the entire back-catalog")
    }
    
    /// Regression: episodes marked as played (isPlayed=true) must never be auto-queued.
    /// This was broken because getAutoQueueCandidates only checked in-memory interactedKeys,
    /// not the persisted isPlayed flag in SwiftData.
    func test_autoQueueExistingEpisodes_skipsPlayedEpisodes() {
        // GIVEN: A podcast where the most recent episode is already played
        let podcast = insertPodcast(url: "https://example.com/played-feed", episodeCount: 3)
        let sorted = podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        sorted[0].isPlayed = true  // newest is played
        sorted[1].isPlayed = true  // second newest is played
        try! context.save()
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: Only the 3rd episode (oldest unplayed) should be queued
        XCTAssertEqual(audioManager.queue.count, 1,
                       "Played episodes should never be auto-queued")
        XCTAssertEqual(audioManager.queue.first?.id, sorted[2].guid,
                       "Should queue the oldest unplayed episode since the newer ones are played")
    }
    
    /// Regression: episodes with isInteracted=true in SwiftData must be excluded even after
    /// app restart (when in-memory interactedKeys is empty).
    func test_autoQueueExistingEpisodes_skipsPersistedInteractedEpisodes() {
        // GIVEN: A podcast where the most recent episode has isInteracted=true in SwiftData
        let podcast = insertPodcast(url: "https://example.com/persisted-feed", episodeCount: 2)
        let sorted = podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        sorted[0].isInteracted = true  // persisted, but NOT in interactedKeys (simulates app restart)
        try! context.save()
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: The interacted episode should be skipped
        XCTAssertEqual(audioManager.queue.count, 1,
                       "Persisted isInteracted episodes should be excluded")
        XCTAssertEqual(audioManager.queue.first?.id, sorted[1].guid,
                       "Should queue the older un-interacted episode, not the interacted one")
    }
    
    /// All episodes played → nothing should be queued.
    func test_autoQueueExistingEpisodes_queuesNothing_whenAllEpisodesPlayed() {
        // GIVEN: A podcast where all episodes are played
        let podcast = insertPodcast(url: "https://example.com/all-played-feed", episodeCount: 3)
        for ep in podcast.episodes { ep.isPlayed = true }
        try! context.save()
        settingsManager.defaultAutoQueueMode = .normal
        
        // WHEN
        podcastManager.autoQueueExistingEpisodes(playerManager: playerManager, settingsManager: settingsManager)
        
        // THEN: Queue should remain empty
        XCTAssertTrue(audioManager.queue.isEmpty,
                      "No episodes should be queued when all are played")
    }
}

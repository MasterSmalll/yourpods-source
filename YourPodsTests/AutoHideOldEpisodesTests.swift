import XCTest
import SwiftData
@testable import YourPods

// MARK: - Auto-Hide Old Episodes Tests

/// Tests for auto-hiding old episodes when subscribing to a new podcast.
///
/// When the setting is enabled, `autoHideOldEpisodes(for:keepRecent:)` should
/// hide all but the N most recent episodes (by pubDate) using the existing
/// hidden-episode infrastructure (`setHidden(guid:hidden:true)`).
@MainActor
final class AutoHideOldEpisodesTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    
    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
        UserDefaults.standard.removeObject(forKey: "autoHideOldEpisodes")
        UserDefaults.standard.removeObject(forKey: "autoHideKeepRecentCount")
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)
    }
    
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
        UserDefaults.standard.removeObject(forKey: "autoHideOldEpisodes")
        UserDefaults.standard.removeObject(forKey: "autoHideKeepRecentCount")
        podcastManager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }
    
    /// Helper: create a podcast with N episodes, each with a pubDate offset by days.
    /// Episode 0 is the newest, episode N-1 is the oldest.
    private func makePodcast(episodeCount: Int, includeNilPubDate: Bool = false) -> (Podcast, [Episode]) {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        var episodes: [Episode] = []
        
        for i in 0..<episodeCount {
            let ep = Episode(guid: "ep-\(i)", title: "Episode \(i)")
            if includeNilPubDate && i == episodeCount - 1 {
                ep.pubDate = nil
            } else {
                // Newest first: ep-0 is today, ep-1 is yesterday, etc.
                ep.pubDate = Calendar.current.date(byAdding: .day, value: -i, to: Date())
            }
            ep.podcast = podcast
            episodes.append(ep)
        }
        podcast.episodes = episodes
        
        context.insert(podcast)
        for ep in episodes { context.insert(ep) }
        
        // Reload subscriptions so PodcastManager and its episodeActionSync see this podcast
        podcastManager.subscriptions = [podcast]
        
        return (podcast, episodes)
    }
    
    // MARK: - Test 1: Hides all but keepRecent most recent
    
    /// With 10 episodes and keepRecent=3, the 7 oldest must be hidden
    /// and the 3 newest must remain visible.
    func test_autoHideOnSubscribe_hidesAllButKeepRecentCount() {
        let (podcast, episodes) = makePodcast(episodeCount: 10)
        
        podcastManager.autoHideOldEpisodes(for: podcast, keepRecent: 3)
        
        // Episodes 0, 1, 2 are the 3 newest — should NOT be hidden
        for i in 0..<3 {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episodes[i].guid),
                           "Episode \(i) (newest) should NOT be hidden")
        }
        
        // Episodes 3..9 are older — should be hidden
        for i in 3..<10 {
            XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[i].guid),
                          "Episode \(i) (older) should be hidden")
        }
    }
    
    // MARK: - Test 2: Custom keep count
    
    /// With 10 episodes and keepRecent=5, only 5 should be hidden.
    func test_autoHideOnSubscribe_customKeepCount() {
        let (podcast, episodes) = makePodcast(episodeCount: 10)
        
        podcastManager.autoHideOldEpisodes(for: podcast, keepRecent: 5)
        
        // 5 newest should be visible
        for i in 0..<5 {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episodes[i].guid),
                           "Episode \(i) (newest 5) should NOT be hidden")
        }
        
        // 5 oldest should be hidden
        for i in 5..<10 {
            XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[i].guid),
                          "Episode \(i) (older) should be hidden")
        }
    }
    
    // MARK: - Test 3: Few episodes — nothing to hide
    
    /// With ≤ keepRecent episodes, none should be hidden.
    func test_autoHideOnSubscribe_fewEpisodes_hidesNothing() {
        let (podcast, episodes) = makePodcast(episodeCount: 2)
        
        podcastManager.autoHideOldEpisodes(for: podcast, keepRecent: 3)
        
        for ep in episodes {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: ep.guid),
                           "\(ep.guid) should NOT be hidden when episode count ≤ keepRecent")
        }
    }
    
    // MARK: - Test 4: Setting disabled — nothing hidden
    
    /// When autoHideOldEpisodes setting is false, the guard in addSubscription
    /// prevents the method from being called.
    func test_autoHideOnSubscribe_settingDisabled_hidesNothing() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "autoHideOldEpisodes")
        
        let settingsMgr = SettingsManager(defaults: defaults)
        XCTAssertFalse(settingsMgr.autoHideOldEpisodes,
                       "Setting must be disabled for this test")
        
        let (podcast, episodes) = makePodcast(episodeCount: 10)
        
        // Simulate addSubscription guard: setting is off → don't call autoHideOldEpisodes
        if settingsMgr.autoHideOldEpisodes {
            podcastManager.autoHideOldEpisodes(for: podcast, keepRecent: 3)
        }
        
        for ep in episodes {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: ep.guid),
                           "\(ep.guid) should NOT be hidden when setting is disabled")
        }
    }
    
    // MARK: - Test 5: Episodes with nil pubDate are treated as oldest
    
    /// Episodes without a pubDate should sort to the end (oldest) and be hidden first.
    func test_autoHideOnSubscribe_nilPubDate_treatedAsOldest() {
        let (podcast, episodes) = makePodcast(episodeCount: 5, includeNilPubDate: true)
        
        podcastManager.autoHideOldEpisodes(for: podcast, keepRecent: 3)
        
        // Episodes 0, 1, 2 are newest with dates — should NOT be hidden
        for i in 0..<3 {
            XCTAssertFalse(podcastManager.episodeActionSync.isHidden(guid: episodes[i].guid),
                           "Episode \(i) (newest with date) should NOT be hidden")
        }
        
        // Episode 4 has nil pubDate — should be treated as oldest and hidden
        XCTAssertTrue(podcastManager.episodeActionSync.isHidden(guid: episodes[4].guid),
                      "Episode with nil pubDate should be treated as oldest and hidden")
    }
    
    // MARK: - Test 6: Hidden episodes have isPlayed = true
    
    /// Verify that auto-hidden episodes have isPlayed set to true
    /// (contract from setHidden).
    func test_autoHideOnSubscribe_hiddenEpisodesHaveIsPlayedTrue() {
        let (podcast, episodes) = makePodcast(episodeCount: 5)
        
        // Precondition: all episodes start as unplayed
        for ep in episodes {
            XCTAssertFalse(ep.isPlayed, "Precondition: \(ep.guid) should start as unplayed")
        }
        
        podcastManager.autoHideOldEpisodes(for: podcast, keepRecent: 3)
        
        // The 3 newest should remain unplayed
        for i in 0..<3 {
            XCTAssertFalse(episodes[i].isPlayed,
                           "Episode \(i) (newest) should remain unplayed")
        }
        
        // The 2 hidden episodes should be marked as played
        for i in 3..<5 {
            XCTAssertTrue(episodes[i].isPlayed,
                          "Episode \(i) (hidden) should have isPlayed = true")
        }
    }
}

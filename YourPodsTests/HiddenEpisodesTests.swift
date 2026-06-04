import XCTest
import SwiftData
@testable import YourPods

// MARK: - Hidden Episodes Tests (TDD Phase 1: Red)

/// Tests for the Hidden Episodes feature (Build 198).
///
/// Hidden episodes are treated as played (`isPlayed = true`) for filtering
/// and badge counts. A separate `hiddenEpisodeGuids` set tracks which episodes
/// were hidden (vs genuinely played) for the "Show Hidden" toggle and unhide.
///
/// Phase 1 (Red): All tests must FAIL with assertion errors until the
/// implementation is written in Phase 2 (Green).
final class HiddenEpisodesModelTests: XCTestCase {
    
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    // MARK: - ProPlaybackState decoding
    
    /// Server sends hidden: true on a playback state — must be decoded.
    func test_proPlaybackState_decodesHiddenTrue() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "episodeGuid": "guid-1",
            "positionSec": 300,
            "durationSec": 3600,
            "title": "Episode 1",
            "podcastTitle": "Pod",
            "artUrl": null,
            "updatedAt": null,
            "nowPlaying": false,
            "completed": false,
            "hidden": true
        }
        """.data(using: .utf8)!
        
        let state = try decoder.decode(ProPlaybackState.self, from: json)
        XCTAssertEqual(state.hidden, true,
                       "hidden: true must be decoded from server response")
    }
    
    /// Server sends hidden: false — must be decoded as false (not nil).
    func test_proPlaybackState_decodesHiddenFalse() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "episodeGuid": "guid-1",
            "positionSec": 0,
            "durationSec": 3600,
            "title": null,
            "podcastTitle": null,
            "artUrl": null,
            "updatedAt": null,
            "nowPlaying": null,
            "completed": null,
            "hidden": false
        }
        """.data(using: .utf8)!
        
        let state = try decoder.decode(ProPlaybackState.self, from: json)
        XCTAssertEqual(state.hidden, false,
                       "hidden: false must be decoded explicitly, not as nil")
    }
    
    /// Older server responses without the hidden field — must default to nil.
    func test_proPlaybackState_missingHidden_defaultsToNil() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "episodeUrl": "https://example.com/ep1.mp3",
            "episodeGuid": "guid-1",
            "positionSec": 120,
            "durationSec": 3600,
            "title": null,
            "podcastTitle": null,
            "artUrl": null,
            "updatedAt": null,
            "nowPlaying": true,
            "completed": null
        }
        """.data(using: .utf8)!
        
        let state = try decoder.decode(ProPlaybackState.self, from: json)
        XCTAssertNil(state.hidden,
                     "Missing hidden field must decode as nil for backward compat")
    }
    
    // MARK: - ProHideEpisodeRequest encoding
    
    /// Single hide request encodes the correct shape.
    func test_proHideEpisodeRequest_encodesSingleCorrectly() throws {
        let request = ProHideEpisodeRequest(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://example.com/feed"
        )
        
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        XCTAssertEqual(json?["episodeUrl"] as? String, "https://example.com/ep1.mp3")
        XCTAssertEqual(json?["podcastUrl"] as? String, "https://example.com/feed")
    }
    
    /// Batch hide request encodes as an array.
    func test_proHideEpisodeRequest_encodesBatchCorrectly() throws {
        let requests = [
            ProHideEpisodeRequest(episodeUrl: "https://example.com/ep1.mp3", podcastUrl: "https://example.com/feed"),
            ProHideEpisodeRequest(episodeUrl: "https://example.com/ep2.mp3", podcastUrl: "https://example.com/feed")
        ]
        
        let data = try encoder.encode(requests)
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        
        XCTAssertEqual(json?.count, 2, "Batch should encode as array of 2 items")
        XCTAssertEqual(json?[0]["episodeUrl"] as? String, "https://example.com/ep1.mp3")
        XCTAssertEqual(json?[1]["episodeUrl"] as? String, "https://example.com/ep2.mp3")
    }
    
    // MARK: - ProHideResponse decoding
    
    func test_proHideResponse_decodesFromAPIShape() throws {
        let json = """
        {"message": "hidden", "count": 2}
        """.data(using: .utf8)!
        
        let response = try decoder.decode(ProHideResponse.self, from: json)
        XCTAssertEqual(response.message, "hidden")
        XCTAssertEqual(response.count, 2)
    }
}

// MARK: - Hidden State Store Tests

/// Tests for the hidden episode tracking in EpisodeActionSyncService.
@MainActor
final class HiddenEpisodeStoreTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: EpisodeActionSyncService!
    
    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
    }
    
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        UserDefaults.standard.removeObject(forKey: "episodeActionMap")
        service = nil
        context = nil
        container = nil
        try await super.tearDown()
    }
    
    /// After setHidden(true), isHidden must return true.
    func test_isHidden_returnsTrueAfterSetHiddenTrue() {
        service.setHidden(guid: "ep-1", hidden: true)
        XCTAssertTrue(service.isHidden(guid: "ep-1"),
                      "isHidden must return true after setHidden(true)")
    }
    
    /// After setHidden(false), isHidden must return false (unhide).
    func test_isHidden_returnsFalseAfterSetHiddenFalse() {
        service.setHidden(guid: "ep-1", hidden: true)
        service.setHidden(guid: "ep-1", hidden: false)
        XCTAssertFalse(service.isHidden(guid: "ep-1"),
                       "isHidden must return false after unhiding")
    }
    
    /// Hidden state must survive persist + load cycle.
    func test_hiddenState_persistsAcrossLoadSaveCycles() {
        service.setHidden(guid: "ep-1", hidden: true)
        service.setHidden(guid: "ep-2", hidden: true)
        service.persistHiddenGuids()
        
        // Create a new service instance and load
        let service2 = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        service2.loadHiddenGuids()
        
        XCTAssertTrue(service2.isHidden(guid: "ep-1"),
                      "Hidden state must survive persist + load")
        XCTAssertTrue(service2.isHidden(guid: "ep-2"),
                      "Hidden state must survive persist + load")
        XCTAssertFalse(service2.isHidden(guid: "ep-3"),
                       "Non-hidden episode must remain non-hidden")
    }
    
    /// hiddenGuids(for:) returns only GUIDs belonging to that podcast.
    func test_hiddenGuids_forPodcast_returnsCorrectGuids() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let ep1 = Episode(guid: "ep-1", title: "Episode 1")
        let ep2 = Episode(guid: "ep-2", title: "Episode 2")
        let ep3 = Episode(guid: "ep-3", title: "Episode 3")
        ep1.podcast = podcast
        ep2.podcast = podcast
        ep3.podcast = podcast
        podcast.episodes = [ep1, ep2, ep3]
        
        service.setHidden(guid: "ep-1", hidden: true)
        service.setHidden(guid: "ep-3", hidden: true)
        // ep-2 is not hidden
        
        let guids = service.hiddenGuids(for: podcast)
        XCTAssertEqual(Set(guids), Set(["ep-1", "ep-3"]),
                       "Should return only the hidden GUIDs for this podcast")
    }
    
    /// Hiding sets episode.isPlayed = true.
    func test_hiding_setsIsPlayedTrue() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1")
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        // Inject the podcast so the service can find the episode
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        XCTAssertFalse(episode.isPlayed, "Precondition: episode starts as unplayed")
        
        svc.setHidden(guid: "ep-1", hidden: true)
        
        XCTAssertTrue(episode.isPlayed,
                      "Hiding must set isPlayed = true")
    }
    
    /// Unhiding sets episode.isPlayed = false.
    func test_unhiding_setsIsPlayedFalse() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1")
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        svc.setHidden(guid: "ep-1", hidden: true)
        XCTAssertTrue(episode.isPlayed, "Precondition: hidden episode is played")
        
        svc.setHidden(guid: "ep-1", hidden: false)
        
        XCTAssertFalse(episode.isPlayed,
                       "Unhiding must set isPlayed = false")
    }
    
    /// Badge count excludes hidden episodes via the existing isPlayed check.
    /// This is a verification test — no new code needed, just proves the contract.
    func test_badgeCount_excludesHiddenEpisodes() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let ep1 = Episode(guid: "ep-1", title: "Episode 1")
        let ep2 = Episode(guid: "ep-2", title: "Episode 2")
        let ep3 = Episode(guid: "ep-3", title: "Episode 3")
        ep1.podcast = podcast
        ep2.podcast = podcast
        ep3.podcast = podcast
        podcast.episodes = [ep1, ep2, ep3]
        context.insert(podcast)
        context.insert(ep1)
        context.insert(ep2)
        context.insert(ep3)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        // Hide ep-1 (should set isPlayed = true)
        svc.setHidden(guid: "ep-1", hidden: true)
        
        // Count unplayed via the same logic BadgeService uses
        var unplayed = 0
        for ep in podcast.episodes {
            if !ep.isPlayed { unplayed += 1 }
        }
        
        XCTAssertEqual(unplayed, 2,
                       "Badge count must exclude hidden episodes (3 total - 1 hidden = 2 unplayed)")
    }
    
    // MARK: - Edge Cases
    
    /// Playing a hidden episode should not change the hidden flag.
    func test_playingHiddenEpisode_doesNotChangeHiddenFlag() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1")
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        svc.setHidden(guid: "ep-1", hidden: true)
        
        // Simulate playback progress (doesn't touch hidden set)
        episode.listenedSeconds = 300
        
        XCTAssertTrue(svc.isHidden(guid: "ep-1"),
                      "Playing a hidden episode must not change the hidden flag")
    }
    
    /// Delta sync: server sends hidden: true → local episode must become
    /// isPlayed = true and be added to hidden set.
    func test_deltaSyncHiddenTrue_setsIsPlayedAndAddsToSet() throws {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1", audioUrl: "https://example.com/ep1.mp3")
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        // Simulate delta sync delivering hidden state
        svc.setHidden(guid: "ep-1", hidden: true)
        
        XCTAssertTrue(episode.isPlayed,
                      "Delta sync hidden: true must set isPlayed = true")
        XCTAssertTrue(svc.isHidden(guid: "ep-1"),
                      "Delta sync hidden: true must add to hidden set")
    }
    
    // MARK: - Played Reversal Regression Tests (Bug: setHidden clobbers isPlayed)
    
    /// Calling setHidden(hidden: false) for a NEVER-HIDDEN, genuinely-played
    /// episode must NOT reset isPlayed to false. This is the root cause of
    /// "mark as played reverses once refreshed" — the sync pulls hidden: false
    /// for every non-hidden episode and setHidden blindly sets isPlayed = false.
    func test_setHiddenFalse_doesNotResetIsPlayed_forNeverHiddenEpisode() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1")
        episode.podcast = podcast
        episode.isPlayed = true  // Genuinely played
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        // Simulate sync delivering hidden: false for a non-hidden episode
        svc.setHidden(guid: "ep-1", hidden: false)
        
        XCTAssertTrue(episode.isPlayed,
                      "setHidden(false) must NOT reset isPlayed for a never-hidden, genuinely-played episode")
    }
    
    /// Calling setHidden(hidden: false) for a PREVIOUSLY-HIDDEN episode
    /// must correctly reset isPlayed to false (genuine unhide action).
    func test_setHiddenFalse_resetsIsPlayed_forPreviouslyHiddenEpisode() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1")
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        // Hide first (episode enters hiddenEpisodeGuids)
        svc.setHidden(guid: "ep-1", hidden: true)
        XCTAssertTrue(episode.isPlayed, "Precondition: hiding sets isPlayed = true")
        
        // Then unhide (should reset isPlayed = false)
        svc.setHidden(guid: "ep-1", hidden: false)
        
        XCTAssertFalse(episode.isPlayed,
                       "Unhiding a previously-hidden episode must set isPlayed = false")
    }
    
    /// Hiding an already-played episode sets isPlayed = true (no-op on played
    /// state), and adds it to the hidden set.
    func test_setHiddenTrue_setsIsPlayed_forUnplayedEpisode() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: "ep-1", title: "Episode 1")
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        
        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )
        
        XCTAssertFalse(episode.isPlayed, "Precondition: episode is unplayed")
        
        svc.setHidden(guid: "ep-1", hidden: true)
        
        XCTAssertTrue(episode.isPlayed,
                      "Hiding must set isPlayed = true")
        XCTAssertTrue(svc.isHidden(guid: "ep-1"),
                      "Hiding must add to hidden set")
    }
}

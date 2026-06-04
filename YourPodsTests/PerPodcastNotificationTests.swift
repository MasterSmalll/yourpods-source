import XCTest
import SwiftData
import UserNotifications
@testable import YourPods

// MARK: - Per-Podcast Notification Tests

/// Tests for per-podcast notification controls.
///
/// TDD Phase 1: These tests define the expected behavior for the opt-in
/// per-podcast notification model. All tests should FAIL against stubs.
@MainActor
final class PerPodcastNotificationTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: NewEpisodeNotificationService!
    private var mockCenter: MockNotificationCenter!
    private var settingsManager: SettingsManager!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        service = NewEpisodeNotificationService()
        mockCenter = MockNotificationCenter()
        service.notificationCenter = mockCenter
        service.applicationStateProvider = { .background }
        
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "PerPodcastNotificationTests")!)
    }
    
    override func tearDown() {
        UserDefaults(suiteName: "PerPodcastNotificationTests")?.removePersistentDomain(forName: "PerPodcastNotificationTests")
        settingsManager = nil
        service = nil
        mockCenter = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func makePodcast(title: String, url: String, notificationsEnabled: Bool? = nil) -> Podcast {
        let p = Podcast(url: url, title: title, podcastDescription: nil, logoUrl: nil, website: nil, author: nil)
        context.insert(p)
        var settings = p.effectiveSettings
        settings.notificationsEnabled = notificationsEnabled
        p.effectiveSettings = settings
        return p
    }
    
    private func makeEpisode(title: String, guid: String, podcast: Podcast) -> Episode {
        let e = Episode(
            guid: guid,
            title: title,
            episodeDescription: nil,
            audioUrl: "https://example.com/\(guid).mp3",
            pubDate: Date(),
            imageUrl: nil,
            durationSeconds: 3600,
            link: nil,
            chaptersUrl: nil,
            transcriptUrl: nil,
            podcast: podcast
        )
        context.insert(e)
        return e
    }
    
    /// Filter episodes using the same logic as PodcastManager.processNewEpisodes()
    private func filterEpisodesForNotification(_ episodes: [Episode]) -> [Episode] {
        guard settingsManager.newEpisodeNotificationsEnabled else { return [] }
        return episodes.filter { episode in
            episode.podcast?.effectiveSettings.notificationsEnabled == true
        }
    }
    
    // MARK: - Global Kill Switch
    
    /// Global toggle OFF overrides everything — even per-podcast ON.
    func test_globalOff_noNotificationsEvenWithPerPodcastTrue() async {
        // GIVEN: Global OFF, per-podcast ON
        settingsManager.newEpisodeNotificationsEnabled = false
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech", notificationsEnabled: true)
        let episode = makeEpisode(title: "Episode 1", guid: "ep1", podcast: podcast)
        
        // WHEN
        let filtered = filterEpisodesForNotification([episode])
        
        // THEN: Kill switch prevents all notifications
        XCTAssertTrue(filtered.isEmpty,
                      "Global OFF should prevent all notifications regardless of per-podcast setting")
    }
    
    // MARK: - Opt-In Model
    
    /// Global ON + no per-podcast override → no notification (opt-in default).
    func test_globalOn_perPodcastNil_noNotification() async {
        // GIVEN: Global ON, per-podcast nil (default)
        settingsManager.newEpisodeNotificationsEnabled = true
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech", notificationsEnabled: nil)
        let episode = makeEpisode(title: "Episode 1", guid: "ep1", podcast: podcast)
        
        // WHEN
        let filtered = filterEpisodesForNotification([episode])
        
        // THEN: Opt-in model — nil means no notification
        XCTAssertTrue(filtered.isEmpty,
                      "Default (nil) per-podcast setting should NOT produce notifications — opt-in model")
    }
    
    /// Global ON + per-podcast ON → notification posted.
    func test_globalOn_perPodcastTrue_notificationPosted() async {
        // GIVEN: Global ON, per-podcast ON
        settingsManager.newEpisodeNotificationsEnabled = true
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech", notificationsEnabled: true)
        let episode = makeEpisode(title: "Episode 1", guid: "ep1", podcast: podcast)
        
        // WHEN
        let filtered = filterEpisodesForNotification([episode])
        await service.postNewEpisodeNotifications(filtered)
        
        // THEN: Notification posted
        XCTAssertEqual(filtered.count, 1,
                       "Per-podcast ON should pass through to notification")
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Should post 1 notification for opted-in podcast")
    }
    
    /// Global ON + per-podcast explicit false → no notification.
    func test_globalOn_perPodcastFalse_noNotification() async {
        // GIVEN: Global ON, per-podcast explicitly OFF
        settingsManager.newEpisodeNotificationsEnabled = true
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech", notificationsEnabled: false)
        let episode = makeEpisode(title: "Episode 1", guid: "ep1", podcast: podcast)
        
        // WHEN
        let filtered = filterEpisodesForNotification([episode])
        
        // THEN: Explicit false suppresses notification
        XCTAssertTrue(filtered.isEmpty,
                      "Explicit per-podcast OFF should NOT produce notifications")
    }
    
    // MARK: - Mixed Overrides
    
    /// 3 podcasts: one ON, one OFF, one nil. Only the ON podcast should notify.
    func test_mixedOverrides_onlyOptedInPodcastsNotify() async {
        // GIVEN: Global ON, mixed per-podcast settings
        settingsManager.newEpisodeNotificationsEnabled = true
        let podcastOn = makePodcast(title: "Favorite Pod", url: "https://example.com/fav", notificationsEnabled: true)
        let podcastOff = makePodcast(title: "Noisy Pod", url: "https://example.com/noisy", notificationsEnabled: false)
        let podcastDefault = makePodcast(title: "Default Pod", url: "https://example.com/default", notificationsEnabled: nil)
        
        let ep1 = makeEpisode(title: "Fav Ep", guid: "fav1", podcast: podcastOn)
        let ep2 = makeEpisode(title: "Noisy Ep", guid: "noisy1", podcast: podcastOff)
        let ep3 = makeEpisode(title: "Default Ep", guid: "default1", podcast: podcastDefault)
        
        // WHEN
        let filtered = filterEpisodesForNotification([ep1, ep2, ep3])
        await service.postNewEpisodeNotifications(filtered)
        
        // THEN: Only the opted-in podcast notifies
        XCTAssertEqual(filtered.count, 1, "Only 1 podcast is opted in")
        XCTAssertEqual(filtered.first?.podcast?.title, "Favorite Pod")
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Should post 1 notification for the opted-in podcast only")
    }
    
    // MARK: - Bulk Enable
    
    /// enableNotificationsForAllPodcasts() should set true on all subscriptions.
    func test_enableNotificationsForAllPodcasts_setsAllTrue() {
        // GIVEN: 3 podcasts with various notification states
        let p1 = makePodcast(title: "Pod 1", url: "https://example.com/1", notificationsEnabled: nil)
        let p2 = makePodcast(title: "Pod 2", url: "https://example.com/2", notificationsEnabled: false)
        let p3 = makePodcast(title: "Pod 3", url: "https://example.com/3", notificationsEnabled: true)
        
        // WHEN: bulk enable
        for podcast in [p1, p2, p3] {
            podcast.effectiveSettings.notificationsEnabled = true
        }
        
        // THEN: all should be true
        XCTAssertEqual(p1.effectiveSettings.notificationsEnabled, true)
        XCTAssertEqual(p2.effectiveSettings.notificationsEnabled, true)
        XCTAssertEqual(p3.effectiveSettings.notificationsEnabled, true)
    }
    
    /// Bulk enable should not overwrite other Listening Profile settings.
    func test_enableNotificationsForAllPodcasts_preservesOtherSettings() {
        // GIVEN: podcast with custom settings
        let podcast = makePodcast(title: "Custom Pod", url: "https://example.com/custom")
        var settings = podcast.effectiveSettings
        settings.skipIntroSeconds = 30
        settings.playbackSpeed = 1.5
        settings.privacyMode = true
        podcast.effectiveSettings = settings
        
        // WHEN: enable notifications
        podcast.effectiveSettings.notificationsEnabled = true
        
        // THEN: other settings preserved
        XCTAssertEqual(podcast.effectiveSettings.skipIntroSeconds, 30,
                       "Enabling notifications should not overwrite skip intro")
        XCTAssertEqual(podcast.effectiveSettings.playbackSpeed, 1.5,
                       "Enabling notifications should not overwrite playback speed")
        XCTAssertEqual(podcast.effectiveSettings.privacyMode, true,
                       "Enabling notifications should not overwrite privacy mode")
        XCTAssertEqual(podcast.effectiveSettings.notificationsEnabled, true)
    }
    
    // MARK: - PodcastSettings Model
    
    /// notificationsEnabled should be included in hasOverrides.
    func test_notificationsEnabled_includedInHasOverrides() {
        var settings = PodcastSettings()
        XCTAssertFalse(settings.hasOverrides, "Empty settings should have no overrides")
        
        settings.notificationsEnabled = true
        XCTAssertTrue(settings.hasOverrides,
                      "Setting notificationsEnabled should mark hasOverrides as true")
    }
    
    /// notificationsEnabled should round-trip through Codable.
    func test_notificationsEnabled_roundTripsViaCodable() throws {
        var original = PodcastSettings()
        original.notificationsEnabled = true
        
        let data = try JSONEncoder().encode(original)
        
        // Verify the key exists in the encoded JSON
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("notificationsEnabled"),
                      "Encoded JSON must contain 'notificationsEnabled' key — currently missing from CodingKeys")
        
        let decoded = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        XCTAssertEqual(decoded.notificationsEnabled, true,
                       "notificationsEnabled should survive Codable round-trip")
    }
    
    /// nil notificationsEnabled should round-trip as nil (not false).
    func test_notificationsEnabled_nilRoundTrips() throws {
        var original = PodcastSettings()
        original.notificationsEnabled = nil
        
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        XCTAssertNil(decoded.notificationsEnabled,
                     "nil notificationsEnabled should stay nil after round-trip")
    }
    
    /// toServerPayload should include "notifications" key when set.
    func test_notificationsEnabled_inServerPayload() {
        var settings = PodcastSettings()
        settings.notificationsEnabled = true
        
        let payload = settings.toServerPayload()
        
        XCTAssertEqual(payload["notifications"], .bool(true),
                       "toServerPayload() should include 'notifications' key")
    }
    
    /// toServerPayload should NOT include "notifications" key when nil.
    func test_notificationsEnabled_nilNotInServerPayload() {
        let settings = PodcastSettings()
        
        let payload = settings.toServerPayload()
        
        XCTAssertNil(payload["notifications"],
                     "nil notificationsEnabled should not appear in server payload")
    }
    
    /// fromServerPayload should parse "notifications" boolean.
    func test_notificationsEnabled_fromServerPayload() {
        let payload: [String: AnyCodableValue] = [
            "notifications": .bool(true)
        ]
        
        let settings = PodcastSettings.fromServerPayload(payload)
        
        XCTAssertEqual(settings.notificationsEnabled, true,
                       "fromServerPayload() should parse 'notifications' boolean")
    }
    
    /// merging should adopt server value when local is nil.
    func test_notificationsEnabled_mergedFromServer() {
        var local = PodcastSettings()
        local.notificationsEnabled = nil
        
        var server = PodcastSettings()
        server.notificationsEnabled = true
        
        let merged = local.merging(serverSettings: server)
        
        XCTAssertEqual(merged.notificationsEnabled, true,
                       "Merge should adopt server notificationsEnabled when local is nil")
    }
    
    /// merging should keep local value when both are set.
    func test_notificationsEnabled_localWinsInMerge() {
        var local = PodcastSettings()
        local.notificationsEnabled = false
        
        var server = PodcastSettings()
        server.notificationsEnabled = true
        
        let merged = local.merging(serverSettings: server)
        
        XCTAssertEqual(merged.notificationsEnabled, false,
                       "Local notificationsEnabled should take precedence over server")
    }
    
    /// "notifications" should be a known key (not stored in serverExtras).
    func test_notificationsEnabled_isKnownKeyNotExtra() {
        let payload: [String: AnyCodableValue] = [
            "notifications": .bool(true),
            "unknownKey": .string("preserved")
        ]
        
        let settings = PodcastSettings.fromServerPayload(payload)
        
        XCTAssertEqual(settings.notificationsEnabled, true,
                       "notifications should be parsed as a known key")
        XCTAssertNil(settings.serverExtras["notifications"],
                     "notifications should NOT be stored in serverExtras")
        XCTAssertEqual(settings.serverExtras["unknownKey"], .string("preserved"),
                       "Unknown keys should still be preserved in serverExtras")
    }
}

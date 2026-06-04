import XCTest
import SwiftData
import UserNotifications
@testable import YourPods

// MARK: - Mock Notification Center

/// Records all notification requests for assertion without posting to the real system.
final class MockNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    private(set) var addedRequests: [UNNotificationRequest] = []
    var authorizationGranted = true
    var authorizationRequested = false
    
    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }
    
    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        return addedRequests
    }
    
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequested = true
        return authorizationGranted
    }
    
    func isAuthorized() async -> Bool {
        return authorizationGranted
    }
    
    func reset() {
        addedRequests.removeAll()
        authorizationRequested = false
    }
}

// MARK: - Tests

/// Tests for `NewEpisodeNotificationService`.
///
/// TDD Phase 1: These tests define the expected notification behavior.
/// All tests should FAIL against the current stubs.
@MainActor
final class NewEpisodeNotificationTests: XCTestCase {
    
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
        // Default: app is in background (notifications should post)
        service.applicationStateProvider = { .background }
        
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "NewEpisodeNotificationTests")!)
    }
    
    override func tearDown() {
        UserDefaults(suiteName: "NewEpisodeNotificationTests")?.removePersistentDomain(forName: "NewEpisodeNotificationTests")
        settingsManager = nil
        service = nil
        mockCenter = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func makePodcast(title: String, url: String) -> Podcast {
        let p = Podcast(url: url, title: title, podcastDescription: nil, logoUrl: nil, website: nil, author: nil)
        context.insert(p)
        return p
    }
    
    private func makeEpisode(title: String, guid: String, podcast: Podcast, pubDate: Date = Date()) -> Episode {
        let e = Episode(
            guid: guid,
            title: title,
            episodeDescription: nil,
            audioUrl: "https://example.com/\(guid).mp3",
            pubDate: pubDate,
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
    
    // MARK: - Notification Posting
    
    /// When the service receives new episodes and the app is in the background,
    /// it must post one notification per podcast.
    func test_postsNotificationsWhenNewEpisodesFound() async {
        // GIVEN: 1 new episode from 1 podcast, app in background
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let episode = makeEpisode(title: "Episode 42", guid: "ep42", podcast: podcast)
        
        // WHEN
        await service.postNewEpisodeNotifications([episode])
        
        // THEN: 1 notification posted
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Should post 1 notification for 1 podcast with new episodes")
    }
    
    /// No notifications when the episode list is empty.
    func test_noNotificationsForEmptyEpisodes() async {
        // WHEN
        await service.postNewEpisodeNotifications([])
        
        // THEN
        XCTAssertTrue(mockCenter.addedRequests.isEmpty,
                      "Should not post any notification for an empty episode list")
    }
    
    // MARK: - Foreground Suppression
    
    /// No notifications when the app is in the foreground for freshly published episodes.
    func test_noNotificationsInForeground_freshEpisodes() async {
        // GIVEN: App is in the foreground, episode published just now
        service.applicationStateProvider = { .active }
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let episode = makeEpisode(title: "Episode 42", guid: "ep42", podcast: podcast, pubDate: Date())
        
        // WHEN
        await service.postNewEpisodeNotifications([episode])
        
        // THEN
        XCTAssertTrue(mockCenter.addedRequests.isEmpty,
                       "Should NOT post notifications for fresh episodes when the app is in the foreground")
    }
    
    /// Stale episodes (published >30 min ago) SHOULD trigger notifications even in foreground.
    func test_foreground_staleEpisode_postsNotification() async {
        // GIVEN: App is in the foreground, episode published 2 hours ago
        service.applicationStateProvider = { .active }
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let staleDate = Date().addingTimeInterval(-2 * 60 * 60) // 2 hours ago
        let episode = makeEpisode(title: "Missed Episode", guid: "stale1", podcast: podcast, pubDate: staleDate)
        
        // WHEN
        await service.postNewEpisodeNotifications([episode])
        
        // THEN: Should notify — user missed this episode
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Should post notification for stale episodes even when app is in the foreground")
    }
    
    /// Episodes at or near the threshold boundary should be suppressed (not stale enough).
    func test_foreground_episodeAtThreshold_suppressed() async {
        // GIVEN: App is in the foreground, episode published slightly under threshold
        // (use threshold - 10s to avoid timing precision issues from test execution)
        service.applicationStateProvider = { .active }
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let borderlineDate = Date().addingTimeInterval(-(NewEpisodeNotificationService.foregroundStaleThreshold - 10))
        let episode = makeEpisode(title: "Borderline Episode", guid: "border1", podcast: podcast, pubDate: borderlineDate)
        
        // WHEN
        await service.postNewEpisodeNotifications([episode])
        
        // THEN: At exactly the threshold, should suppress (not "more than" threshold)
        XCTAssertTrue(mockCenter.addedRequests.isEmpty,
                      "Episode at exactly the threshold boundary should still be suppressed")
    }
    
    /// Mixed batch: only stale episodes should notify in foreground.
    func test_foreground_mixedBatch_onlyStaleEpisodesNotify() async {
        // GIVEN: App is in the foreground
        service.applicationStateProvider = { .active }
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let staleDate = Date().addingTimeInterval(-3 * 60 * 60) // 3 hours ago
        let freshDate = Date() // just now
        
        let staleEp = makeEpisode(title: "Old Episode", guid: "stale2", podcast: podcast, pubDate: staleDate)
        let freshEp = makeEpisode(title: "New Episode", guid: "fresh1", podcast: podcast, pubDate: freshDate)
        
        // WHEN
        await service.postNewEpisodeNotifications([staleEp, freshEp])
        
        // THEN: 1 notification for the stale episode only
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Should post notification only for the stale episode")
        let body = mockCenter.addedRequests.first?.content.body
        XCTAssertEqual(body, "Old Episode",
                       "Notification body should be the stale episode title")
    }
    
    /// Background sync should still post for ALL episodes regardless of pubDate.
    func test_background_freshEpisodes_stillNotify() async {
        // GIVEN: App is in background, episode published just now
        service.applicationStateProvider = { .background }
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let episode = makeEpisode(title: "Fresh Episode", guid: "fresh2", podcast: podcast, pubDate: Date())
        
        // WHEN
        await service.postNewEpisodeNotifications([episode])
        
        // THEN: Background should always notify
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Background sync should post notifications for all episodes regardless of pubDate")
    }
    
    /// Foreground: all episodes are stale from different podcasts — posts one per podcast.
    func test_foreground_allStale_groupedByPodcast() async {
        // GIVEN: App is in foreground, 3 stale episodes from 2 podcasts
        service.applicationStateProvider = { .active }
        let podcast1 = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let podcast2 = makePodcast(title: "News Daily", url: "https://example.com/news")
        let staleDate = Date().addingTimeInterval(-2 * 60 * 60) // 2 hours ago
        
        let ep1 = makeEpisode(title: "Tech Ep 1", guid: "staleT1", podcast: podcast1, pubDate: staleDate)
        let ep2 = makeEpisode(title: "Tech Ep 2", guid: "staleT2", podcast: podcast1, pubDate: staleDate)
        let ep3 = makeEpisode(title: "News Ep 1", guid: "staleN1", podcast: podcast2, pubDate: staleDate)
        
        // WHEN
        await service.postNewEpisodeNotifications([ep1, ep2, ep3])
        
        // THEN: 2 notifications — 1 per podcast, all stale
        XCTAssertEqual(mockCenter.addedRequests.count, 2,
                       "Foreground stale episodes should still group by podcast")
    }
    
    // MARK: - Grouping by Podcast
    
    /// Multiple episodes from different podcasts should produce one notification per podcast.
    func test_notificationsGroupedByPodcast() async {
        // GIVEN: 3 episodes from 2 podcasts
        let podcast1 = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let podcast2 = makePodcast(title: "News Daily", url: "https://example.com/news")
        let ep1 = makeEpisode(title: "Tech Ep 1", guid: "tech1", podcast: podcast1)
        let ep2 = makeEpisode(title: "Tech Ep 2", guid: "tech2", podcast: podcast1)
        let ep3 = makeEpisode(title: "News Ep 1", guid: "news1", podcast: podcast2)
        
        // WHEN
        await service.postNewEpisodeNotifications([ep1, ep2, ep3])
        
        // THEN: 2 notifications (1 per podcast)
        XCTAssertEqual(mockCenter.addedRequests.count, 2,
                       "Should post 1 notification per podcast, not per episode")
    }
    
    /// Thread identifier should be set for podcast grouping in notification center.
    func test_threadIdentifierSetForGrouping() async {
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let episode = makeEpisode(title: "Episode 1", guid: "ep1", podcast: podcast)
        
        await service.postNewEpisodeNotifications([episode])
        
        let request = mockCenter.addedRequests.first
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.content.threadIdentifier, "https://example.com/tech",
                       "Thread identifier should be the podcast URL for grouping")
    }
    
    // MARK: - Content Formatting
    
    /// Single episode: title = podcast name, body = episode title.
    func test_singleEpisodeContentFormat() async {
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let episode = makeEpisode(title: "The Big Update", guid: "ep1", podcast: podcast)
        
        await service.postNewEpisodeNotifications([episode])
        
        let content = mockCenter.addedRequests.first?.content
        XCTAssertEqual(content?.title, "Tech Today",
                       "Notification title should be the podcast name")
        XCTAssertEqual(content?.body, "The Big Update",
                       "Notification body should be the episode title for a single episode")
    }
    
    /// Multiple episodes from same podcast: title = podcast name, body = "N new episodes".
    func test_multiEpisodeContentFormat() async {
        let podcast = makePodcast(title: "Tech Today", url: "https://example.com/tech")
        let ep1 = makeEpisode(title: "Episode 1", guid: "ep1", podcast: podcast)
        let ep2 = makeEpisode(title: "Episode 2", guid: "ep2", podcast: podcast)
        let ep3 = makeEpisode(title: "Episode 3", guid: "ep3", podcast: podcast)
        
        await service.postNewEpisodeNotifications([ep1, ep2, ep3])
        
        let content = mockCenter.addedRequests.first?.content
        XCTAssertEqual(content?.title, "Tech Today",
                       "Notification title should be the podcast name")
        XCTAssertEqual(content?.body, "3 new episodes",
                       "Notification body should show the count for multiple episodes")
    }
    
    // MARK: - Settings Default
    
    /// The notification setting must default to OFF (privacy-first).
    func test_settingDefaultsToOff() {
        XCTAssertFalse(settingsManager.newEpisodeNotificationsEnabled,
                       "New episode notifications must default to OFF")
    }
}

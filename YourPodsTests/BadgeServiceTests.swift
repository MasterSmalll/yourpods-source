import XCTest
import SwiftData
import UserNotifications
@testable import YourPods

// MARK: - Mock Badge Notification Center

/// Captures badge count updates for test verification.
final class MockBadgeNotificationCenter: BadgeNotificationCenterProtocol, @unchecked Sendable {
    var lastBadgeCount: Int?
    var setBadgeCallCount = 0
    
    func setBadgeCount(_ count: Int) async throws {
        lastBadgeCount = count
        setBadgeCallCount += 1
    }
}

// MARK: - Badge Service Tests

@MainActor
final class BadgeServiceTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: BadgeService!
    private var mockBadgeCenter: MockBadgeNotificationCenter!
    private var settingsManager: SettingsManager!
    private var podcastManager: PodcastManager!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        let testDefaults = UserDefaults(suiteName: "BadgeServiceTests")!
        testDefaults.removePersistentDomain(forName: "BadgeServiceTests")
        
        settingsManager = SettingsManager(defaults: testDefaults)
        podcastManager = PodcastManager(modelContext: context)
        
        mockBadgeCenter = MockBadgeNotificationCenter()
        service = BadgeService.shared
        service.notificationCenter = mockBadgeCenter
        service.podcastManager = podcastManager
        service.settingsManager = settingsManager
    }
    
    override func tearDown() {
        service.notificationCenter = BadgeNotificationCenterWrapper()
        service.podcastManager = nil
        service.settingsManager = nil
        
        UserDefaults(suiteName: "BadgeServiceTests")?.removePersistentDomain(forName: "BadgeServiceTests")
        settingsManager = nil
        podcastManager = nil
        service = nil
        mockBadgeCenter = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func makePodcast(title: String, url: String) -> Podcast {
        let p = Podcast(url: url, title: title, podcastDescription: nil, logoUrl: nil, website: nil, author: nil)
        context.insert(p)
        podcastManager.subscriptions.append(p)
        return p
    }
    
    private func makeEpisode(title: String, guid: String, podcast: Podcast, isPlayed: Bool = false) -> Episode {
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
        e.isPlayed = isPlayed
        context.insert(e)
        podcast.episodes.append(e)
        return e
    }
    
    // MARK: - Badge Count Calculation
    
    /// Badge count should equal the number of unplayed episodes across all subscriptions.
    func test_calculateUnplayedCount_countsUnplayedEpisodes() {
        // GIVEN: 2 podcasts with a mix of played/unplayed episodes
        let pod1 = makePodcast(title: "Pod 1", url: "https://example.com/1")
        _ = makeEpisode(title: "Ep1", guid: "ep1", podcast: pod1, isPlayed: false)
        _ = makeEpisode(title: "Ep2", guid: "ep2", podcast: pod1, isPlayed: true)
        _ = makeEpisode(title: "Ep3", guid: "ep3", podcast: pod1, isPlayed: false)
        
        let pod2 = makePodcast(title: "Pod 2", url: "https://example.com/2")
        _ = makeEpisode(title: "Ep4", guid: "ep4", podcast: pod2, isPlayed: false)
        _ = makeEpisode(title: "Ep5", guid: "ep5", podcast: pod2, isPlayed: true)
        
        // WHEN
        let count = service.calculateUnplayedCount()
        
        // THEN: 3 unplayed episodes (ep1, ep3, ep4)
        XCTAssertEqual(count, 3, "Badge count should equal total unplayed episodes across all subscriptions")
    }
    
    /// Badge count should be 0 when all episodes are played.
    func test_calculateUnplayedCount_zeroWhenAllPlayed() {
        let pod = makePodcast(title: "Pod", url: "https://example.com/pod")
        _ = makeEpisode(title: "Ep1", guid: "ep1", podcast: pod, isPlayed: true)
        _ = makeEpisode(title: "Ep2", guid: "ep2", podcast: pod, isPlayed: true)
        
        let count = service.calculateUnplayedCount()
        
        XCTAssertEqual(count, 0, "Badge count should be 0 when all episodes are played")
    }
    
    /// Badge count should be 0 when there are no subscriptions.
    func test_calculateUnplayedCount_zeroWhenNoSubscriptions() {
        let count = service.calculateUnplayedCount()
        XCTAssertEqual(count, 0, "Badge count should be 0 with no subscriptions")
    }
    
    // MARK: - Badge Update Behavior
    
    /// When badge is enabled, updateBadgeCount should set the badge to the unplayed count.
    func test_updateBadgeCount_setsBadgeWhenEnabled() async {
        // GIVEN: Badge enabled, 2 unplayed episodes
        settingsManager.appBadgeEnabled = true
        let pod = makePodcast(title: "Pod", url: "https://example.com/pod")
        _ = makeEpisode(title: "Ep1", guid: "ep1", podcast: pod, isPlayed: false)
        _ = makeEpisode(title: "Ep2", guid: "ep2", podcast: pod, isPlayed: false)
        
        // WHEN
        await service.updateBadgeCount()
        
        // THEN
        XCTAssertEqual(mockBadgeCenter.lastBadgeCount, 2,
                       "Badge should show unplayed count when enabled")
    }
    
    /// When badge is disabled, updateBadgeCount should clear the badge to 0.
    func test_updateBadgeCount_clearsBadgeWhenDisabled() async {
        // GIVEN: Badge disabled, unplayed episodes exist
        settingsManager.appBadgeEnabled = false
        let pod = makePodcast(title: "Pod", url: "https://example.com/pod")
        _ = makeEpisode(title: "Ep1", guid: "ep1", podcast: pod, isPlayed: false)
        
        // WHEN
        await service.updateBadgeCount()
        
        // THEN
        XCTAssertEqual(mockBadgeCenter.lastBadgeCount, 0,
                       "Badge should be cleared to 0 when feature is disabled")
    }
    
    /// When badge is enabled but no podcastManager is wired, badge should be 0.
    func test_updateBadgeCount_safeWithNilPodcastManager() async {
        // GIVEN: Badge enabled but podcastManager is nil
        settingsManager.appBadgeEnabled = true
        service.podcastManager = nil
        
        // WHEN
        await service.updateBadgeCount()
        
        // THEN: Should not crash, badge should be 0
        XCTAssertEqual(mockBadgeCenter.lastBadgeCount, 0,
                       "Badge should be 0 when podcastManager is not available")
    }
    
    // MARK: - Integration: Badge updates after processNewEpisodes
    
    /// Badge should update after processNewEpisodes discovers new episodes.
    func test_badgeUpdatesAfterProcessNewEpisodes() async {
        // GIVEN: Badge enabled, notification service mocked for background
        settingsManager.appBadgeEnabled = true
        settingsManager.newEpisodeNotificationsEnabled = false // Badges independent from notifications
        
        let notifMock = MockNotificationCenter()
        NewEpisodeNotificationService.shared.notificationCenter = notifMock
        NewEpisodeNotificationService.shared.applicationStateProvider = { .background }
        
        let pod = makePodcast(title: "Pod", url: "https://example.com/pod")
        let existingEp = makeEpisode(title: "Old Ep", guid: "old-ep", podcast: pod, isPlayed: false)
        let newEp = makeEpisode(title: "New Ep", guid: "new-ep", podcast: pod, isPlayed: false)
        
        let playerManager = PlayerManager(audioManager: AudioManager())
        let downloadManager = DownloadManager()
        
        // Wire badge service for integration
        podcastManager.badgeService = service
        
        // WHEN: processNewEpisodes runs
        await podcastManager.processNewEpisodes(
            [newEp],
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )
        
        // THEN: Badge should reflect total unplayed count (old + new = 2)
        XCTAssertEqual(mockBadgeCenter.lastBadgeCount, 2,
                       "Badge should update to total unplayed count after processNewEpisodes")
        
        // Cleanup
        NewEpisodeNotificationService.shared.notificationCenter = UNUserNotificationCenterWrapper()
        NewEpisodeNotificationService.shared.applicationStateProvider = {
            #if os(iOS)
            return await MainActor.run {
                UIApplication.shared.applicationState == .active ? .active : .background
            }
            #else
            return .background
            #endif
        }
    }
    
    // MARK: - Setting Independence
    
    /// Badge and notification toggles should be independent.
    func test_badgeAndNotificationsAreIndependent() async {
        // GIVEN: Badge ON, notifications OFF
        settingsManager.appBadgeEnabled = true
        settingsManager.newEpisodeNotificationsEnabled = false
        
        let pod = makePodcast(title: "Pod", url: "https://example.com/pod")
        _ = makeEpisode(title: "Ep1", guid: "ep1", podcast: pod, isPlayed: false)
        
        // WHEN
        await service.updateBadgeCount()
        
        // THEN: Badge should still update regardless of notification setting
        XCTAssertEqual(mockBadgeCenter.lastBadgeCount, 1,
                       "Badge should work independently from notification toggle")
    }
    
    /// Badge should work when notifications are enabled too.
    func test_badgeWorksWithNotificationsAlsoEnabled() async {
        // GIVEN: Both ON
        settingsManager.appBadgeEnabled = true
        settingsManager.newEpisodeNotificationsEnabled = true
        
        let pod = makePodcast(title: "Pod", url: "https://example.com/pod")
        _ = makeEpisode(title: "Ep1", guid: "ep1", podcast: pod, isPlayed: false)
        _ = makeEpisode(title: "Ep2", guid: "ep2", podcast: pod, isPlayed: false)
        _ = makeEpisode(title: "Ep3", guid: "ep3", podcast: pod, isPlayed: true)
        
        // WHEN
        await service.updateBadgeCount()
        
        // THEN
        XCTAssertEqual(mockBadgeCenter.lastBadgeCount, 2,
                       "Badge should show correct count when both badge and notifications are enabled")
    }
    
    // MARK: - Profile Sync
    
    /// appBadgeEnabled should be included in the profile sync payload.
    func test_appBadgeEnabled_inProfilePayload() {
        settingsManager.appBadgeEnabled = true
        let payload = settingsManager.asProfilePayload()
        
        if case .bool(let v) = payload["appBadgeEnabled"] {
            XCTAssertTrue(v, "appBadgeEnabled should be true in payload")
        } else {
            XCTFail("appBadgeEnabled missing from profile payload")
        }
    }
    
    /// appBadgeEnabled=false should also serialize in payload.
    func test_appBadgeDisabled_inProfilePayload() {
        settingsManager.appBadgeEnabled = false
        let payload = settingsManager.asProfilePayload()
        
        if case .bool(let v) = payload["appBadgeEnabled"] {
            XCTAssertFalse(v, "appBadgeEnabled should be false in payload")
        } else {
            XCTFail("appBadgeEnabled missing from profile payload")
        }
    }
}

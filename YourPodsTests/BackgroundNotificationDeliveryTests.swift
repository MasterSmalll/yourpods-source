import XCTest
import SwiftData
import UserNotifications
@testable import YourPods

// MARK: - Background Notification Delivery Tests

/// Tests proving that `processNewEpisodes()` awaits notification posting
/// rather than dispatching it as fire-and-forget.
///
/// Root cause: `processNewEpisodes()` wrapped the notification call in an
/// unstructured `Task { }`, which races against `BGAppRefreshTask.setTaskCompleted()`.
/// iOS suspends the process before the Task runs → no notifications.
///
/// These tests verify the fix: `processNewEpisodes()` must be async and
/// `await` the notification posting inline so the background task doesn't
/// complete until notifications are posted.
@MainActor
final class BackgroundNotificationDeliveryTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: NewEpisodeNotificationService!
    private var mockCenter: MockNotificationCenter!
    private var settingsManager: SettingsManager!
    private var podcastManager: PodcastManager!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        service = NewEpisodeNotificationService.shared
        mockCenter = MockNotificationCenter()
        service.notificationCenter = mockCenter
        service.applicationStateProvider = { .background }
        
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "BackgroundNotificationDeliveryTests")!)
        settingsManager.newEpisodeNotificationsEnabled = true
        
        podcastManager = PodcastManager(modelContext: context)
    }
    
    override func tearDown() {
        // Restore production notification center
        service.notificationCenter = UNUserNotificationCenterWrapper()
        service.applicationStateProvider = {
            #if os(iOS)
            return UIApplication.shared.applicationState == .active ? .active : .background
            #else
            return .background
            #endif
        }
        
        UserDefaults(suiteName: "BackgroundNotificationDeliveryTests")?.removePersistentDomain(forName: "BackgroundNotificationDeliveryTests")
        settingsManager = nil
        podcastManager = nil
        service = nil
        mockCenter = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func makePodcast(title: String, url: String, notificationsEnabled: Bool? = true) -> Podcast {
        let p = Podcast(url: url, title: title, podcastDescription: nil, logoUrl: nil, website: nil, author: nil)
        context.insert(p)
        var settings = p.effectiveSettings
        settings.notificationsEnabled = notificationsEnabled
        p.effectiveSettings = settings
        podcastManager.subscriptions.append(p)
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
        podcast.episodes.append(e)
        return e
    }
    
    // MARK: - Core: Notification must be awaited, not fire-and-forget
    
    /// After `processNewEpisodes()` returns, the notification MUST already be
    /// posted. If it's fire-and-forget (detached Task), this test will fail
    /// because the mock won't have captured the request yet.
    func test_processNewEpisodes_awaitsNotificationPosting() async {
        // GIVEN: A podcast with notifications enabled and a new episode
        let podcast = makePodcast(title: "Test Pod", url: "https://example.com/test")
        let episode = makeEpisode(title: "New Episode", guid: "new-ep-1", podcast: podcast)
        
        let playerManager = PlayerManager(audioManager: AudioManager())
        let downloadManager = DownloadManager()
        
        // WHEN: processNewEpisodes completes
        await podcastManager.processNewEpisodes(
            [episode],
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )
        
        // THEN: Notification must already be posted — no race condition
        // If processNewEpisodes uses fire-and-forget Task { }, the mock
        // will have 0 requests because the Task hasn't run yet.
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Notification must be posted BEFORE processNewEpisodes returns — fire-and-forget Task causes background delivery failure")
    }
    
    /// Verify that the applicationStateProvider is safe to call from any thread.
    /// During background refresh, the provider must return .background consistently.
    func test_applicationStateProvider_backgroundDuringBackgroundRefresh() async {
        // GIVEN: App state simulating background refresh
        service.applicationStateProvider = { .background }
        
        let podcast = makePodcast(title: "BG Pod", url: "https://example.com/bg")
        let episode = makeEpisode(title: "BG Episode", guid: "bg-ep-1", podcast: podcast)
        
        // WHEN: Posting from a background context (simulating BGAppRefreshTask)
        await service.postNewEpisodeNotifications([episode])
        
        // THEN: Notification posted (not suppressed by wrong state detection)
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Background state must allow notification posting")
    }
    
    /// Verify notifications are posted for multiple opted-in podcasts
    /// and all are awaited before the function returns.
    func test_processNewEpisodes_awaitsAllPodcastNotifications() async {
        // GIVEN: 3 podcasts with notifications enabled, 1 episode each
        let pod1 = makePodcast(title: "Pod 1", url: "https://example.com/1")
        let pod2 = makePodcast(title: "Pod 2", url: "https://example.com/2")
        let pod3 = makePodcast(title: "Pod 3", url: "https://example.com/3")
        
        let ep1 = makeEpisode(title: "Ep 1", guid: "ep-1", podcast: pod1)
        let ep2 = makeEpisode(title: "Ep 2", guid: "ep-2", podcast: pod2)
        let ep3 = makeEpisode(title: "Ep 3", guid: "ep-3", podcast: pod3)
        
        let playerManager = PlayerManager(audioManager: AudioManager())
        let downloadManager = DownloadManager()
        
        // WHEN
        await podcastManager.processNewEpisodes(
            [ep1, ep2, ep3],
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )
        
        // THEN: All 3 notifications awaited and posted
        XCTAssertEqual(mockCenter.addedRequests.count, 3,
                       "All 3 podcast notifications must be posted before processNewEpisodes returns")
    }
    
    /// Verify that non-opted-in podcasts don't produce notifications even in async path.
    func test_processNewEpisodes_respectsOptInFilterInAsyncPath() async {
        // GIVEN: 2 podcasts — one opted in, one not
        let optedIn = makePodcast(title: "Opted In", url: "https://example.com/in", notificationsEnabled: true)
        let optedOut = makePodcast(title: "Opted Out", url: "https://example.com/out", notificationsEnabled: nil)
        
        let ep1 = makeEpisode(title: "Ep In", guid: "ep-in", podcast: optedIn)
        let ep2 = makeEpisode(title: "Ep Out", guid: "ep-out", podcast: optedOut)
        
        let playerManager = PlayerManager(audioManager: AudioManager())
        let downloadManager = DownloadManager()
        
        // WHEN
        await podcastManager.processNewEpisodes(
            [ep1, ep2],
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )
        
        // THEN: Only the opted-in podcast notification is posted
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "Only opted-in podcast should produce a notification")
        XCTAssertEqual(mockCenter.addedRequests.first?.content.title, "Opted In")
    }
}

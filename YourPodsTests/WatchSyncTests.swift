import XCTest
import WatchConnectivity
import SwiftData
@testable import YourPods

class MockWatchSession: WatchSessionProtocol {
    var delegate: WCSessionDelegate?
    var isPaired: Bool = true
    var isReachable: Bool = true
    var lastUpdatedContext: [String : Any]?
    var lastSentMessage: [String : Any]?
    var contextUpdateCount = 0
    var sentMessages: [[String: Any]] = []

    func activate() {}
    func updateApplicationContext(_ context: [String : Any]) throws {
        lastUpdatedContext = context
        contextUpdateCount += 1
    }
    func sendMessage(_ message: [String : Any], replyHandler: (([String : Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        lastSentMessage = message
        sentMessages.append(message)
    }
}

@MainActor
final class WatchSyncTests: XCTestCase {
    
    var watchService: WatchService!
    var audioManager: AudioManager!
    var mockSession: MockWatchSession!
    var container: ModelContainer!
    var context: ModelContext!
    var podcastManager: PodcastManager!
    var playerManager: PlayerManager!

    override func setUp() {
        super.setUp()
        // Clean slate for queue keys
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")

        watchService = WatchService.shared
        audioManager = AudioManager()
        watchService.audioManager = audioManager

        mockSession = MockWatchSession()
        watchService.session = mockSession

        // In-memory SwiftData stack for watch-position persistence tests.
        container = try! ModelContainer(
            for: Podcast.self, Episode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        podcastManager = PodcastManager(modelContext: context)
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }
    
    func testSyncQueue_IncludesCurrentItemAndUpcoming() {
        // GIVEN: A current item and an upcoming queue
        let current = QueueItem(
            id: "current-id",
            title: "Current Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/1.mp3",
            artworkUrl: "https://example.com/1.jpg",
            durationSeconds: 3600,
            positionSeconds: 100,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        
        let upcoming = QueueItem(
            id: "upcoming-id",
            title: "Upcoming Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/2.mp3",
            artworkUrl: "https://example.com/2.jpg",
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        
        audioManager.currentItem = current
        audioManager.appendToQueue([upcoming])
        
        // WHEN: Syncing the queue
        watchService.syncQueue(autoSyncEnabled: true)
        
        // THEN: The context should include both current and upcoming
        guard let queue = mockSession.lastUpdatedContext?["queue"] as? [[String: Any]] else {
            XCTFail("Queue missing from context")
            return
        }
        
        XCTAssertEqual(queue.count, 2, "Queue should include currentItem + upcoming items")
        XCTAssertEqual(queue[0]["id"] as? String, "current-id")
        XCTAssertEqual(queue[1]["id"] as? String, "upcoming-id")
    }
    
    func testSyncQueue_IncludesArtistField() {
        let upcoming = QueueItem(
            id: "upcoming-id",
            title: "Upcoming Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/2.mp3",
            artworkUrl: "https://example.com/2.jpg",
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([upcoming])
        
        watchService.syncQueue(autoSyncEnabled: true)
        
        guard let queue = mockSession.lastUpdatedContext?["queue"] as? [[String: Any]] else {
            XCTFail("Queue missing from context")
            return
        }
        
        XCTAssertNotNil(queue[0]["artist"], "Each item must have an 'artist' field for Watch compatibility")
        XCTAssertEqual(queue[0]["artist"] as? String, "Podcast A")
    }



    func testSyncQueue_IncludesPositionSyncInterval_Default30() {
        // GIVEN: Default settings (watchPositionSyncInterval not explicitly set)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchPositionSyncInterval")
        
        let upcoming = QueueItem(
            id: "interval-test",
            title: "Interval Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/interval.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([upcoming])
        
        // WHEN: Syncing the queue with default interval
        watchService.syncQueue(autoSyncEnabled: true)
        
        // THEN: The context should include positionSyncInterval defaulting to 30
        let interval = mockSession.lastUpdatedContext?["positionSyncInterval"] as? Int
        XCTAssertNotNil(interval, "positionSyncInterval must be included in application context")
        XCTAssertEqual(interval, 30, "Default position sync interval should be 30 seconds")
    }
    
    func testSyncQueue_IncludesPositionSyncInterval_CustomValue() {
        // GIVEN: A custom watchPositionSyncInterval of 60
        let defaults = UserDefaults.standard
        defaults.set(60, forKey: "watchPositionSyncInterval")
        defer { defaults.removeObject(forKey: "watchPositionSyncInterval") }
        
        let upcoming = QueueItem(
            id: "interval-custom",
            title: "Custom Interval Episode",
            podcastTitle: "Podcast A",
            audioUrl: "https://example.com/custom.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        audioManager.appendToQueue([upcoming])
        
        // WHEN: Syncing with custom interval
        watchService.syncQueue(autoSyncEnabled: true, watchPositionSyncInterval: 60)
        
        // THEN: The context should reflect the custom interval
        let interval = mockSession.lastUpdatedContext?["positionSyncInterval"] as? Int
        XCTAssertEqual(interval, 60, "Custom position sync interval should be transmitted to watch")
    }

    // MARK: - Watch→iPhone resume: position persistence (forward-only)

    @discardableResult
    private func makePodcastWithEpisode(guid: String = "ep-1", listenedSeconds: Int = 0) -> Episode {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: guid, title: "Episode \(guid)", audioUrl: "https://example.com/\(guid).mp3", pubDate: Date())
        episode.listenedSeconds = listenedSeconds
        episode.podcast = podcast
        podcast.episodes = [episode]
        context.insert(podcast)
        context.insert(episode)
        podcastManager.subscriptions = [podcast]
        return episode
    }

    func test_updateProgress_persistsListenedSeconds_whenEpisodeNotLoaded() {
        let episode = makePodcastWithEpisode(listenedSeconds: 0)
        XCTAssertNil(audioManager.currentItem)
        playerManager.updateProgress(episodeId: "ep-1", position: 1500)
        XCTAssertEqual(episode.listenedSeconds, 1500)
    }

    func test_updateProgress_isForwardOnly_neverRewinds() {
        let episode = makePodcastWithEpisode(listenedSeconds: 2000)
        playerManager.updateProgress(episodeId: "ep-1", position: 1500)
        XCTAssertEqual(episode.listenedSeconds, 2000)
    }

    func test_updateProgress_isIdempotent_onDoubleDelivery() {
        let episode = makePodcastWithEpisode(listenedSeconds: 0)
        playerManager.updateProgress(episodeId: "ep-1", position: 1500)
        playerManager.updateProgress(episodeId: "ep-1", position: 1500)
        XCTAssertEqual(episode.listenedSeconds, 1500)
    }

    func test_updateProgress_unknownGuid_isNoOp() {
        let episode = makePodcastWithEpisode(listenedSeconds: 300)
        playerManager.updateProgress(episodeId: "nope", position: 1500)
        XCTAssertEqual(episode.listenedSeconds, 300)
    }

    // MARK: - refresh_queue reply payload

    func test_refreshQueueReply_containsQueuePayload() {
        // GIVEN: a current item and one upcoming item
        let current = QueueItem(
            id: "cur", title: "Current", podcastTitle: "Pod A",
            audioUrl: "https://example.com/c.mp3", artworkUrl: nil,
            durationSeconds: 100, positionSeconds: 10,
            podcastUrl: "https://example.com/feed", pubDate: nil)
        let next = QueueItem(
            id: "next", title: "Next", podcastTitle: "Pod A",
            audioUrl: "https://example.com/n.mp3", artworkUrl: nil,
            durationSeconds: 200, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil)
        audioManager.currentItem = current
        audioManager.appendToQueue([next])

        // WHEN
        let reply = watchService.refreshQueueReply()

        // THEN: the reply carries the full queue in wire format
        let queue = reply["queue"] as? [[String: Any]]
        XCTAssertEqual(queue?.count, 2)
        XCTAssertEqual(queue?.first?["id"] as? String, "cur")
        XCTAssertEqual(queue?.last?["id"] as? String, "next")
        XCTAssertNotNil(WatchWireFormat.decodeQueueItem(queue!.first!))
    }

    // MARK: - syncQueue dedupe / throttle (battery fix)

    /// `WatchService.shared` is a true singleton whose dedupe/throttle state
    /// (`lastStableFingerprint`, `lastContextPushAt`, ...) persists across every
    /// test in this process, not just within one test method. Deriving queue-item
    /// ids from the running test's name keeps each test's fingerprint globally
    /// unique so a prior test's residual state can never accidentally throttle
    /// (or fail to throttle) this test's first push.
    private var uniqueTestSuffix: String {
        name.filter { $0.isLetter || $0.isNumber }
    }

    /// Seed `currentItem` (fixed id for this test) + one upcoming item. Calling
    /// again with a different `currentPosition` mutates only the position,
    /// simulating a same-episode position tick — membership/order/metadata
    /// stay identical.
    private func seedQueue(currentPosition: Int) {
        let suffix = uniqueTestSuffix
        audioManager.currentItem = QueueItem(
            id: "current-\(suffix)", title: "Current \(suffix)", podcastTitle: "Pod \(suffix)",
            audioUrl: "https://example.com/\(suffix)-current.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: currentPosition,
            podcastUrl: "https://example.com/feed-\(suffix)", pubDate: nil)
        if audioManager.queue.isEmpty {
            audioManager.appendToQueue([QueueItem(
                id: "upcoming-\(suffix)", title: "Upcoming \(suffix)", podcastTitle: "Pod \(suffix)",
                audioUrl: "https://example.com/\(suffix)-upcoming.mp3", artworkUrl: nil,
                durationSeconds: 1800, positionSeconds: 0,
                podcastUrl: "https://example.com/feed-\(suffix)", pubDate: nil)])
        }
    }

    /// Append a new, previously-unseen episode to the queue — a membership change.
    private func appendEpisodeToQueue(id: String) {
        let suffix = uniqueTestSuffix
        audioManager.appendToQueue([QueueItem(
            id: "\(id)-\(suffix)", title: "Episode \(id)", podcastTitle: "Pod \(suffix)",
            audioUrl: "https://example.com/\(suffix)-\(id).mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed-\(suffix)", pubDate: nil)])
    }

    func test_syncQueue_positionOnlyChange_isThrottled() {
        seedQueue(currentPosition: 10)          // helper: current + one upcoming
        watchService.syncQueue(watchPositionSyncInterval: 30)
        XCTAssertEqual(mockSession.contextUpdateCount, 1)

        // Position ticks forward 5s — same membership/order/metadata.
        seedQueue(currentPosition: 15)
        watchService.syncQueue(watchPositionSyncInterval: 30)
        XCTAssertEqual(mockSession.contextUpdateCount, 1, "position-only change within interval must not push")
    }

    func test_syncQueue_membershipChange_pushesImmediately() {
        seedQueue(currentPosition: 10)
        watchService.syncQueue(watchPositionSyncInterval: 30)
        appendEpisodeToQueue(id: "new-ep")      // helper
        watchService.syncQueue(watchPositionSyncInterval: 30)
        XCTAssertEqual(mockSession.contextUpdateCount, 2)
    }

    func test_syncQueue_doesNotSendDuplicateQueueMessage() {
        seedQueue(currentPosition: 10)
        mockSession.isReachable = true
        watchService.syncQueue()
        XCTAssertTrue(mockSession.sentMessages.allSatisfy { $0["queue"] == nil },
                      "the watch ignores message-borne queues; this push is pure radio waste")
    }

    func test_updatePlaybackState_unchangedInfo_doesNotPush() {
        watchService.updatePlaybackState()
        let count = mockSession.contextUpdateCount
        watchService.updatePlaybackState()   // nothing changed
        XCTAssertEqual(mockSession.contextUpdateCount, count)
    }

    func test_syncQueueWithSettings_respectsDisabledWatchSync() {
        let settings = SettingsManager()          // uses UserDefaults — set and restore
        settings.watchSyncEnabled = false
        watchService.settingsManager = settings
        defer { settings.watchSyncEnabled = true }

        seedQueue(currentPosition: 0)
        watchService.syncQueueWithSettings()
        XCTAssertEqual(mockSession.contextUpdateCount, 0, "watchSyncEnabled=false must suppress pushes")
    }
}

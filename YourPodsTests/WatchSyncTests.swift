import XCTest
import WatchConnectivity
@testable import YourPods

class MockWatchSession: WatchSessionProtocol {
    var delegate: WCSessionDelegate?
    var isPaired: Bool = true
    var isReachable: Bool = true
    var lastUpdatedContext: [String : Any]?
    var lastSentMessage: [String : Any]?
    
    func activate() {}
    func updateApplicationContext(_ context: [String : Any]) throws {
        lastUpdatedContext = context
    }
    func sendMessage(_ message: [String : Any], replyHandler: (([String : Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        lastSentMessage = message
    }
}

@MainActor
final class WatchSyncTests: XCTestCase {
    
    var watchService: WatchService!
    var audioManager: AudioManager!
    var mockSession: MockWatchSession!
    
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
}

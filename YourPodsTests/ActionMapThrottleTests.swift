import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for the action map persistence throttle.
///
/// Root cause: `persistActionMap()` re-encodes the full `[String: EpisodeAction]`
/// dictionary into UserDefaults on every `sendEpisodeAction()` call — at the
/// default 60s server sync interval this generated ~132 MB of writes over 22 hours.
///
/// Fix: Throttle `persistActionMap()` to 60-second intervals via
/// `throttledPersistActionMap()`, with a `forcePersistActionMap()` bypass
/// for critical moments (sync completion, app backgrounding).
@MainActor
final class ActionMapThrottleTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-throttle-am"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
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
            "episodeActionMap",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Throttle Behavior

    /// Two rapid `sendEpisodeAction()` calls should NOT both persist the actionMap.
    /// The second call should update in-memory but skip the disk write.
    func test_sendEpisodeAction_throttlesPersistActionMap() async {
        let action1 = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 100,
            started: 0,
            total: 600,
            device: "test"
        )
        let action2 = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 200,
            started: 0,
            total: 600,
            device: "test"
        )

        // First call — should persist (cold start, lastActionMapPersistTime is distantPast)
        await manager.episodeActionSync.sendEpisodeAction(action1)
        XCTAssertEqual(manager.episodeActionSync.actionMapPersistCount, 1,
                       "First sendEpisodeAction should persist the actionMap")

        // Second call — should be throttled
        await manager.episodeActionSync.sendEpisodeAction(action2)
        XCTAssertEqual(manager.episodeActionSync.actionMapPersistCount, 1,
                       "Second rapid sendEpisodeAction should NOT persist — throttled")

        // Verify in-memory map was still updated
        let latestAction = manager.episodeActionSync.getLatestAction(for: "ep-1")
        XCTAssertEqual(latestAction?.position, 200,
                       "In-memory actionMap should reflect the latest action even when persistence is throttled")
    }

    /// After the throttle interval elapses, the next call should persist.
    func test_sendEpisodeAction_persistsAfterThrottleInterval() async {
        let action1 = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 100,
            started: 0,
            total: 600,
            device: "test"
        )

        // First call — persists
        await manager.episodeActionSync.sendEpisodeAction(action1)
        XCTAssertEqual(manager.episodeActionSync.actionMapPersistCount, 1)

        // Simulate time passing beyond the throttle interval
        manager.episodeActionSync.testOverrideLastActionMapPersistTime(.distantPast)

        let action2 = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 300,
            started: 0,
            total: 600,
            device: "test"
        )

        // Second call after interval — should persist
        await manager.episodeActionSync.sendEpisodeAction(action2)
        XCTAssertEqual(manager.episodeActionSync.actionMapPersistCount, 2,
                       "Persist should fire after throttle interval elapses")
    }

    // MARK: - Force Bypass

    /// `forcePersistActionMap()` must always persist, regardless of throttle state.
    func test_forcePersistActionMap_bypassesThrottle() async {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 100,
            started: 0,
            total: 600,
            device: "test"
        )

        // First call — persists
        await manager.episodeActionSync.sendEpisodeAction(action)
        XCTAssertEqual(manager.episodeActionSync.actionMapPersistCount, 1)

        // Force persist — should always work, even within the throttle window
        manager.episodeActionSync.forcePersistActionMap()
        XCTAssertEqual(manager.episodeActionSync.actionMapPersistCount, 2,
                       "forcePersistActionMap must bypass the throttle")
    }
}

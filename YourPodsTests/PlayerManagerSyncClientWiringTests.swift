import XCTest
import SwiftData
@testable import YourPods

/// Verifies that `PodcastManager.setSyncClient` forwards the client
/// to `PlayerManager`, ensuring queue sync is wired at all call sites
/// (onboarding, profile switch, reconnect) — not just app cold start.
///
/// Root cause: Every View that called `podcastManager.setSyncClient(...)`
/// forgot to also call `playerManager.setSyncClient(...)`. The only place
/// PlayerManager got wired was `YourPodsApp.init()`. After onboarding or
/// profile switches, `PlayerManager.syncClient` was nil and queue sync
/// silently skipped (zero log output, zero errors).
@MainActor
final class PlayerManagerSyncClientWiringTests: XCTestCase {
    
    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!
    private var podcastManager: PodcastManager!
    
    override func setUp() async throws {
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        
        let container = try ModelContainer(
            for: Podcast.self, Episode.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        podcastManager = PodcastManager(modelContext: container.mainContext)
        
        // Wire the relationship (as YourPodsApp.init does)
        podcastManager.playerManager = playerManager
        playerManager.podcastManager = podcastManager
    }
    
    /// When PodcastManager.setSyncClient is called with a queue-capable client,
    /// PlayerManager should also receive it and queue sync should execute.
    func test_setSyncClient_forwardsToPlayerManager() async throws {
        let spy = QueueFixSpy()
        
        // Call setSyncClient on PodcastManager only (simulates what Views do)
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        
        // PlayerManager should now have a sync client wired.
        // syncQueueWithServer calls getQueue as Step 1 — if the guard passes,
        // the spy records the call.
        _ = await playerManager.syncQueueWithServer()
        
        let called = await spy.getQueueCalled
        XCTAssertTrue(called, "PlayerManager.syncQueueWithServer should have called getQueue — syncClient was not forwarded from PodcastManager")
    }
    
    /// When PodcastManager.setSyncClient(nil) is called (logout/vault switch),
    /// PlayerManager should also have its client cleared and queue sync should no-op.
    func test_setSyncClient_nil_clearsPlayerManager() async throws {
        let spy = QueueFixSpy()
        
        // Wire a client first
        podcastManager.setSyncClient(spy, deviceId: "test-device")
        
        // Clear it (simulates switching to Vault Mode)
        podcastManager.setSyncClient(nil, deviceId: "local")
        
        // Reset the spy's tracking
        await spy.resetGetQueueCalled()
        
        // syncQueueWithServer should be a no-op (guard fails silently)
        let conflicts = await playerManager.syncQueueWithServer()
        XCTAssertTrue(conflicts.isEmpty, "After clearing syncClient, queue sync should return empty")
        
        let called = await spy.getQueueCalled
        XCTAssertFalse(called, "After clearing syncClient, PlayerManager should not attempt queue sync")
    }
    
    /// Negative test: without the playerManager wiring, queue sync should NOT work.
    /// This documents the exact bug that was fixed.
    func test_withoutWiring_queueSyncDoesNotRun() async throws {
        // Create a separate PodcastManager WITHOUT the playerManager wired
        let container = try ModelContainer(
            for: Podcast.self, Episode.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        let unwiredPodcastManager = PodcastManager(modelContext: container.mainContext)
        // Deliberately NOT setting: unwiredPodcastManager.playerManager = playerManager
        
        let spy = QueueFixSpy()
        unwiredPodcastManager.setSyncClient(spy, deviceId: "test-device")
        
        // PlayerManager should NOT have a sync client — queue sync should skip
        _ = await playerManager.syncQueueWithServer()
        
        let called = await spy.getQueueCalled
        XCTAssertFalse(called, "Without wiring, PlayerManager should not have received the sync client")
    }
}

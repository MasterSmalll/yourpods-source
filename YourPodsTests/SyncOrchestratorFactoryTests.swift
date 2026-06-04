import XCTest
import SwiftData
@testable import YourPods

/// Tests for `SyncOrchestratorFactory` — verifies the factory dispatches
/// the correct orchestrator based on profile type and sync client.
@MainActor
final class SyncOrchestratorFactoryTests: XCTestCase {

    // MARK: - Vault (no profile / no client)

    func test_factory_returnsGPodder_whenNoProfileButHasSyncClient() {
        // GIVEN: No active profile but a sync client is wired (e.g. tests,
        // legacy edge case). The factory should fall back to gPodder-style
        // sync since a server connection exists.
        let spy = StubSyncClientForFactory()
        
        // WHEN
        let orchestrator = SyncOrchestratorFactory.make(
            profile: nil,
            podcastManager: makePodcastManager(),
            syncClient: spy
        )
        
        // THEN: Falls back to GPodderSyncOrchestrator (not Vault) because
        // the old monolith would still run subscription+action sync when
        // syncClient != nil, regardless of profile presence.
        XCTAssertTrue(orchestrator is GPodderSyncOrchestrator,
                      "nil profile + non-nil syncClient must produce GPodderSyncOrchestrator, got \(type(of: orchestrator))")
    }

    func test_factory_returnsVault_whenNothingConfigured() {
        // GIVEN: No profile AND no sync client — true Vault mode
        
        // WHEN
        let orchestrator = SyncOrchestratorFactory.make(
            profile: nil,
            podcastManager: makePodcastManager(),
            syncClient: nil
        )
        
        // THEN
        XCTAssertTrue(orchestrator is VaultSyncOrchestrator,
                      "nil profile + nil syncClient must produce VaultSyncOrchestrator, got \(type(of: orchestrator))")
    }

    func test_factory_returnsVault_whenNoSyncClient() {
        // GIVEN: A profile exists but no sync client
        let profile = makeProfile(type: .gpodder)
        
        // WHEN
        let orchestrator = SyncOrchestratorFactory.make(
            profile: profile,
            podcastManager: makePodcastManager(),
            syncClient: nil
        )
        
        // THEN
        XCTAssertTrue(orchestrator is VaultSyncOrchestrator,
                      "nil syncClient must produce VaultSyncOrchestrator, got \(type(of: orchestrator))")
    }

    // MARK: - gPodder

    func test_factory_returnsGPodder_forGPodderProfile() {
        // GIVEN: A gPodder profile with a sync client
        let profile = makeProfile(type: .gpodder)
        let spy = StubSyncClientForFactory()
        
        // WHEN
        let orchestrator = SyncOrchestratorFactory.make(
            profile: profile,
            podcastManager: makePodcastManager(),
            syncClient: spy
        )
        
        // THEN
        XCTAssertTrue(orchestrator is GPodderSyncOrchestrator,
                      ".gpodder profile must produce GPodderSyncOrchestrator, got \(type(of: orchestrator))")
    }

    func test_factory_returnsGPodder_forGPodderNetProfile() {
        // GIVEN: A gpodder.net profile
        let profile = makeProfile(type: .gpodderNet)
        let spy = StubSyncClientForFactory()
        
        // WHEN
        let orchestrator = SyncOrchestratorFactory.make(
            profile: profile,
            podcastManager: makePodcastManager(),
            syncClient: spy
        )
        
        // THEN
        XCTAssertTrue(orchestrator is GPodderSyncOrchestrator,
                      ".gpodderNet profile must produce GPodderSyncOrchestrator, got \(type(of: orchestrator))")
    }

    // MARK: - Pro

    func test_factory_returnsPro_forYourPodsProProfile() {
        // GIVEN: A Pro profile with a sync client
        let profile = makeProfile(type: .yourpodsPro)
        let spy = StubSyncClientForFactory()
        
        // WHEN
        let orchestrator = SyncOrchestratorFactory.make(
            profile: profile,
            podcastManager: makePodcastManager(),
            syncClient: spy
        )
        
        // THEN
        XCTAssertTrue(orchestrator is ProSyncOrchestrator,
                      "Pro profile must produce ProSyncOrchestrator, got \(type(of: orchestrator))")
    }

    // MARK: - Helpers

    private func makeProfile(type: ProfileType) -> ServerProfile {
        ServerProfile(
            name: "Test Profile",
            baseUrl: "https://example.com",
            username: "test",
            deviceId: "test-device",
            profileType: type
        )
    }

    private func makePodcastManager() -> PodcastManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        return PodcastManager(modelContext: container.mainContext)
    }
}

// MARK: - Minimal Stub SyncClient for Factory Tests

private actor StubSyncClientForFactory: SyncClient {
    var supportsQueueSync: Bool { false }
    var supportsSettingsSync: Bool { false }
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult { QueueSyncResult(items: [], droppedItems: []) }
    func getQueue() async throws -> [QueueSyncItem] { [] }
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] { [] }
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        SubscriptionDelta(add: [], remove: [], timestamp: 0)
    }
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] { [] }
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] { [] }
}

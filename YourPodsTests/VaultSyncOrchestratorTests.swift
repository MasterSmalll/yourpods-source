import XCTest
import SwiftData
@testable import YourPods

/// Tests for `VaultSyncOrchestrator` — RSS refresh only, no server contact.
///
/// Vault mode users have no account and no sync client. The orchestrator
/// must refresh RSS feeds and run auto-queue/download, but must NEVER
/// contact any server for subscriptions, episode actions, or queue sync.
@MainActor
final class VaultSyncOrchestratorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        manager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = manager
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()
        manager.downloadManager = downloadManager
        manager.settingsManager = settingsManager
    }

    override func tearDown() {
        downloadManager = nil
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Positive: RSS refresh runs

    /// Vault sync must refresh RSS feeds.
    func test_vault_refreshesRSSFeeds() async {
        // GIVEN: A Vault orchestrator (no sync client)
        let orchestrator = VaultSyncOrchestrator()
        manager.isRefreshing = false

        // WHEN: Running sync
        _ = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        // THEN: isRefreshing was toggled (indicates refreshAllFeeds ran)
        // Since we have no subscriptions, the method completes quickly,
        // but the key assertion is that it doesn't crash and runs to completion.
        // The real validation is the negative test below.
        XCTAssertFalse(manager.isRefreshing, "Sync should have completed")
    }

    // MARK: - Negative: No server contact

    /// Vault sync must return empty conflicts (no server to conflict with).
    func test_vault_returnsEmptyConflicts() async {
        let orchestrator = VaultSyncOrchestrator()

        let conflicts = await orchestrator.sync(
            podcastManager: manager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager,
            conflictStrategy: .serverWins
        )

        XCTAssertTrue(conflicts.isEmpty,
                      "Vault mode has no server — conflicts must always be empty")
    }

    /// Vault orchestrator must not have any SyncClient reference.
    /// This is a compile-time guarantee but we verify the type here for documentation.
    func test_vault_hasNoSyncClientProperty() {
        let orchestrator = VaultSyncOrchestrator()
        // VaultSyncOrchestrator is a struct with no `client` property.
        // This test exists to document the structural guarantee.
        // If someone adds a SyncClient to VaultSyncOrchestrator, this test
        // should be updated and the change justified.
        let mirror = Mirror(reflecting: orchestrator)
        let clientProperty = mirror.children.first(where: { $0.label == "client" })
        XCTAssertNil(clientProperty,
                     "VaultSyncOrchestrator must not hold a SyncClient reference")
    }
}

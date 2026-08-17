import XCTest
import SwiftData
@testable import YourPods

/// Tests for centralized conflict delivery + persistence.
///
/// Root cause R3: conflicts are lost if the user dismisses the app or
/// the sync sheet doesn't appear. R7-default: non-.ask strategies
/// must suppress conflict UI.
@MainActor
final class ConflictDeliveryTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var playerManager: PlayerManager!
    private var audioManager: AudioManager!
    private var settingsManager: SettingsManager!
    private var downloadManager: DownloadManager!
    private let testProfileId = "test-conflict-delivery"
    private var conflictFileURL: URL!

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        podcastManager = PodcastManager(modelContext: context)
        settingsManager = SettingsManager()
        downloadManager = DownloadManager()
        playerManager.podcastManager = podcastManager
        playerManager.settingsManager = settingsManager
        podcastManager.playerManager = playerManager
        podcastManager.downloadManager = downloadManager
        podcastManager.settingsManager = settingsManager

        conflictFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-conflicts-\(UUID().uuidString).json")
    }

    override func tearDown() {
        clearTestDefaults()
        try? FileManager.default.removeItem(at: conflictFileURL)
        downloadManager = nil
        settingsManager = nil
        playerManager = nil
        audioManager = nil
        podcastManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "syncConflictStrategy",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Helpers

    private func makeConflict(guid: String, localPos: Int = 100, serverPos: Int = 500,
                               serverTimestamp: Int = 1000, count: Int = 1) -> SyncConflict {
        SyncConflict(
            episodeGuid: guid,
            episodeTitle: "Episode \(guid)",
            podcastTitle: "Podcast",
            podcastUrl: "https://example.com/pod",
            artworkUrl: nil,
            audioUrl: "https://example.com/\(guid).mp3",
            localPosition: localPos,
            serverPosition: serverPos,
            serverTimestamp: serverTimestamp,
            totalDuration: 3600,
            occurrenceCount: count
        )
    }

    // MARK: - 3.1 deliverConflicts

    /// deliverConflicts must append without overwriting unrelated pending conflicts.
    func test_deliverConflicts_appends_withoutOverwritingUnrelatedPending() {
        let existing = makeConflict(guid: "ep-1")
        playerManager.pendingConflicts = [existing]

        let newConflict = makeConflict(guid: "ep-2")
        playerManager.deliverConflicts([newConflict], strategy: .ask)

        XCTAssertEqual(playerManager.pendingConflicts.count, 2,
                       "deliverConflicts must append, not overwrite")
        XCTAssertNotNil(playerManager.pendingConflicts.first(where: { $0.episodeGuid == "ep-1" }))
        XCTAssertNotNil(playerManager.pendingConflicts.first(where: { $0.episodeGuid == "ep-2" }))
    }

    /// deliverConflicts must deduplicate by guid, keeping the newer serverTimestamp.
    func test_deliverConflicts_dedupesByGuid_keepingNewerServerTimestamp() {
        let old = makeConflict(guid: "ep-1", serverTimestamp: 1000)
        playerManager.pendingConflicts = [old]

        let newer = makeConflict(guid: "ep-1", serverPos: 800, serverTimestamp: 2000)
        playerManager.deliverConflicts([newer], strategy: .ask)

        XCTAssertEqual(playerManager.pendingConflicts.count, 1,
                       "Same guid must be deduped")
        XCTAssertEqual(playerManager.pendingConflicts.first?.serverTimestamp, 2000,
                       "Must keep the newer server timestamp")
    }

    /// deliverConflicts must be a no-op when strategy is .serverWins.
    func test_deliverConflicts_noOp_whenStrategyServerWins() {
        let conflict = makeConflict(guid: "ep-1")
        playerManager.deliverConflicts([conflict], strategy: .serverWins)

        XCTAssertTrue(playerManager.pendingConflicts.isEmpty,
                      "Must not deliver conflicts when strategy is .serverWins")
    }

    /// deliverConflicts must be a no-op when strategy is .deviceWins.
    func test_deliverConflicts_noOp_whenStrategyDeviceWins() {
        let conflict = makeConflict(guid: "ep-1")
        playerManager.deliverConflicts([conflict], strategy: .deviceWins)

        XCTAssertTrue(playerManager.pendingConflicts.isEmpty,
                      "Must not deliver conflicts when strategy is .deviceWins")
    }

    /// bypassStrategyGate delivers regardless of strategy.
    func test_deliverConflicts_bypassGate_deliversRegardlessOfStrategy() {
        let conflict = makeConflict(guid: "ep-1")
        playerManager.deliverConflicts([conflict], strategy: .serverWins, bypassStrategyGate: true)

        XCTAssertEqual(playerManager.pendingConflicts.count, 1,
                       "Bypass gate must deliver regardless of strategy")
    }

    // MARK: - 3.2 Persistence

    /// SyncConflict must be Codable.
    func test_syncConflict_isCodable() throws {
        let conflict = makeConflict(guid: "ep-1", localPos: 100, serverPos: 500,
                                     serverTimestamp: 1234, count: 3)
        let data = try JSONEncoder().encode(conflict)
        let decoded = try JSONDecoder().decode(SyncConflict.self, from: data)
        XCTAssertEqual(decoded.episodeGuid, "ep-1")
        XCTAssertEqual(decoded.localPosition, 100)
        XCTAssertEqual(decoded.serverPosition, 500)
        XCTAssertEqual(decoded.serverTimestamp, 1234)
        XCTAssertEqual(decoded.occurrenceCount, 3)
    }

    // MARK: - 3.3 Default strategy verification

    /// SettingsManager default strategy must be .ask.
    func test_settingsManager_defaultStrategy_isAsk() {
        let fresh = SettingsManager()
        XCTAssertEqual(fresh.syncConflictStrategy, .ask,
                       "Default sync conflict strategy must be .ask")
    }
}

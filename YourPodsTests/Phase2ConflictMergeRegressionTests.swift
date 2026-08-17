import XCTest
@testable import YourPods

/// Regression tests for the server-conflict merge (ProSyncOrchestrator Step 5f).
///
/// **URL-rewrite delivery (HIGH):** server URL rewrites were appended to `pendingUrlRewrites` with
/// NO `syncConflictStrategy` gate and NO dedup — violating the "respect syncConflictStrategy
/// in all code paths" hard rule, producing duplicate `Identifiable` ids (oldUrl) that break
/// the SwiftUI conflict list, and a sheet that re-pops forever after the user taps "Keep local".
///
/// **Server position conflict dedup (MED):** server position conflicts were de-duped against locally-detected
/// conflicts by testing the server's audio URL against a `Set` of local *GUIDs* (URL != GUID),
/// so the guard never fired and the same episode produced two rows in the Sync Conflicts sheet.
@MainActor
final class Phase2ConflictMergeRegressionTests: XCTestCase {

    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!

    override func setUp() {
        super.setUp()
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
    }

    override func tearDown() {
        playerManager = nil
        audioManager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func rewrite(_ old: String, _ new: String) -> URLRewriteConflict {
        URLRewriteConflict(oldUrl: old, newUrl: new, podcastTitle: nil, artworkUrl: nil)
    }

    private func localConflict(guid: String, audioUrl: String) -> SyncConflict {
        SyncConflict(
            episodeGuid: guid, episodeTitle: "T", podcastTitle: "P",
            podcastUrl: "https://example.com/pod", artworkUrl: nil, audioUrl: audioUrl,
            localPosition: 100, serverPosition: 500, serverTimestamp: 1000,
            totalDuration: 3600, occurrenceCount: 1
        )
    }

    /// The server keys conflicts by episodeUrl and sends no numeric id — the `id:`
    /// parameter is retained only so the call sites below still read as distinct rows.
    private func serverConflict(id: Int, episodeUrl: String) -> ProServerConflict {
        ProServerConflict(
            episodeUrl: episodeUrl, podcastUrl: "https://example.com/pod",
            localPosition: 100, serverPosition: 500, duration: 3600,
            deviceId: "yourpods-iPhone-test", serverCompleted: nil, occurrenceCount: 1,
            updatedAt: nil, episodeTitle: nil, podcastTitle: nil, artUrl: nil
        )
    }

    // MARK: - deliverUrlRewrites respects strategy + dedups

    func test_deliverUrlRewrites_noOp_whenStrategyServerWins() {
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .serverWins)
        XCTAssertTrue(playerManager.pendingUrlRewrites.isEmpty,
            "URL rewrites must not surface when strategy is .serverWins (user opted out of prompts)")
    }

    func test_deliverUrlRewrites_noOp_whenStrategyDeviceWins() {
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .deviceWins)
        XCTAssertTrue(playerManager.pendingUrlRewrites.isEmpty,
            "URL rewrites must not surface when strategy is .deviceWins")
    }

    func test_deliverUrlRewrites_appends_whenStrategyAsk() {
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .ask)
        XCTAssertEqual(playerManager.pendingUrlRewrites.map(\.oldUrl), ["a"])
    }

    func test_deliverUrlRewrites_dedupesByOldUrl_acrossCalls() {
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .ask)
        // Next sync returns the same unresolved rewrite again:
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .ask)
        XCTAssertEqual(playerManager.pendingUrlRewrites.count, 1,
            "Same oldUrl must not be appended twice — duplicate Identifiable id breaks the SwiftUI list")
    }

    func test_deliverUrlRewrites_skipsRejected() {
        playerManager.recordRejectedUrlRewrite(oldUrl: "a")
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .ask)
        XCTAssertTrue(playerManager.pendingUrlRewrites.isEmpty,
            "A rewrite the user rejected must not re-surface on the next sync (no re-pop-forever)")
    }

    func test_recordRejectedUrlRewrite_removesFromPending() {
        playerManager.deliverUrlRewrites([rewrite("a", "b")], strategy: .ask)
        playerManager.recordRejectedUrlRewrite(oldUrl: "a")
        XCTAssertTrue(playerManager.pendingUrlRewrites.isEmpty,
            "Rejecting a rewrite must remove it from the pending list immediately")
    }

    // MARK: - Server position conflicts dedup against local by audio URL

    func test_mergeServerConflicts_dedupesAgainstLocal_byAudioUrl() {
        let url = "https://example.com/ep1.mp3"
        let local = [localConflict(guid: "real-guid-1", audioUrl: url)]
        let server = [serverConflict(id: 7, episodeUrl: url)]  // server keys by audio URL
        let merged = ProSyncOrchestrator.mergedServerPositionConflicts(local: local, server: server)
        XCTAssertTrue(merged.isEmpty,
            "Server conflict for the same episode (audioUrl) as a local conflict must be deduped — not shown twice")
    }

    func test_mergeServerConflicts_keepsServerOnlyConflict() {
        let server = [serverConflict(id: 7, episodeUrl: "https://example.com/only.mp3")]
        let merged = ProSyncOrchestrator.mergedServerPositionConflicts(local: [], server: server)
        XCTAssertEqual(merged.count, 1, "A server-only conflict must still be surfaced")
        XCTAssertNil(merged.first?.serverConflictId,
            "The server sends no numeric id — conflict resolution carries the position itself, not a row pointer")
        XCTAssertEqual(merged.first?.localPosition, 100,
            "The server's localPosition must survive the merge; it is what the sheet offers as this device's position")
        XCTAssertEqual(merged.first?.serverPosition, 500)
    }

    func test_mergeServerConflicts_dedupesByGuidFallback() {
        // Edge: server conflict's episodeUrl matches a local conflict's GUID (fallback key).
        let local = [localConflict(guid: "shared-key", audioUrl: "https://example.com/x.mp3")]
        let server = [serverConflict(id: 9, episodeUrl: "shared-key")]
        let merged = ProSyncOrchestrator.mergedServerPositionConflicts(local: local, server: server)
        XCTAssertTrue(merged.isEmpty, "GUID-keyed dedup must still work as a fallback")
    }
}

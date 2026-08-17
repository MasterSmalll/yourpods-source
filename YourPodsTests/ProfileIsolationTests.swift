import XCTest
import SwiftData
@testable import YourPods

/// Profile isolation for the episode action map + completion outbox.
///
/// Root cause (2026-06-23): the action map (`episodeActionMap.json`) and completion
/// outbox were GLOBAL singletons shared by every profile. Switching or deleting a
/// profile left the prior profile's positions in the shared store, which then drove
/// spurious conflicts on the next pull — and a manual resolution uploaded the stale
/// position straight to the active profile's server (e.g. Nextcloud), leaking it to a
/// linked web account.
///
/// Fix: scope both files per profile, swap in-memory state on `switchProfile`, delete
/// scoped files on profile deletion, and migrate the legacy global file to the active
/// profile once.
@MainActor
final class ProfileIsolationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var profileA: String!
    private var profileB: String!
    private var currentProfile: String!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        profileA = "isoTestA-\(UUID().uuidString)"
        profileB = "isoTestB-\(UUID().uuidString)"
        currentProfile = profileA
        removeLegacyAndScopedFiles()
    }

    override func tearDown() {
        removeLegacyAndScopedFiles()
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func removeLegacyAndScopedFiles() {
        let fm = FileManager.default
        let urls = [
            EpisodeActionSyncService.actionMapFileURL,
            EpisodeActionSyncService.actionMapFileURL.appendingPathExtension("bak"),
            EpisodeActionSyncService.actionMapFileURL(forProfile: profileA),
            EpisodeActionSyncService.actionMapFileURL(forProfile: profileA).appendingPathExtension("bak"),
            EpisodeActionSyncService.actionMapFileURL(forProfile: profileB),
            EpisodeActionSyncService.completionOutboxFileURL(forProfile: nil),
            EpisodeActionSyncService.completionOutboxFileURL(forProfile: profileA),
            EpisodeActionSyncService.completionOutboxFileURL(forProfile: profileB),
        ]
        for url in urls { try? fm.removeItem(at: url) }
    }

    private func makeService() -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { self.currentProfile },
            deviceIdProvider: { "iso-device" }
        )
    }

    private func makeAction(guid: String = "g1", position: Int) -> EpisodeAction {
        EpisodeAction(
            podcast: "https://example.com/feed.xml",
            episode: "https://example.com/ep-\(guid).mp3",
            guid: guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: position,
            started: 0,
            total: 3600,
            device: "iso-device"
        )
    }

    private func makePending(guid: String) -> PendingCompletion {
        PendingCompletion(
            podcastUrl: "https://example.com/feed.xml",
            episodeUrl: "https://example.com/ep-\(guid).mp3",
            episodeGuid: guid,
            durationSec: 3600,
            eventTime: Date()
        )
    }

    // MARK: - Action map isolation

    /// Switching profiles must not let one profile see another's positions, and each
    /// profile's positions must survive a round-trip switch.
    func test_actionMap_isolatedBetweenProfiles() {
        let service = makeService()
        service.loadActionMap()
        service.replaceActionMap(["g1": makeAction(position: 100)])
        XCTAssertEqual(service.actionMap["g1"]?.position, 100)

        service.switchProfile(to: profileB)
        XCTAssertTrue(service.actionMap.isEmpty,
                      "Profile B must not see Profile A's positions")

        service.switchProfile(to: profileA)
        XCTAssertEqual(service.actionMap["g1"]?.position, 100,
                       "Profile A's positions must survive a round-trip switch")
    }

    // MARK: - Completion outbox isolation

    func test_completionOutbox_isolatedBetweenProfiles() {
        let service = makeService()
        service.loadActionMap()         // resolves the active profile for scoped paths
        service.loadCompletionOutbox()
        service.enqueueCompletion(makePending(guid: "c1"))
        XCTAssertEqual(service.completionOutbox.count, 1)

        service.switchProfile(to: profileB)
        XCTAssertTrue(service.completionOutbox.isEmpty,
                      "Profile B must not drain Profile A's pending completions")

        service.switchProfile(to: profileA)
        XCTAssertEqual(service.completionOutbox["c1"]?.episodeGuid, "c1",
                       "Profile A's pending completions must survive a round-trip switch")
    }

    // MARK: - Profile deletion

    func test_deleteProfileFiles_removesScopedFiles_andClearsActiveMemory() {
        let service = makeService()
        service.loadActionMap()
        service.replaceActionMap(["g1": makeAction(position: 50)])
        let aURL = EpisodeActionSyncService.actionMapFileURL(forProfile: profileA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aURL.path))

        service.deleteProfileFiles(forProfileId: profileA)

        XCTAssertFalse(FileManager.default.fileExists(atPath: aURL.path),
                       "Deleting a profile must remove its scoped action map file")
        XCTAssertTrue(service.actionMap.isEmpty,
                      "Deleting the active profile must clear its in-memory map")
    }

    func test_deleteProfileFiles_doesNotAffectOtherProfile() {
        let service = makeService()
        service.loadActionMap()
        service.replaceActionMap(["g1": makeAction(guid: "g1", position: 10)])
        service.switchProfile(to: profileB)
        service.replaceActionMap(["g2": makeAction(guid: "g2", position: 20)])
        let bURL = EpisodeActionSyncService.actionMapFileURL(forProfile: profileB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bURL.path))

        service.deleteProfileFiles(forProfileId: profileA)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bURL.path),
                      "Deleting Profile A must not remove Profile B's file")
        XCTAssertEqual(service.actionMap["g2"]?.position, 20,
                       "Active Profile B's in-memory map must be untouched")
    }

    // MARK: - Legacy migration

    func test_legacyMigration_adoptsGlobalFileForActiveNamedProfile() {
        // Seed a pre-scoping global (unsuffixed) action map file.
        let legacyURL = EpisodeActionSyncService.actionMapFileURL
        let legacyData = try! JSONEncoder().encode(["leg1": makeAction(guid: "leg1", position: 77)])
        try! FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! legacyData.write(to: legacyURL)

        let service = makeService()     // active profile is the named profileA
        service.loadActionMap()

        XCTAssertEqual(service.actionMap["leg1"]?.position, 77,
                       "Active profile must adopt the legacy global action map")
        let scopedURL = EpisodeActionSyncService.actionMapFileURL(forProfile: profileA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedURL.path),
                      "Legacy map must be migrated to the profile-scoped file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "Legacy global file must be removed after migration")
    }
}

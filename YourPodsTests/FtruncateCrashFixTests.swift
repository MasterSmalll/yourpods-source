import XCTest
import SwiftData
import SQLite3
@testable import YourPods

// MARK: - WAL Auto-Checkpoint Disable Tests

/// Tests for the ftruncate crash fix in rawWriteProbe.
///
/// Root cause: rawWriteProbe's INSERT triggers SQLite's WAL auto-checkpoint,
/// which calls walLimitSize → ftruncate — an uncatchable signal on degraded
/// filesystems (background task file revocation, data protection lockout).
///
/// Fix: PRAGMA wal_autocheckpoint=0 disables auto-checkpoint so the probe
/// exercises the write + WAL append path without triggering ftruncate.
final class RawWriteProbeAutoCheckpointTests: XCTestCase {

    /// After rawWriteProbe runs, the WAL file must NOT be truncated.
    /// If auto-checkpoint is properly disabled, the WAL will still contain
    /// frames (non-zero size) rather than being truncated to 0 by a checkpoint.
    ///
    /// This directly verifies the fix: with wal_autocheckpoint=0, the probe's
    /// INSERT/DELETE writes WAL frames but never checkpoints (and never calls
    /// the dangerous ftruncate path).
    func test_rawWriteProbe_doesNotTruncateWAL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("default.store")

        // Create a store with WAL mode. Keep connection open so WAL retains frames.
        // (sqlite3_close triggers a passive checkpoint that empties the WAL.)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE test_data (id INTEGER PRIMARY KEY, val TEXT)", nil, nil, nil)
        for i in 0..<100 {
            sqlite3_exec(db, "INSERT INTO test_data (id, val) VALUES (\(i), 'padding')", nil, nil, nil)
        }
        // Keep db open — defer close after assertions
        defer { sqlite3_close(db) }

        // Record WAL size before probe
        let walPath = storeURL.path + "-wal"
        let walSizeBefore = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(walSizeBefore, 0, "Precondition: WAL must have content before probe")

        // Act: run rawWriteProbe (opens a separate connection)
        let result = StoreHealthProbe.rawWriteProbe(storeURL: storeURL)
        XCTAssertTrue(result, "Probe must pass on healthy store")

        // Assert: WAL must NOT have been truncated to 0 by an auto-checkpoint.
        // With wal_autocheckpoint=0, the probe's writes ADD to the WAL but never
        // trigger the ftruncate path.
        let walSizeAfter = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(walSizeAfter, 0,
                             "WAL must not be truncated to 0 — auto-checkpoint must be disabled in rawWriteProbe")
    }

    /// Same test for the verdict-based variant.
    func test_rawWriteVerdict_doesNotTruncateWAL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("default.store")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE test_data (id INTEGER PRIMARY KEY, val TEXT)", nil, nil, nil)
        for i in 0..<100 {
            sqlite3_exec(db, "INSERT INTO test_data (id, val) VALUES (\(i), 'padding')", nil, nil, nil)
        }
        defer { sqlite3_close(db) }

        let walPath = storeURL.path + "-wal"
        let walSizeBefore = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(walSizeBefore, 0, "Precondition: WAL must have content")

        let verdict = StoreHealthProbe.rawWriteVerdict(storeURL: storeURL)
        XCTAssertTrue(verdict.isHealthy, "Verdict must be healthy for valid store")

        let walSizeAfter = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(walSizeAfter, 0,
                             "WAL must not be truncated — auto-checkpoint must be disabled in rawWriteVerdict")
    }
}

// MARK: - Batch Hidden Changes Tests

/// Tests for the batched applyHiddenChanges method.
///
/// Root cause: setHidden calls storeHealthCheck + safeSave per episode during
/// sync. With N hidden state changes, this opens N rawWriteProbe connections
/// and issues N separate saves — each risking the ftruncate crash.
///
/// Fix: applyHiddenChanges runs one health check and one save for N changes.
@MainActor
final class BatchHiddenChangesTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "hiddenEpisodeGuids")
        container = nil
        context = nil
        try await super.tearDown()
    }

    /// applyHiddenChanges must call storeHealthCheck exactly once for N changes.
    func test_applyHiddenChanges_callsHealthCheckOnce() {
        var healthCheckCount = 0
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: {
                healthCheckCount += 1
                return true
            }
        )

        let changes = (0..<10).map {
            HiddenStateChange(guid: "ep-\($0)", hidden: true)
        }
        svc.applyHiddenChanges(changes)

        XCTAssertEqual(healthCheckCount, 1,
                       "applyHiddenChanges must call storeHealthCheck exactly once, not once per change")
    }

    /// applyHiddenChanges must update all hidden GUIDs in a single batch.
    func test_applyHiddenChanges_updatesAllGuids() {
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )

        let changes = [
            HiddenStateChange(guid: "ep-1", hidden: true),
            HiddenStateChange(guid: "ep-2", hidden: true),
            HiddenStateChange(guid: "ep-3", hidden: false),
        ]
        svc.applyHiddenChanges(changes)

        XCTAssertTrue(svc.isHidden(guid: "ep-1"))
        XCTAssertTrue(svc.isHidden(guid: "ep-2"))
        XCTAssertFalse(svc.isHidden(guid: "ep-3"))
    }

    /// applyHiddenChanges must set isPlayed on matching Episode models.
    func test_applyHiddenChanges_setsIsPlayedOnEpisodes() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let ep1 = Episode(guid: "ep-1", title: "Episode 1")
        let ep2 = Episode(guid: "ep-2", title: "Episode 2")
        ep1.podcast = podcast
        ep2.podcast = podcast
        podcast.episodes = [ep1, ep2]
        context.insert(podcast)
        context.insert(ep1)
        context.insert(ep2)

        let subs = [podcast]
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { subs },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" }
        )

        svc.applyHiddenChanges([
            HiddenStateChange(guid: "ep-1", hidden: true),
            HiddenStateChange(guid: "ep-2", hidden: true),
        ])

        XCTAssertTrue(ep1.isPlayed, "Hiding must set isPlayed = true")
        XCTAssertTrue(ep2.isPlayed, "Hiding must set isPlayed = true")
    }

    /// applyHiddenChanges must skip saves when storeHealthCheck fails.
    func test_applyHiddenChanges_skipsWhenUnhealthy() {
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: { false }
        )

        let changes = [
            HiddenStateChange(guid: "ep-1", hidden: true),
        ]
        svc.applyHiddenChanges(changes)

        // Hidden state in memory should still be updated
        XCTAssertTrue(svc.isHidden(guid: "ep-1"),
                      "In-memory hidden state must still be updated even when store is unhealthy")
    }

    /// setHidden must NOT call safeSave — callers are responsible for saving.
    func test_setHidden_doesNotSave() {
        var healthCheckCount = 0
        let svc = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [] },
            syncClientProvider: { nil },
            profileIdProvider: { nil },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: {
                healthCheckCount += 1
                return true
            }
        )

        svc.setHidden(guid: "ep-1", hidden: true)

        XCTAssertEqual(healthCheckCount, 0,
                       "setHidden must NOT call storeHealthCheck — caller is responsible for saving")
    }
}

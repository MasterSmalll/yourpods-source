import XCTest
import SQLite3
@testable import YourPods

/// Tests for rawWriteProbe hardening (reduced write surface + lock tolerance).
///
/// Context: a worst-case Pro sync runs the probe a dozen-plus times. Each run
/// previously executed CREATE TABLE + INSERT + DELETE + DROP TABLE — four raw
/// write transactions, two of which mutate sqlite_master. Schema churn bumps
/// the schema cookie and forces SQLITE_SCHEMA re-preparation on Core Data's
/// live connection, and every extra write transaction is another suspension-
/// kill window (0xDEAD10CC).
final class ProbeHardeningTests: XCTestCase {

    private var tempDir: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("default.store")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE seed (id INTEGER PRIMARY KEY)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO seed (id) VALUES (1)", nil, nil, nil)
        sqlite3_close(db)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        storeURL = nil
        super.tearDown()
    }

    /// Read PRAGMA schema_version (the schema cookie Core Data watches).
    private func schemaVersion() -> Int32 {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA schema_version", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Schema Churn

    /// After the first run creates the probe table, repeat runs must not touch
    /// sqlite_master at all: no DROP, no re-CREATE. Schema cookie stays stable.
    func test_rawWriteProbe_doesNotMutateSchema_afterFirstRun() {
        // First run may create the persistent probe table (one-time schema change).
        XCTAssertTrue(StoreHealthProbe.rawWriteProbe(storeURL: storeURL))
        let versionAfterFirstRun = schemaVersion()

        // Repeat runs must leave the schema cookie untouched.
        XCTAssertTrue(StoreHealthProbe.rawWriteProbe(storeURL: storeURL))
        XCTAssertTrue(StoreHealthProbe.rawWriteProbe(storeURL: storeURL))

        XCTAssertEqual(schemaVersion(), versionAfterFirstRun,
                       "Repeat probes must not mutate sqlite_master — schema churn forces SQLITE_SCHEMA re-preparation on Core Data's live connection")
    }

    /// Same contract for the verdict-based variant.
    func test_rawWriteVerdict_doesNotMutateSchema_afterFirstRun() {
        XCTAssertTrue(StoreHealthProbe.rawWriteVerdict(storeURL: storeURL).isHealthy)
        let versionAfterFirstRun = schemaVersion()

        XCTAssertTrue(StoreHealthProbe.rawWriteVerdict(storeURL: storeURL).isHealthy)

        XCTAssertEqual(schemaVersion(), versionAfterFirstRun,
                       "Repeat verdict probes must not mutate sqlite_master")
    }

    // MARK: - Lock Tolerance

    /// EDGE: A brief write lock held by another connection (Core Data mid-commit)
    /// must not fail the probe. Without a busy timeout, SQLITE_BUSY returns
    /// immediately and guardedSave silently skips legitimate saves.
    func test_rawWriteProbe_toleratesBriefWriteLock() {
        // Hold the write lock from a second connection for ~50ms.
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let releaseLock = DispatchWorkItem {
            sqlite3_exec(blocker, "COMMIT", nil, nil, nil)
            sqlite3_close(blocker)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: releaseLock)

        // Probe must wait out the brief lock instead of failing immediately.
        let result = StoreHealthProbe.rawWriteProbe(storeURL: storeURL)
        releaseLock.wait()

        XCTAssertTrue(result,
                      "Probe must tolerate a brief write lock via busy timeout — immediate SQLITE_BUSY causes silently skipped saves")
    }
}

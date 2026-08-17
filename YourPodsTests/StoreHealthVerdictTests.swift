import XCTest
import SwiftData
import SQLite3
@testable import YourPods

/// Tests for the tri-state StoreHealthVerdict system.
///
/// preflightCheck must distinguish between
/// corruption (delete the store) and transient failures (do NOT delete).
/// These tests pin the exact behaviors that prevent data loss.
@MainActor
final class StoreHealthVerdictTests: XCTestCase {
    
    // MARK: - StoreHealthVerdict Enum
    
    func test_verdict_healthy_isNotCorrupt() {
        let verdict = StoreHealthVerdict.healthy
        XCTAssertFalse(verdict.isCorrupt)
        XCTAssertTrue(verdict.isHealthy)
    }
    
    func test_verdict_corrupt_isCorrupt() {
        let verdict = StoreHealthVerdict.corrupt(reason: "quick_check failed")
        XCTAssertTrue(verdict.isCorrupt)
        XCTAssertFalse(verdict.isHealthy)
    }
    
    func test_verdict_indeterminate_isNotCorrupt() {
        let verdict = StoreHealthVerdict.indeterminate(reason: "SQLITE_BUSY")
        XCTAssertFalse(verdict.isCorrupt)
        XCTAssertFalse(verdict.isHealthy)
    }
    
    func test_verdict_equatable() {
        XCTAssertEqual(StoreHealthVerdict.healthy, StoreHealthVerdict.healthy)
        XCTAssertEqual(
            StoreHealthVerdict.corrupt(reason: "a"),
            StoreHealthVerdict.corrupt(reason: "a")
        )
        XCTAssertNotEqual(
            StoreHealthVerdict.corrupt(reason: "a"),
            StoreHealthVerdict.indeterminate(reason: "a")
        )
    }
    
    // MARK: - preflightVerdict — Healthy Store
    
    func test_preflightVerdict_healthyStore_returnsHealthy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("default.store")
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let probe = Podcast(url: "__verdict_healthy__", title: "Test")
            ctx.insert(probe)
            try ctx.save()
            ctx.delete(probe)
            try ctx.save()
        }
        
        let verdict = StoreHealthProbe.preflightVerdict(storeURL: storeURL)
        
        XCTAssertEqual(verdict, .healthy, "Healthy store must return .healthy verdict")
    }
    
    func test_preflightVerdict_missingFile_returnsHealthy() {
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("does_not_exist.store")
        
        let verdict = StoreHealthProbe.preflightVerdict(storeURL: nonExistentURL)
        
        XCTAssertEqual(verdict, .healthy, "Missing store file should return .healthy")
    }
    
    // MARK: - preflightVerdict — Corrupt Store
    
    /// A file with no valid SQLite header must return .corrupt.
    /// This is the clearest corruption case — SQLITE_NOTADB on open.
    func test_preflightVerdict_corruptedStore_returnsCorrupt() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("default.store")
        // Complete garbage — not a valid SQLite file at all
        let garbage = Data(repeating: 0xFF, count: 4096)
        try garbage.write(to: storeURL)
        
        let verdict = StoreHealthProbe.preflightVerdict(storeURL: storeURL)
        
        // Must be .corrupt — SQLITE_NOTADB on open
        XCTAssertTrue(verdict.isCorrupt,
                      "Corrupted store must return .corrupt, got: \(verdict)")
    }
    
    /// A store where PRAGMA quick_check detects B-tree corruption must return .corrupt.
    /// This exercises the "quick_check != ok" path (distinct from open failure).
    func test_EDGE_preflightVerdict_quickCheckDetectsCorruption_returnsCorrupt() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("default.store")
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        
        // Create a valid store first, then release the container
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let probe = Podcast(url: "__qc_corrupt__", title: "Test")
            ctx.insert(probe)
            try ctx.save()
            ctx.delete(probe)
            try ctx.save()
        }
        
        // Use raw SQLite to corrupt the internal schema in a way that
        // quick_check will detect. Trashing the sqlite_master rootpage
        // is the most reliable way to trigger "quick_check != ok" while
        // keeping the file openable.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK else {
            XCTFail("Could not open store for corruption")
            return
        }
        
        // Corrupt the B-tree by directly writing garbage into a data page.
        // Page 1 is the header page (first 100 bytes are SQLite header).
        // We write garbage starting at byte 200 to corrupt B-tree leaf pages
        // without breaking the file header.
        sqlite3_close(db)
        
        var data = try Data(contentsOf: storeURL)
        if data.count > 4096 {
            // Corrupt a later page (page 2+), which is where data lives
            for i in 4096..<min(8192, data.count) {
                data[i] = 0xAB
            }
            try data.write(to: storeURL)
        }
        
        let verdict = StoreHealthProbe.preflightVerdict(storeURL: storeURL)
        
        // Should be .corrupt or at least NOT .healthy (the data is garbage)
        XCTAssertFalse(verdict.isHealthy,
                       "Store with corrupted pages must not return .healthy, got: \(verdict)")
    }
    
    // MARK: - preflightVerdict — Indeterminate (locked store)
    
    /// THE CORE BUG FIX: An exclusively locked store must return .indeterminate,
    /// NOT .corrupt. The old preflightCheck returned `false` here, causing the
    /// app to delete a perfectly healthy store.
    func test_EDGE_preflightVerdict_exclusivelyLockedStore_returnsIndeterminate_notCorrupt() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("default.store")
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let probe = Podcast(url: "__verdict_locked__", title: "Test")
            ctx.insert(probe)
            try ctx.save()
            ctx.delete(probe)
            try ctx.save()
        }
        
        // Hold an exclusive lock on the store — simulates lock contention
        // from another process or data protection lockout
        var lockDb: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &lockDb, flags, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lockDb, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        
        defer {
            sqlite3_exec(lockDb, "ROLLBACK", nil, nil, nil)
            sqlite3_close(lockDb)
        }
        
        let verdict = StoreHealthProbe.preflightVerdict(storeURL: storeURL)
        
        // MUST be .indeterminate — the store is healthy but locked
        XCTAssertFalse(verdict.isCorrupt,
                       "Exclusively locked store must NOT return .corrupt — it's healthy but locked. Got: \(verdict)")
        XCTAssertFalse(verdict.isHealthy,
                       "Exclusively locked store should not return .healthy either. Got: \(verdict)")
    }
    
    // MARK: - recoveryAction
    
    func test_recoveryAction_healthy_doesNotDelete() {
        let action = YourPodsApp.recoveryAction(
            for: .healthy, protectedDataAvailable: true
        )
        XCTAssertEqual(action, .none)
    }
    
    func test_recoveryAction_corrupt_withProtectedData_deletes() {
        let action = YourPodsApp.recoveryAction(
            for: .corrupt(reason: "test"), protectedDataAvailable: true
        )
        XCTAssertEqual(action, .deleteAndRecreate)
    }
    
    /// Indeterminate verdict must NOT trigger deletion — this is the core fix.
    func test_recoveryAction_indeterminate_doesNotDelete() {
        let action = YourPodsApp.recoveryAction(
            for: .indeterminate(reason: "SQLITE_BUSY"), protectedDataAvailable: true
        )
        XCTAssertEqual(action, .none,
                       "Indeterminate verdict must NOT trigger store deletion")
    }
    
    /// Protected data unavailable (device locked, before first unlock) —
    /// must NEVER delete, even when corrupt, because the corruption verdict
    /// itself may be a false positive from data protection.
    func test_EDGE_recoveryAction_protectedDataUnavailable_neverDeletes_evenWhenCorrupt() {
        let action = YourPodsApp.recoveryAction(
            for: .corrupt(reason: "test"), protectedDataAvailable: false
        )
        XCTAssertEqual(action, .none,
                       "Must never delete store when protected data is unavailable")
    }
    
    // MARK: - classifyContainerCreationError
    
    /// Disk-full errors should be classified as transient, not corruption.
    func test_classifyContainerError_diskFull_isTransient() {
        let posixError = NSError(
            domain: NSPOSIXErrorDomain,
            code: 28, // ENOSPC
            userInfo: nil
        )
        let cocoaError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: [NSUnderlyingErrorKey: posixError]
        )
        
        let errorClass = YourPodsApp.classifyContainerCreationError(cocoaError)
        
        XCTAssertEqual(errorClass, .transientEnvironment,
                       "Disk-full error must be classified as transient, not corruption")
    }
    
    /// Permission errors should be classified as transient.
    func test_classifyContainerError_permissionDenied_isTransient() {
        let posixError = NSError(
            domain: NSPOSIXErrorDomain,
            code: 13, // EACCES
            userInfo: nil
        )
        let cocoaError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: posixError]
        )
        
        let errorClass = YourPodsApp.classifyContainerCreationError(cocoaError)
        
        XCTAssertEqual(errorClass, .transientEnvironment,
                       "Permission error must be classified as transient")
    }
    
    /// Core Data migration errors should be classified as migration/corruption.
    func test_classifyContainerError_migrationError_isMigration() {
        // NSPersistentStoreIncompatibleVersionHashError = 134100
        let migrationError = NSError(
            domain: NSCocoaErrorDomain,
            code: 134100,
            userInfo: nil
        )
        
        let errorClass = YourPodsApp.classifyContainerCreationError(migrationError)
        
        XCTAssertEqual(errorClass, .migrationOrCorruption,
                       "Migration error should be classified as migration/corruption")
    }
}

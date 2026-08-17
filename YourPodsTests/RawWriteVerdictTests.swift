import XCTest
import SwiftData
import SQLite3
@testable import YourPods

/// Tests for the verdict-based write probe.
///
/// `rawWriteVerdict` returns a tri-state verdict instead of a bare Bool,
/// and `guardedSave` uses the verdict to decide: .corrupt → skip,
/// .indeterminate → attempt save anyway, .healthy → save.
@MainActor
final class RawWriteVerdictTests: XCTestCase {
    
    // MARK: - rawWriteVerdict
    
    /// A healthy store must return .healthy verdict.
    func test_rawWriteVerdict_healthyStore_returnsHealthy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("default.store")
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        let podcast = Podcast(url: "__write_verdict_ok__", title: "Test")
        ctx.insert(podcast)
        try ctx.save()
        
        let verdict = StoreHealthProbe.rawWriteVerdict(storeURL: storeURL)
        
        XCTAssertEqual(verdict, .healthy,
                       "Healthy store must return .healthy from rawWriteVerdict")
    }
    
    /// A corrupted store (garbage data pages) must return .corrupt verdict.
    func test_rawWriteVerdict_corruptStore_returnsCorrupt() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("default.store")
        // Complete garbage — not a valid SQLite file
        let garbage = Data(repeating: 0xFF, count: 4096)
        try garbage.write(to: storeURL)
        
        let verdict = StoreHealthProbe.rawWriteVerdict(storeURL: storeURL)
        
        XCTAssertTrue(verdict.isCorrupt,
                      "Corrupted store must return .corrupt, got: \(verdict)")
    }
    
    /// An exclusively locked store must return .indeterminate, not .corrupt.
    /// This is THE core behavior change from the Bool-based rawWriteProbe.
    func test_rawWriteVerdict_lockedStore_returnsIndeterminate() throws {
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
            let probe = Podcast(url: "__write_verdict_locked__", title: "Test")
            ctx.insert(probe)
            try ctx.save()
            ctx.delete(probe)
            try ctx.save()
        }
        
        // Hold an exclusive lock
        var lockDb: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &lockDb, flags, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lockDb, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        
        defer {
            sqlite3_exec(lockDb, "ROLLBACK", nil, nil, nil)
            sqlite3_close(lockDb)
        }
        
        let verdict = StoreHealthProbe.rawWriteVerdict(storeURL: storeURL, busyTimeoutMs: 100)
        
        // Must be indeterminate — the store is healthy but locked
        XCTAssertFalse(verdict.isCorrupt,
                       "Locked store must NOT return .corrupt — it's healthy but locked. Got: \(verdict)")
        XCTAssertFalse(verdict.isHealthy,
                       "Locked store must return .indeterminate, not .healthy. Got: \(verdict)")
    }
    
    // MARK: - guardedSave with Verdict
    
    /// guardedSave must succeed on a healthy store (baseline).
    func test_guardedSave_healthyStore_savesSuccessfully() throws {
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        
        let podcast = Podcast(url: "__guarded_save_ok__", title: "Test")
        ctx.insert(podcast)
        
        // guardedSave with nil storeURL skips the probe
        let result = ctx.guardedSave(storeURL: nil)
        XCTAssertTrue(result, "guardedSave must succeed on healthy in-memory store")
    }
}

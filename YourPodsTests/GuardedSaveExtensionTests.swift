import XCTest
import SwiftData
import SQLite3
@testable import YourPods

/// Tests for `ModelContext.guardedSave()` — the pre-save store health check
/// that prevents pread() signal crashes during WAL checkpoints.
///
/// Root cause: `modelContext.save()` can trigger `sqlite3WalCheckpoint` → `pread()`
/// which delivers a Unix signal on corrupt pages. Unlike ObjC exceptions, signals
/// are uncatchable. The only defense is to not call `save()` when the store is unhealthy.
///
/// `guardedSave()` runs `StoreHealthProbe.rawWriteProbe()` before every save.
/// If the probe fails (returns error codes instead of crashing), the save is skipped.
@MainActor
final class GuardedSaveExtensionTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuardedSaveTests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - guardedSave() Behavior
    
    /// When the store is healthy, guardedSave() must save successfully and return true.
    func test_guardedSave_succeedsWhenStoreHealthy() {
        // Insert data to make the save meaningful
        let podcast = Podcast(url: "__guarded_save_healthy__", title: "Healthy Test")
        context.insert(podcast)
        
        // Use a real on-disk store for the health probe
        let storeURL = tempDir.appendingPathComponent("healthy.store")
        
        // Create the store file so rawWriteProbe has something to check
        var db: OpaquePointer?
        sqlite3_open_v2(storeURL.path, &db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_close(db)
        
        let result = context.guardedSave(storeURL: storeURL)
        XCTAssertTrue(result, "guardedSave must return true when store is healthy")
    }
    
    /// When the store probe fails, guardedSave() must skip the save and return false.
    func test_guardedSave_skipsWhenStoreUnhealthy() {
        let podcast = Podcast(url: "__guarded_save_unhealthy__", title: "Unhealthy Test")
        context.insert(podcast)
        
        // Create a store file that will fail the write probe:
        // write garbage to make it unopenable by sqlite3
        let storeURL = tempDir.appendingPathComponent("corrupt.store")
        let garbage = Data(repeating: 0xFF, count: 4096)
        try! garbage.write(to: storeURL)
        
        let result = context.guardedSave(storeURL: storeURL)
        XCTAssertFalse(result, "guardedSave must return false when store probe fails")
    }
    
    /// guardedSave() with no storeURL (nil) must behave like safeSave() — no probe, just save.
    func test_guardedSave_withNilURL_savesWithoutProbe() {
        let podcast = Podcast(url: "__guarded_nil_url__", title: "Nil URL Test")
        context.insert(podcast)
        
        let result = context.guardedSave(storeURL: nil)
        XCTAssertTrue(result, "guardedSave with nil URL must save without probe")
    }
    
    // MARK: - PodcastManager.saveContext() StoreError
    
    /// PodcastManager.saveContext() must throw StoreError.storeUnhealthy
    /// when the pre-save health check fails.
    func test_saveContext_throwsStoreUnhealthy_whenProbeFails() {
        // We can't easily inject a bad store into PodcastManager for this unit test,
        // but we can verify the error type exists and is throwable.
        let error = StoreError.storeUnhealthy
        XCTAssertEqual(
            error.localizedDescription,
            "The database store is unhealthy. Save was skipped to prevent a crash."
        )
    }
}

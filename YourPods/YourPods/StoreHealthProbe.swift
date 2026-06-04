import SwiftData
import Foundation
import SQLite3

/// Isolated, testable health-probe for the SwiftData store.
///
/// Validates store integrity using the raw sqlite3 C API exclusively.
/// All probes return error codes instead of crashing with `pread()` signals,
/// making them safe to call during `App.init()` before SwiftData opens the file.
///
/// The `run()` / `runInstrumented()` methods are retained for backward
/// compatibility with existing sentinel tests but are no longer called
/// from the production init path.
enum StoreHealthProbe {
    
    /// Run the health probe against `context`.
    ///
    /// - Parameters:
    ///   - context: The `ModelContext` to test.
    ///   - sentinelKey: UserDefaults key used as the crash sentinel.
    /// - Returns: `true` if the store appears corrupted (save threw a Swift error).
    ///   A signal crash during save will kill the process — the sentinel
    ///   will be detected on next launch.
    @MainActor
    static func run(
        context: ModelContext,
        sentinelKey: String
    ) -> Bool {
        return runInstrumented(
            context: context,
            sentinelKey: sentinelKey,
            onBeforeSave: nil
        )
    }
    
    /// Instrumented variant for testing.
    /// Calls `onBeforeSave` after setting the sentinel but before calling `save()`.
    @MainActor
    static func runInstrumented(
        context: ModelContext,
        sentinelKey: String,
        onBeforeSave: (() -> Void)? = nil
    ) -> Bool {
        // Set sentinel BEFORE touching the store.
        // If pread() kills the process during save(), this sentinel
        // will remain set and trigger store deletion on next launch.
        UserDefaults.standard.set(true, forKey: sentinelKey)
        UserDefaults.standard.synchronize()  // Force disk flush before potentially crashing save
        
        let probe = Podcast(url: "__health_check__", title: "")
        context.insert(probe)
        
        // Allow tests to observe the sentinel state before save
        onBeforeSave?()
        
        do {
            try context.save()
            // Clean up the probe record
            context.delete(probe)
            try context.save()
            // Save succeeded — clear sentinel, store is healthy
            UserDefaults.standard.set(false, forKey: sentinelKey)
            return false
        } catch {
            // Save threw a Swift error (not a signal crash).
            // Rollback the dirty insert so it doesn't linger.
            context.rollback()
            // Clear sentinel since the process survived
            UserDefaults.standard.set(false, forKey: sentinelKey)
            return true
        }
    }
    
    // MARK: - Raw Write Probe (sqlite3 C API)
    
    /// Validate that the store can handle writes using the raw sqlite3 C API.
    ///
    /// Unlike `ModelContext.save()`, sqlite3 operations return error codes
    /// instead of crashing with a signal on corrupt pages. This makes the
    /// probe safe to call during app init without risking a pread() crash.
    ///
    /// - Parameter storeURL: Path to the SQLite store file.
    /// - Returns: `true` if a write round-trip (INSERT + DELETE) succeeded.
    static func rawWriteProbe(storeURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return true  // No file = nothing to probe
        }
        
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        
        // Create a disposable probe table if it doesn't exist
        let createSQL = "CREATE TABLE IF NOT EXISTS _health_probe (id INTEGER PRIMARY KEY)"
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        
        // INSERT a test row — exercises the write + WAL path
        let insertSQL = "INSERT INTO _health_probe (id) VALUES (1)"
        guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
            // Cleanup attempt
            sqlite3_exec(db, "DROP TABLE IF EXISTS _health_probe", nil, nil, nil)
            sqlite3_close(db)
            return false
        }
        
        // DELETE the test row — exercises the delete path
        let deleteSQL = "DELETE FROM _health_probe WHERE id = 1"
        guard sqlite3_exec(db, deleteSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "DROP TABLE IF EXISTS _health_probe", nil, nil, nil)
            sqlite3_close(db)
            return false
        }
        
        // Drop the probe table so it doesn't pollute the schema
        sqlite3_exec(db, "DROP TABLE IF EXISTS _health_probe", nil, nil, nil)
        sqlite3_close(db)
        return true
    }
    
    // MARK: - Preflight SQLite Integrity Check
    
    /// Pre-validate the SQLite store using the raw sqlite3 C API
    /// BEFORE SwiftData/CoreData ever opens it.
    ///
    /// Runs `PRAGMA quick_check` which reads all database pages and detects
    /// corruption that would cause `pread()` to crash during a WAL checkpoint.
    ///
    /// - Parameter storeURL: Path to the `default.store` SQLite file.
    /// - Returns: `true` if the store is healthy or doesn't exist yet.
    ///   `false` if corruption is detected and the caller should delete the store.
    static func preflightCheck(storeURL: URL) -> Bool {
        // No file = first launch or already deleted. Nothing to validate.
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return true
        }
        
        // Step 1: Read-only quick_check — validates B-tree page integrity
        // without triggering a WAL checkpoint.
        var db: OpaquePointer?
        let readOnlyFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, readOnlyFlags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false  // Can't even open → treat as corrupted
        }
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false  // Can't prepare statement → corrupted
        }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            return false  // No result → corrupted
        }
        
        guard let resultPtr = sqlite3_column_text(stmt, 0) else {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            return false
        }
        let quickCheckResult = String(cString: resultPtr)
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        
        guard quickCheckResult == "ok" else {
            return false  // B-tree corruption detected
        }
        
        // Step 2: WAL checkpoint probe — exercises the exact pread() path
        // that crashed in build 27. If a WAL file exists, open read-write
        // and attempt a TRUNCATE checkpoint.
        //
        // Why TRUNCATE instead of PASSIVE:
        // - PASSIVE skips frames when other connections are active (returns SQLITE_BUSY)
        //   and leaves the WAL file at its original size. If PASSIVE skips corrupt frames,
        //   Core Data's own checkpoint (which uses a more aggressive mode) will hit them
        //   with pread() and crash.
        // - TRUNCATE waits for exclusive access, checkpoints ALL frames, and zeros the
        //   WAL file. This exercises the exact read path that Core Data would use, but
        //   via the safe C API (error codes instead of signals). If it succeeds, the WAL
        //   is empty and Core Data has nothing to checkpoint on ModelContainer init.
        // - If TRUNCATE returns BUSY/LOCKED, another process has the DB — acceptable,
        //   not corruption. We proceed and let Core Data handle it normally.
        let walPath = storeURL.path + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            var rwDb: OpaquePointer?
            let rwFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(storeURL.path, &rwDb, rwFlags, nil) == SQLITE_OK else {
                sqlite3_close(rwDb)
                return false  // Can't open read-write → treat as corrupted
            }
            
            // TRUNCATE checkpoint: checkpoints ALL WAL pages, then truncates
            // the WAL file to zero bytes. Returns SQLITE_OK on success.
            var walFrames: Int32 = 0
            var checkpointed: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(
                rwDb,
                nil,  // All attached databases
                SQLITE_CHECKPOINT_TRUNCATE,
                &walFrames,
                &checkpointed
            )
            sqlite3_close(rwDb)
            
            // SQLITE_OK = checkpoint + truncate succeeded (WAL is healthy and empty)
            // SQLITE_BUSY/LOCKED = another connection has the WAL locked (not corruption,
            //   just can't get exclusive access — acceptable, Core Data will handle it)
            if rc != SQLITE_OK && rc != SQLITE_BUSY && rc != SQLITE_LOCKED {
                return false  // WAL checkpoint failed → corruption
            }
            
            // NOTE: WAL and SHM files are intentionally NOT deleted by our code.
            // TRUNCATE mode zeros the WAL file content (safe for Core Data to find),
            // but the file itself may still exist with 0 bytes. SQLite manages its
            // own WAL lifecycle — we never call removeItem on WAL/SHM files.
        }
        
        // Step 3: Raw write probe — validates the store can handle INSERT + DELETE
        // using the sqlite3 C API. Returns error codes instead of crashing with
        // a signal, unlike the previous ModelContext.save() probe.
        guard rawWriteProbe(storeURL: storeURL) else {
            return false  // Write probe failed → corruption in writable pages
        }
        
        return true
    }
}

import SwiftData
import Foundation
import SQLite3

/// Tri-state health verdict for the SQLite store.
///
/// Replaces the previous Bool return from `preflightCheck` which treated
/// ALL failures as corruption — including transient errors (data protection
/// lockout, lock contention, disk full) that should NOT trigger store deletion.
enum StoreHealthVerdict: Equatable {
    /// Store is healthy — passed all integrity checks.
    case healthy
    /// Store is definitively corrupted — caller should delete and recreate.
    case corrupt(reason: String)
    /// Inconclusive — a transient error prevented diagnosis.
    /// Caller must NOT delete the store (it may be perfectly healthy).
    case indeterminate(reason: String)
    
    /// True only for `.corrupt` — use to gate destructive recovery actions.
    var isCorrupt: Bool {
        if case .corrupt = self { return true }
        return false
    }
    
    /// True only for `.healthy`.
    var isHealthy: Bool {
        self == .healthy
    }
}

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
    ///
    /// Wrapped in `SuspensionGuard` like every other StoreHealthProbe entry:
    /// no production caller exists today, but the saves below are real write
    /// round-trips, and any future reuse must not silently reintroduce an
    /// unguarded write transaction.
    @MainActor
    static func runInstrumented(
        context: ModelContext,
        sentinelKey: String,
        onBeforeSave: (() -> Void)? = nil
    ) -> Bool {
        SuspensionGuard.shared.withProtection("sentinelProbe") {
            runInstrumentedBody(context: context, sentinelKey: sentinelKey, onBeforeSave: onBeforeSave)
        }
    }

    @MainActor
    private static func runInstrumentedBody(
        context: ModelContext,
        sentinelKey: String,
        onBeforeSave: (() -> Void)?
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

        // The probe commits write transactions — protect against suspension
        // mid-write (0xDEAD10CC) like any other store write.
        return SuspensionGuard.shared.withProtection("rawWriteProbe") {
            rawWriteProbeBody(storeURL: storeURL)
        }
    }

    private static func rawWriteProbeBody(storeURL: URL) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }

        // Tolerate brief lock contention (Core Data mid-commit on its own
        // connection). Without this, transient SQLITE_BUSY fails the probe
        // and guardedSave silently skips legitimate saves.
        sqlite3_busy_timeout(db, 250)

        // Disable auto-checkpoint and WAL size limit to prevent ftruncate.
        // The probe exercises the write + WAL append path (proving pages
        // are writable), but walLimitSize → ftruncate is an uncatchable
        // signal on degraded filesystems (background task file revocation,
        // data protection lockout). These PRAGMAs ensure the dangerous
        // ftruncate path is never reached by the probe's writes.
        sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_size_limit=-1", nil, nil, nil)

        // Create the persistent probe table on first run only. The table is
        // deliberately NOT dropped afterwards: DROP + re-CREATE on every probe
        // bumps the schema cookie twice per run, forcing SQLITE_SCHEMA
        // re-preparation on Core Data's live connection and doubling the
        // probe's write-transaction count (each one a suspension-kill window).
        let createSQL = "CREATE TABLE IF NOT EXISTS _health_probe (id INTEGER PRIMARY KEY)"
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }

        // INSERT a test row — exercises the write + WAL path.
        // OR REPLACE keeps the probe idempotent if a prior run died mid-probe.
        let insertSQL = "INSERT OR REPLACE INTO _health_probe (id) VALUES (1)"
        guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }

        // DELETE the test row — exercises the delete path
        let deleteSQL = "DELETE FROM _health_probe WHERE id = 1"
        guard sqlite3_exec(db, deleteSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }

        sqlite3_close(db)
        return true
    }
    
    // MARK: - Verdict-based Write Probe
    
    /// Tri-state write probe using the raw sqlite3 C API.
    ///
    /// Returns `.healthy`, `.corrupt`, or `.indeterminate` instead of a bare Bool.
    /// The busy timeout prevents false-negative results from lock contention.
    ///
    /// - Parameters:
    ///   - storeURL: Path to the SQLite store file.
    ///   - busyTimeoutMs: SQLite busy timeout in milliseconds (default 250ms for save-path probes).
    /// - Returns: A `StoreHealthVerdict`.
    static func rawWriteVerdict(storeURL: URL, busyTimeoutMs: Int32 = 250) -> StoreHealthVerdict {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .healthy  // No file = nothing to probe
        }

        return SuspensionGuard.shared.withProtection("rawWriteVerdict") {
            rawWriteVerdictBody(storeURL: storeURL, busyTimeoutMs: busyTimeoutMs)
        }
    }

    private static func rawWriteVerdictBody(storeURL: URL, busyTimeoutMs: Int32) -> StoreHealthVerdict {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let openRc = sqlite3_open_v2(storeURL.path, &db, flags, nil)
        guard openRc == SQLITE_OK else {
            sqlite3_close(db)
            return classifyError(openRc, context: "rawWriteVerdict open")
        }

        sqlite3_busy_timeout(db, busyTimeoutMs)

        // Disable auto-checkpoint and WAL size limit to prevent ftruncate.
        // Same rationale as rawWriteProbe — see comment there.
        sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_size_limit=-1", nil, nil, nil)

        // Persistent probe table — created once, never dropped (schema churn
        // forces SQLITE_SCHEMA re-preparation on Core Data's live connection).
        let createSQL = "CREATE TABLE IF NOT EXISTS _health_probe (id INTEGER PRIMARY KEY)"
        let createRc = sqlite3_exec(db, createSQL, nil, nil, nil)
        guard createRc == SQLITE_OK else {
            sqlite3_close(db)
            return classifyError(createRc, context: "rawWriteVerdict create")
        }

        // INSERT a test row — exercises the write + WAL path
        let insertSQL = "INSERT OR REPLACE INTO _health_probe (id) VALUES (1)"
        let insertRc = sqlite3_exec(db, insertSQL, nil, nil, nil)
        guard insertRc == SQLITE_OK else {
            sqlite3_close(db)
            return classifyError(insertRc, context: "rawWriteVerdict insert")
        }

        // DELETE the test row — exercises the delete path
        let deleteSQL = "DELETE FROM _health_probe WHERE id = 1"
        let deleteRc = sqlite3_exec(db, deleteSQL, nil, nil, nil)
        guard deleteRc == SQLITE_OK else {
            sqlite3_close(db)
            return classifyError(deleteRc, context: "rawWriteVerdict delete")
        }

        sqlite3_close(db)
        return .healthy
    }
    
    // MARK: - Verdict-based Preflight Check
    
    /// Error codes that indicate definitive corruption — the store MUST be deleted.
    private static let corruptionCodes: Set<Int32> = [
        11,  // SQLITE_CORRUPT
        26,  // SQLITE_NOTADB
    ]
    
    /// Error codes that indicate transient/environmental failures — the store
    /// may be perfectly healthy and must NOT be deleted.
    private static let transientCodes: Set<Int32> = [
        5,   // SQLITE_BUSY
        6,   // SQLITE_LOCKED
        10,  // SQLITE_IOERR
        13,  // SQLITE_FULL
        14,  // SQLITE_CANTOPEN
        3,   // SQLITE_PERM
        8,   // SQLITE_READONLY
    ]
    
    /// Classify a sqlite3 error code into a health verdict.
    private static func classifyError(_ rc: Int32, context: String) -> StoreHealthVerdict {
        if corruptionCodes.contains(rc) {
            return .corrupt(reason: "\(context): sqlite3 error \(rc)")
        }
        // Any other non-OK code is indeterminate (we can't tell if it's corruption or transient)
        return .indeterminate(reason: "\(context): sqlite3 error \(rc)")
    }
    
    /// Pre-validate the SQLite store using the raw sqlite3 C API, returning
    /// a tri-state verdict instead of a bare Bool.
    ///
    /// `.corrupt` = definitive corruption (SQLITE_CORRUPT, SQLITE_NOTADB, quick_check ≠ "ok").
    /// `.indeterminate` = transient failure (CANTOPEN, IOERR, BUSY, LOCKED, FULL, PERM, etc.).
    /// `.healthy` = all checks passed.
    ///
    /// - Parameter storeURL: Path to the `default.store` SQLite file.
    /// - Returns: A `StoreHealthVerdict`.
    static func preflightVerdict(storeURL: URL) -> StoreHealthVerdict {
        // No file = first launch or already deleted. Nothing to validate.
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .healthy
        }

        // The preflight performs writes and a TRUNCATE checkpoint (an
        // ftruncate site) — protect against suspension mid-write. App.init
        // runs this during BGAppRefreshTask cold launches in the background.
        return SuspensionGuard.shared.withProtection("preflightVerdict") {
            preflightVerdictBody(storeURL: storeURL)
        }
    }

    private static func preflightVerdictBody(storeURL: URL) -> StoreHealthVerdict {
        // Step 0: Delete the SHM (WAL index) file before opening.
        // See preflightCheck for full rationale.
        let shmPath = storeURL.path + "-shm"
        if FileManager.default.fileExists(atPath: shmPath) {
            try? FileManager.default.removeItem(atPath: shmPath)
        }
        
        // Step 1: Open read-write and run PRAGMA quick_check
        var db: OpaquePointer?
        let rwFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let openRc = sqlite3_open_v2(storeURL.path, &db, rwFlags, nil)
        guard openRc == SQLITE_OK else {
            sqlite3_close(db)
            return classifyError(openRc, context: "open")
        }
        
        // Set busy timeout to tolerate transient lock contention
        sqlite3_busy_timeout(db, 2000)
        
        var stmt: OpaquePointer?
        let prepareRc = sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil)
        guard prepareRc == SQLITE_OK else {
            let extRc = sqlite3_extended_errcode(db)
            sqlite3_close(db)
            // The DB opened successfully — the file IS valid SQLite.
            // Failure during prepare is most likely lock contention in WAL mode
            // (especially after SHM deletion). Treat known transient codes AND
            // IOERR (often lock-related after SHM delete) as indeterminate.
            if transientCodes.contains(prepareRc) || prepareRc == SQLITE_IOERR {
                return .indeterminate(reason: "prepare quick_check: sqlite3 error \(prepareRc) (ext=\(extRc))")
            }
            if corruptionCodes.contains(prepareRc) {
                return .corrupt(reason: "prepare quick_check: sqlite3 error \(prepareRc)")
            }
            return .indeterminate(reason: "prepare quick_check: unknown error \(prepareRc)")
        }
        
        let stepRc = sqlite3_step(stmt)
        guard stepRc == SQLITE_ROW else {
            let extRc = sqlite3_extended_errcode(db)
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            // Same logic: DB opened + prepared OK, so step failure is likely
            // lock contention or WAL recovery issue, not page corruption.
            if transientCodes.contains(stepRc) || stepRc == SQLITE_IOERR {
                return .indeterminate(reason: "step quick_check: sqlite3 error \(stepRc) (ext=\(extRc))")
            }
            if corruptionCodes.contains(stepRc) {
                return .corrupt(reason: "step quick_check: sqlite3 error \(stepRc)")
            }
            return .indeterminate(reason: "step quick_check: unknown error \(stepRc)")
        }
        
        guard let resultPtr = sqlite3_column_text(stmt, 0) else {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            return .corrupt(reason: "quick_check returned NULL")
        }
        let quickCheckResult = String(cString: resultPtr)
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        
        guard quickCheckResult == "ok" else {
            return .corrupt(reason: "quick_check returned: \(quickCheckResult)")
        }
        
        // Step 2: WAL checkpoint probe
        let walPath = storeURL.path + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            var rwDb: OpaquePointer?
            let walOpenRc = sqlite3_open_v2(storeURL.path, &rwDb, rwFlags, nil)
            guard walOpenRc == SQLITE_OK else {
                sqlite3_close(rwDb)
                return classifyError(walOpenRc, context: "open for WAL checkpoint")
            }
            
            sqlite3_busy_timeout(rwDb, 2000)
            
            var walFrames: Int32 = 0
            var checkpointed: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(
                rwDb,
                nil,
                SQLITE_CHECKPOINT_TRUNCATE,
                &walFrames,
                &checkpointed
            )
            sqlite3_close(rwDb)
            
            // BUSY/LOCKED = another connection has the WAL locked (not corruption)
            if rc != SQLITE_OK && rc != SQLITE_BUSY && rc != SQLITE_LOCKED {
                return classifyError(rc, context: "WAL checkpoint")
            }
        }
        
        // Step 3: Raw write probe
        guard rawWriteProbe(storeURL: storeURL) else {
            return .corrupt(reason: "raw write probe failed")
        }
        
        return .healthy
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

        // The preflight performs writes and a TRUNCATE checkpoint (an
        // ftruncate site) — protect against suspension mid-write. App.init
        // runs this during BGAppRefreshTask cold launches in the background.
        //
        // If the system DECLINES the assertion (no background budget), SKIP the
        // checkpoint and report healthy (`declined: true`). A declined assertion
        // is not evidence of corruption — running the ftruncate unprotected
        // risks a suspension-straddling kill, and returning false here would
        // DELETE the user's store (see App.init). A genuinely corrupt store is
        // still caught by the guarded `containerInit` try/catch downstream.
        return SuspensionGuard.shared.withProtectionOrSkip("preflightCheck", declined: true) {
            preflightCheckBody(storeURL: storeURL)
        }
    }

    private static func preflightCheckBody(storeURL: URL) -> Bool {
        // Step 0: Delete the SHM (WAL index) file before opening.
        //
        // The SHM (-shm) file is a shared-memory WAL index that SQLite can
        // always rebuild from the WAL file. If a previous crash (guarded_pwrite_np
        // during save) left the SHM in a corrupt state, pread() will crash with
        // a signal when sqlite3_prepare_v2 reads walIndexReadHdr — creating an
        // infinite crash loop. Deleting the SHM breaks the loop and lets SQLite
        // rebuild the index from the WAL.
        let shmPath = storeURL.path + "-shm"
        if FileManager.default.fileExists(atPath: shmPath) {
            try? FileManager.default.removeItem(atPath: shmPath)
        }
        
        // Step 1: Read-write quick_check — validates B-tree page integrity.
        // Opened READ-WRITE (not read-only) so SQLite can recreate the SHM
        // file that was deleted above. PRAGMA quick_check itself is read-only.
        var db: OpaquePointer?
        let rwFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storeURL.path, &db, rwFlags, nil) == SQLITE_OK else {
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
        
        // Step 2: Raw write probe — validates the store can handle INSERT + DELETE
        // using the sqlite3 C API. Returns error codes instead of crashing with
        // a signal, unlike the previous ModelContext.save() probe.
        //
        // Must run BEFORE the TRUNCATE checkpoint (Step 3) so the probe's WAL
        // frames get checkpointed and truncated. rawWriteProbe disables
        // wal_autocheckpoint to avoid the dangerous ftruncate path internally,
        // which means it leaves un-checkpointed frames. The TRUNCATE in Step 3
        // cleans those up.
        guard rawWriteProbe(storeURL: storeURL) else {
            return false  // Write probe failed → corruption in writable pages
        }
        
        // Step 3: WAL TRUNCATE checkpoint — exercises the exact pread() path
        // that crashed in an earlier release, and cleans up any WAL frames left by
        // rawWriteProbe (which disables auto-checkpoint to avoid ftruncate
        // during writes).
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
        //
        // Unconditional: always run even if no WAL file is visible, because
        // rawWriteProbe may have created one during its writes.
        //
        // Delete the SHM before opening so the TRUNCATE connection gets clean
        // exclusive access (same rationale as Step 0). rawWriteProbe's close
        // may leave a stale SHM that blocks exclusive WAL access.
        let shmPath2 = storeURL.path + "-shm"
        if FileManager.default.fileExists(atPath: shmPath2) {
            try? FileManager.default.removeItem(atPath: shmPath2)
        }
        var rwDb: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &rwDb,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(rwDb)
            return false
        }
        
        var walFrames: Int32 = 0
        var checkpointed: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(
            rwDb,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &walFrames,
            &checkpointed
        )
        sqlite3_close(rwDb)
        
        if rc != SQLITE_OK && rc != SQLITE_BUSY && rc != SQLITE_LOCKED {
            return false  // WAL checkpoint failed → corruption
        }
        
        // After TRUNCATE returns SQLITE_OK, the WAL file may still have stale
        // content. This happens when rawWriteProbe's sqlite3_close passively
        // checkpointed all frames — TRUNCATE sees walFrames=-1 (no valid frames)
        // and skips truncation. Zero the file manually since all data is safely
        // in the main DB file.
        if rc == SQLITE_OK {
            let walPath = storeURL.path + "-wal"
            if FileManager.default.fileExists(atPath: walPath) {
                try? Data().write(to: URL(fileURLWithPath: walPath))
            }
        }
        
        return true
    }
}

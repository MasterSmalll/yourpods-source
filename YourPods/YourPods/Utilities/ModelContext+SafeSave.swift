import Foundation
import SwiftData
import CoreData
import os

/// Errors thrown by guarded save operations.
enum StoreError: LocalizedError {
    /// The SQLite store failed the pre-save health probe.
    /// Saving would risk a pread() signal crash during WAL checkpoint.
    case storeUnhealthy
    
    var errorDescription: String? {
        switch self {
        case .storeUnhealthy:
            return "The database store is unhealthy. Save was skipped to prevent a crash."
        }
    }
}

extension ModelContext {
    
    private static let logger = Logger(subsystem: "com.yourpods", category: "safeSave")
    
    /// Save with a pre-save store health check to prevent pread() signal crashes.
    ///
    /// `modelContext.save()` can trigger a WAL checkpoint (`sqlite3WalCheckpoint`)
    /// internally. If any WAL pages have corrupt checksums or the store file has
    /// I/O errors, `pread()` receives a Unix signal — an uncatchable process kill.
    ///
    /// This method runs `StoreHealthProbe.rawWriteProbe()` before saving. The probe
    /// uses the raw sqlite3 C API which returns error codes instead of signals.
    /// If the probe fails, the save is skipped entirely.
    ///
    /// - Parameter storeURL: Path to the SQLite store file for the health probe.
    ///   Pass `nil` to skip the probe (behaves like `safeSave()`).
    /// - Returns: `true` if the save succeeded, `false` if skipped or failed.
    @discardableResult
    func guardedSave(storeURL: URL? = nil) -> Bool {
        if let storeURL {
            guard StoreHealthProbe.rawWriteProbe(storeURL: storeURL) else {
                Self.logger.warning("guardedSave: store health probe failed — skipping save to prevent pread() crash")
                return false
            }
        }
        return safeSave()
    }
    
    /// Save the model context with Objective-C exception safety.
    ///
    /// `modelContext.save()` can throw an `NSException` (not a Swift `Error`) when
    /// Core Data's internal SQLite layer encounters a nil key/value during INSERT.
    /// Swift's `try?` cannot catch ObjC exceptions — they crash the process.
    ///
    /// This method wraps the save in `ObjCExceptionCatcher` to convert the crash
    /// into a recoverable error. On exception, the underlying managed object context
    /// is rolled back to discard corrupt pending changes and prevent cascading crashes.
    ///
    /// - Returns: `true` if the save succeeded, `false` if it failed.
    @discardableResult
    func safeSave() -> Bool {
        var swiftError: (any Error)?
        
        let objcError = ObjCExceptionCatcher.catch {
            do {
                try self.save()
            } catch {
                swiftError = error
            }
        }
        
        if let objcError {
            Self.logger.error("modelContext.save() threw ObjC exception — rolling back: \(objcError.localizedDescription)")
            // Rollback the underlying NSManagedObjectContext to discard corrupt
            // pending changes. Without this, the context stays dirty and every
            // subsequent save() would re-throw the same exception.
            if let nsContext = Mirror(reflecting: self)
                .children.first(where: { $0.label == "_nsContext" })?
                .value as? NSManagedObjectContext {
                nsContext.rollback()
            }
            return false
        }
        
        if let swiftError {
            Self.logger.error("modelContext.save() threw Swift error: \(swiftError.localizedDescription)")
            return false
        }
        
        return true
    }
}

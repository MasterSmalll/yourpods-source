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
    ///
    /// The save runs inside a `SuspensionGuard` background-task assertion:
    /// a Core Data commit holds the SQLite write lock, and iOS kills a
    /// suspended process holding that lock (0xDEAD10CC). The assertion keeps
    /// the process running until the transaction commits, for every save
    /// call site in the app.
    @discardableResult
    func safeSave() -> Bool {
        SuspensionGuard.shared.withProtectionOrSkip("safeSave", declined: false) {
            performSafeSave()
        }
    }

    private func performSafeSave() -> Bool {
        var swiftError: (any Error)?

        // Diagnostic: attribute rows committed in this save (1 = progress tick,
        // hundreds = bulk re-persist). SwiftData stages pending edits in its own
        // change collections and only flushes them to the underlying
        // NSManagedObjectContext during save(), so the MOC's inserted/updated/
        // deleted sets read 0 *before* the commit. Read the SwiftData layer
        // first and fall back to the Core Data layer for raw-MOC saves; take
        // whichever layer actually holds the pending changes.
        if WriteInstrumentation.shared.isEnabled {
            let swiftDataRows = insertedModelsArray.count
                + changedModelsArray.count
                + deletedModelsArray.count
            let coreDataRows = underlyingNSContext.map {
                $0.insertedObjects.count + $0.updatedObjects.count + $0.deletedObjects.count
            } ?? 0
            WriteInstrumentation.shared.recordRows(max(swiftDataRows, coreDataRows))
        }

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
            underlyingNSContext?.rollback()
            return false
        }
        
        if let swiftError {
            Self.logger.error("modelContext.save() threw Swift error: \(swiftError.localizedDescription)")
            return false
        }
        
        return true
    }
    // MARK: - Underlying NSManagedObjectContext

    /// Access the underlying `NSManagedObjectContext` for this `ModelContext`.
    ///
    /// **Main context path:** If this `ModelContext` is the container's `mainContext`,
    /// returns the `NSPersistentContainer.viewContext`. This is the reliable approach
    /// for Xcode 26 / iOS 26 where `_nsContext` was removed from `ModelContext`.
    ///
    /// **Background context path:** For non-main contexts (e.g. SyncStore), falls
    /// back to the legacy `_nsContext` Mirror path. Background contexts should
    /// prefer `newBackgroundNSContext()` on `ModelContainer` instead.
    ///
    /// Used by rollback, merge-policy configuration, and cross-context refresh.
    var underlyingNSContext: NSManagedObjectContext? {
        // The main ModelContext (PodcastManager's) always runs on MainActor.
        // Background contexts (SyncStore) always run off-main.
        // Use Thread.isMainThread to distinguish: if we're on main and the
        // NSPersistentContainer is available, return viewContext. Otherwise
        // fall back to the _nsContext Mirror path for background contexts.
        if Thread.isMainThread,
           let nsPersistentContainer = container.underlyingNSPersistentContainer {
            return nsPersistentContainer.viewContext
        }
        // For background contexts (or fallback): legacy _nsContext Mirror path
        return Mirror(reflecting: self)
            .children.first { $0.label == "_nsContext" }?
            .value as? NSManagedObjectContext
    }

    // MARK: - Cross-Context Support

    /// Refresh all materialized objects from the persistent store.
    ///
    /// After a background context (e.g. `SyncStore`) saves, the main context's
    /// in-memory objects are stale. This calls `NSManagedObjectContext.refreshAllObjects()`
    /// to fault them back to the store's current state. Unsaved changes in this
    /// context are preserved.
    func refreshAllFromStore() {
        underlyingNSContext?.refreshAllObjects()
    }

    /// Set the merge policy to "object trump" — when this context and another
    /// context save conflicting changes to the same row, the in-memory (object)
    /// values win over the persistent-store values.
    ///
    /// Used by `SyncStore`'s background context so its writes don't conflict
    /// with main-context saves (e.g. progress timer updates).
    func applyObjectTrumpMergePolicy() {
        underlyingNSContext?.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Enable automatic merging of changes from sibling contexts that share
    /// the same `NSPersistentStoreCoordinator`.
    ///
    /// **WARNING:** This causes the viewContext to merge EVERY background save
    /// on the main queue. With batch saves (500 episodes per batch), each save
    /// triggers a main-thread merge. For large libraries, this accumulates into
    /// watchdog-killing main-thread blocking.
    ///
    /// Prefer manual reconciliation via `refreshAllFromStore()` at the END of
    /// a sync cycle instead of per-save automatic merging.
    func enableAutomaticMerging() {
        underlyingNSContext?.automaticallyMergesChangesFromParent = true
    }
}

// MARK: - ModelContainer NSPersistentContainer Accessor

extension ModelContainer {
    /// Extract the underlying `NSPersistentContainer` from SwiftData's internal
    /// `DataStore` via Mirror reflection.
    ///
    /// SwiftData wraps Core Data internally. The path is:
    /// `ModelContainer.datastores[0].1.container` → `NSPersistentContainer`
    ///
    /// This is used to access the `viewContext` for merge policy configuration,
    /// automatic cross-context merging, and `NSManagedObjectContextDidSave`
    /// notification observation.
    var underlyingNSPersistentContainer: NSPersistentContainer? {
        let mirror = Mirror(reflecting: self)
        guard let datastores = mirror.children.first(where: { $0.label == "datastores" })?.value as? [(Any, Any)] else {
            return nil
        }
        for (_, dataStore) in datastores {
            let storeMirror = Mirror(reflecting: dataStore)
            if let nsPersistentContainer = storeMirror.children.first(where: { $0.label == "container" })?.value as? NSPersistentContainer {
                return nsPersistentContainer
            }
        }
        return nil
    }

    /// Create a new background `NSManagedObjectContext` with objectTrump merge policy.
    ///
    /// In Xcode 26, `_nsContext` was removed from `ModelContext`, making it impossible
    /// to set merge policy on a background `ModelContext` via the Mirror path.
    /// SyncStore uses this to get a properly-configured MOC that it can pair
    /// with its `ModelContext` for merge-policy-aware saves.
    ///
    /// Returns nil if the `NSPersistentContainer` can't be extracted.
    func newBackgroundNSContext() -> NSManagedObjectContext? {
        guard let nsPersistentContainer = underlyingNSPersistentContainer else { return nil }
        let ctx = nsPersistentContainer.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }
}


import SwiftData
import Foundation

/// Isolated, testable health-probe for the SwiftData store.
///
/// Exercises the same SQLite page-write paths (`INSERT` → `save()` →
/// WAL checkpoint) that crash with `pread()` on a corrupted store.
///
/// The probe sets a "sentinel" in UserDefaults before touching the store.
/// If the process is killed by a signal crash during the save, the sentinel
/// remains set and is detected on the next launch, triggering store deletion.
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
}

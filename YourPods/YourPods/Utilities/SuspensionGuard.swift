import Foundation
import os
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Wraps a synchronous SQLite write window (Core Data save or raw probe) in a
/// UIKit background-task assertion so the write can never straddle process
/// suspension.
///
/// Why: the store lives in the app-group container. iOS kills a suspended app
/// that holds a SQLite file lock (`0xDEAD10CC`), and the crash stack lands
/// wherever the write happened to be — `ftruncate` in `walLimitSize`, `pwrite`,
/// `fsync`. Apple's system SQLite ships `journal_size_limit=32768`, so the
/// ftruncate-bearing commit window exists on EVERY connection, including
/// Core Data's own (which cannot be pragma-protected). The only durable fix
/// is to keep the process running until the transaction commits.
///
/// All saves route through `ModelContext.safeSave()` and all probes through
/// `StoreHealthProbe`, so those two funnels acquire the assertion — individual
/// call sites need no changes.
final class SuspensionGuard: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.yourpods", category: "suspensionGuard")

    /// Acquire a named assertion. Returns the release closure, or `nil` if the
    /// system DECLINED the assertion (no background budget — typically at the
    /// moment of suspension).
    private let acquire: (String) -> (() -> Void)?

    /// Shared production instance. Mutable so tests can inject a recorder.
    nonisolated(unsafe) static var shared = SuspensionGuard(acquire: SuspensionGuard.productionAcquire)

    init(acquire: @escaping (String) -> (() -> Void)?) {
        self.acquire = acquire
    }

    /// Run `body` inside a background-task assertion. The body ALWAYS runs —
    /// even if the assertion is declined — so use this only for writes that
    /// cannot be skipped (e.g. `containerInit`, which has no fallback). For
    /// recoverable writes, prefer `withProtectionOrSkip`.
    func withProtection<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let release = acquire(name)
        defer { release?() }
        return try instrumented(name, body)
    }

    /// Run `body` inside a background-task assertion, but SKIP it entirely if
    /// the system declines the assertion, returning `declined` instead.
    ///
    /// Why skip: a declined assertion means iOS granted no background time, so
    /// a write started now can be suspended mid-commit and killed holding the
    /// SQLite write lock (0xDEAD10CC) — corrupting the app-group store. A
    /// dropped save (progress tick, queue, sync persist) is recoverable on the
    /// next cycle; a corrupt store requires a reinstall. Skipping is strictly
    /// safer for any write whose loss the app can absorb.
    func withProtectionOrSkip<T>(_ name: String, declined: T, _ body: () throws -> T) rethrows -> T {
        guard let release = acquire(name) else {
            Self.logger.fault("Suspension assertion '\(name)' DECLINED — skipping write to avoid a suspension-straddling commit")
            return declined
        }
        defer { release() }
        return try instrumented(name, body)
    }

    /// Diagnostic accounting (zero-overhead when the flag is off): time the
    /// write window and flag any overlap with another concurrent writer.
    private func instrumented<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let inst = WriteInstrumentation.shared
        guard inst.isEnabled else { return try body() }
        inst.beginWriteWindow(source: name)
        let start = DispatchTime.now()
        defer {
            inst.endWriteWindow(source: name)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
            inst.recordSave(source: name, durationMs: ms)
        }
        return try body()
    }

    /// Production acquire: a UIApplication background task that ends exactly
    /// once — when the write completes or when the system expires the
    /// assertion (an expired-but-never-ended task is itself a termination).
    private static func productionAcquire(name: String) -> (() -> Void)? {
        #if canImport(UIKit) && !os(watchOS)
        // UIApplication assertions are meaningless under unit tests.
        guard NSClassFromString("XCTestCase") == nil else { return {} }

        let lock = NSLock()
        var ended = false
        var taskId: UIBackgroundTaskIdentifier = .invalid
        let endOnce: () -> Void = {
            lock.lock()
            let id = taskId
            let shouldEnd = !ended && id != .invalid
            ended = true
            taskId = .invalid
            lock.unlock()
            if shouldEnd {
                UIApplication.shared.endBackgroundTask(id)
            }
        }

        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            Self.logger.warning("Suspension assertion '\(name)' expired mid-write — releasing")
            endOnce()
        }

        if id == .invalid {
            // The system granted no background time (budget exhausted). Return
            // nil so the caller can SKIP the write rather than run it
            // unprotected — a write started here can straddle suspension and be
            // killed mid-commit (0xDEAD10CC). Log at fault level so crash triage
            // can correlate any suspension kill with this state.
            WriteInstrumentation.shared.recordAssertion(name: name, granted: false)
            Self.logger.fault("Suspension assertion '\(name)' DECLINED by system — no background budget granted")
            return nil
        }
        WriteInstrumentation.shared.recordAssertion(name: name, granted: true)

        // Store the id under the lock. If the expiration handler already
        // fired (microsecond window between begin and this store), it saw
        // taskId == .invalid and ended nothing — end the real id here so an
        // expired-but-never-ended task (itself a termination) cannot leak.
        lock.lock()
        if ended {
            lock.unlock()
            UIApplication.shared.endBackgroundTask(id)
        } else {
            taskId = id
            lock.unlock()
        }
        return endOnce
        #else
        // macOS has no comparable suspension semantics — no-op.
        return {}
        #endif
    }
}

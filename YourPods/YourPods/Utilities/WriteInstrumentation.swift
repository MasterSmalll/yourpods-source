import Foundation
import CoreData
import os

/// In-memory accounting of every disk-write the app performs, used to diagnose
/// the store-corruption class (instrument before fixing).
///
/// It answers the questions we otherwise cannot answer with vibes:
/// - **What writes, how often, for how long** — per-source save tally + duration.
/// - **app-group `UserDefaults` plist churn** — the prime suspect for the
///   sustained ~33 KB/s seen during 24 h of background playback (the 5 s widget
///   push rewrites the whole suite plist). Counted separately from SQLite saves.
/// - **Single-writer invariant** — overlap detector: any time a second
///   write window opens while one is active, that's two writers on the
///   app-group store (lock contention + the concurrent-INSERT corruption class).
/// - **Suspension assertions** — granted vs DECLINED. A DECLINED write
///   proceeds unprotected and can straddle suspension (0xDEAD10CC).
///
/// **It must never itself write to disk** — all state is in memory and emitted
/// to the unified log. Gated behind a runtime flag so it is zero-overhead off.
final class WriteInstrumentation: @unchecked Sendable {

    /// Per-source save accounting.
    struct SourceStat: Equatable, Sendable {
        var count: Int
        var totalDurationMs: Double
    }

    /// Immutable point-in-time view of the counters, safe to read off-lock.
    struct Snapshot: Equatable, Sendable {
        var saves: [String: SourceStat] = [:]
        var defaultsWrites: [String: Int] = [:]
        var assertionsGranted = 0
        var assertionsDeclined = 0
        var writerOverlaps = 0
        var maxConcurrentWriters = 0
        var totalRowsWritten = 0
        var maxRowsInOneSave = 0
        /// Which writers were concurrent when an overlap fired, keyed by the
        /// sorted+joined source names (e.g. "preflightCheck+safeSave") → count.
        /// Pinpoints the single-writer race instead of a bare overlap count.
        var overlapSources: [String: Int] = [:]
        /// Which entity.property was re-written, keyed `Entity.property` → count
        /// (inserts as `Entity.+insert`, deletes as `Entity.-delete`). Pinpoints
        /// the re-persist churn — the exact field driving the row count.
        var dirtyKeys: [String: Int] = [:]
    }

    private static let logger = Logger(subsystem: "com.yourpods", category: "instrumentation")

    /// Runtime gate. Enable on-device for a diagnostic soak with:
    /// `defaults write <app-group/app> DEBUG_WRITE_INSTRUMENTATION -bool YES`
    /// (or a hidden Settings toggle), then relaunch.
    static let flagKey = "DEBUG_WRITE_INSTRUMENTATION"

    /// Mutable so tests can inject an enabled recorder (mirrors `SuspensionGuard.shared`).
    nonisolated(unsafe) static var shared = WriteInstrumentation(
        enabled: UserDefaults.standard.bool(forKey: flagKey)
    )

    let isEnabled: Bool

    private let lock = NSLock()
    private var saves: [String: SourceStat] = [:]
    private var defaultsWrites: [String: Int] = [:]
    private var assertionsGranted = 0
    private var assertionsDeclined = 0
    private var writerOverlaps = 0
    private var activeWriters = 0
    private var maxConcurrentWriters = 0
    private var totalRowsWritten = 0
    private var maxRowsInOneSave = 0
    private var activeSources: [String] = []
    private var overlapSources: [String: Int] = [:]
    private var dirtyKeys: [String: Int] = [:]
    private var contextSaveObserver: NSObjectProtocol?

    init(enabled: Bool) { self.isEnabled = enabled }

    /// Record the number of object rows (inserted+updated+deleted) committed in
    /// one save. Distinguishes a 1-row progress save from a bulk re-persist
    /// (`persistNewPodcasts` writes hundreds) — the disk-write driver.
    func recordRows(_ n: Int) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        totalRowsWritten += n
        if n > maxRowsInOneSave { maxRowsInOneSave = n }
    }

    /// Merge a batch of `Entity.property → count` tallies from one save.
    func recordDirtyKeys(_ keys: [String: Int]) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        for (k, v) in keys { dirtyKeys[k, default: 0] += v }
    }

    /// Observe Core Data saves and attribute each changed property to its
    /// entity (`Entity.property`). Registered once; reads `changedValues()` in
    /// the WillSave notification, the point at which the change sets are
    /// populated (the SwiftData layer hasn't flushed to the MOC before that).
    func observeContextSaves() {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard contextSaveObserver == nil else { return } // register once
        contextSaveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self, let ctx = note.object as? NSManagedObjectContext else { return }
            // WillSave is the point at which the change sets are populated (the
            // SwiftData layer has flushed pending edits into the MOC by now).
            var batch: [String: Int] = [:]
            for obj in ctx.updatedObjects {
                let entity = obj.entity.name ?? "?"
                for key in obj.changedValues().keys {
                    batch["\(entity).\(key)", default: 0] += 1
                }
            }
            for obj in ctx.insertedObjects {
                batch["\(obj.entity.name ?? "?").+insert", default: 0] += 1
            }
            for obj in ctx.deletedObjects {
                batch["\(obj.entity.name ?? "?").-delete", default: 0] += 1
            }
            self.recordDirtyKeys(batch)
        }
    }

    deinit {
        if let observer = contextSaveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Recording

    /// Record one completed SQLite write window (Core Data save or raw probe).
    func recordSave(source: String, durationMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        var stat = saves[source] ?? SourceStat(count: 0, totalDurationMs: 0)
        stat.count += 1
        stat.totalDurationMs += durationMs
        saves[source] = stat
    }

    /// Record one app-group `UserDefaults` write (widget push, queue persist, …).
    func recordDefaultsWrite(source: String) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        defaultsWrites[source, default: 0] += 1
    }

    /// Record the outcome of a suspension background-task assertion.
    func recordAssertion(name: String, granted: Bool) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        if granted { assertionsGranted += 1 } else { assertionsDeclined += 1 }
    }

    /// Mark the start of a write window. If another window is already open, that
    /// is a single-writer violation — two writers on the same store.
    func beginWriteWindow(source: String = "?") {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        activeWriters += 1
        if activeWriters > 1 {
            writerOverlaps += 1
            // Record (and log live) which writers were concurrent — the
            // single-writer race is only actionable if we know the two source names.
            let combo = (activeSources + [source]).sorted().joined(separator: "+")
            overlapSources[combo, default: 0] += 1
            Self.logger.fault("[overlap] two concurrent writers on the store: \(combo, privacy: .public)")
        }
        if activeWriters > maxConcurrentWriters { maxConcurrentWriters = activeWriters }
        activeSources.append(source)
    }

    func endWriteWindow(source: String = "?") {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        if activeWriters > 0 { activeWriters -= 1 }
        if let idx = activeSources.firstIndex(of: source) { activeSources.remove(at: idx) }
    }

    // MARK: - Reading / reporting

    func reset() {
        lock.lock(); defer { lock.unlock() }
        saves = [:]
        defaultsWrites = [:]
        assertionsGranted = 0
        assertionsDeclined = 0
        writerOverlaps = 0
        activeWriters = 0
        maxConcurrentWriters = 0
        totalRowsWritten = 0
        maxRowsInOneSave = 0
        activeSources = []
        overlapSources = [:]
        dirtyKeys = [:]
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            saves: saves,
            defaultsWrites: defaultsWrites,
            assertionsGranted: assertionsGranted,
            assertionsDeclined: assertionsDeclined,
            writerOverlaps: writerOverlaps,
            maxConcurrentWriters: maxConcurrentWriters,
            totalRowsWritten: totalRowsWritten,
            maxRowsInOneSave: maxRowsInOneSave,
            overlapSources: overlapSources,
            dirtyKeys: dirtyKeys
        )
    }

    /// One-line, log-friendly summary. Pure (no logging) so it is unit-testable.
    func formatReport(fileSizes: [String: Int64]) -> String {
        let snap = snapshot()
        let saveDesc = snap.saves.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.count)(\(Int($0.value.totalDurationMs))ms)" }
            .joined(separator: ",")
        let dwDesc = snap.defaultsWrites.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let fsDesc = fileSizes.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let overlapDesc = snap.overlapSources.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        // Cap to the top churners so the log line stays bounded.
        let dkDesc = snap.dirtyKeys.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "saves[\(saveDesc)] rows total=\(snap.totalRowsWritten) max=\(snap.maxRowsInOneSave) "
            + "defaultsWrites[\(dwDesc)] "
            + "assertions granted=\(snap.assertionsGranted) declined=\(snap.assertionsDeclined) "
            + "overlap=\(snap.writerOverlaps) maxConcurrent=\(snap.maxConcurrentWriters) "
            + "overlapSrc[\(overlapDesc)] "
            + "dirtyKeys[\(dkDesc)] "
            + "files[\(fsDesc)]"
    }

    /// Emit the current accounting to the unified log and reset for the next interval.
    func emitReport(reason: String, fileSizes: [String: Int64]) {
        guard isEnabled else { return }
        Self.logger.notice("[\(reason, privacy: .public)] \(self.formatReport(fileSizes: fileSizes), privacy: .public)")
        reset()
    }

    private var emitTimer: DispatchSourceTimer?

    /// Emit a per-interval delta report on a background queue while the process
    /// is alive (e.g. every 60 s during a soak). No-op when disabled. The timer
    /// is owned here and survives for the (diagnostic) app lifetime.
    func startPeriodicEmit(
        intervalSeconds: Int,
        reason: String,
        fileSizes: @escaping @Sendable () -> [String: Int64]
    ) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        emitTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(intervalSeconds),
                       repeating: .seconds(intervalSeconds))
        timer.setEventHandler { [weak self] in
            self?.emitReport(reason: reason, fileSizes: fileSizes())
        }
        timer.resume()
        emitTimer = timer
    }
}

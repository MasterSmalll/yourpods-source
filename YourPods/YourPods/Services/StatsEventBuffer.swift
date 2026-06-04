// ─── YourPods Pro ────────────────────────────────────────────────────────
// StatsEventBuffer — lightweight actor that accumulates listening/skip events
// for async batch upload. Owned by PlayerManager; flushed during sync.
// ─────────────────────────────────────────────────────────────────────────

import Foundation
import os.log

/// Append-only buffer for `ProStatsEvent` items.
///
/// Usage pattern:
/// 1. `PlayerManager` calls `record(_:)` whenever a meaningful playback state
///    change occurs (pause, seek, skip, episode advance).
/// 2. `PodcastManager.refreshAndSync` calls `flush()` to get and clear all
///    pending events, then uploads them via `YourPodsProClient.pushStatsEvents`.
/// 3. If the upload fails, `restore(_:)` re-enqueues the events so they aren't lost.
///
/// Auto-flush triggers:
/// - **Buffer limit**: When pending events reach `bufferLimit` (50), `onFlushNeeded` fires.
/// - **Periodic timer**: Every `flushInterval` (30s), `onFlushNeeded` fires if pending > 0.
/// Both triggers are no-ops for Vault/gPodder users because `flushStatsIfAuthenticated`
/// guards on `syncClient as? YourPodsProClient`.
actor StatsEventBuffer {

    // MARK: - Constants

    /// Maximum events before an automatic flush is triggered.
    static let bufferLimit = 50

    /// Interval (seconds) for periodic auto-flush during active playback.
    static let flushInterval: TimeInterval = 30

    /// Minimum content time (seconds) for a listen event to be recorded.
    /// Events below this threshold are micro-events (accidental taps, buffering blips).
    static let minContentSec: Double = 1.0

    /// Minimum wall-clock duration (seconds) for a listen event to be recorded.
    static let minDurationSec: Double = 0.5

    // MARK: - State

    private let logger = Logger(subsystem: "com.yourpods", category: "StatsEventBuffer")
    private var _pending: [ProStatsEvent] = []
    private var periodicTask: Task<Void, Never>?

    /// Called when the buffer needs an immediate flush (limit reached or timer fired).
    /// Set by PlayerManager to wire the actual upload via `flushStatsIfAuthenticated()`.
    ///
    /// This callback is safe for all account types — `flushStatsIfAuthenticated()` guards
    /// on `syncClient as? YourPodsProClient`, making it a no-op for Vault and gPodder users.
    private var onFlushNeeded: (@Sendable () -> Void)?

    // MARK: - Public Interface

    /// Current pending events (read-only view).
    var pending: [ProStatsEvent] { _pending }

    /// Sets the flush handler callback. Called by PlayerManager at init.
    func setFlushHandler(_ handler: @escaping @Sendable () -> Void) {
        onFlushNeeded = handler
    }

    /// Appends a new event to the buffer.
    /// If the buffer reaches `bufferLimit`, triggers an automatic flush.
    func record(_ event: ProStatsEvent) {
        _pending.append(event)
        logger.debug("Recorded \(event.eventType.rawValue) event — \(self._pending.count) pending")

        if _pending.count >= Self.bufferLimit {
            logger.info("Buffer limit (\(Self.bufferLimit)) reached — triggering auto-flush")
            onFlushNeeded?()
        }
    }

    /// Records a listen event only if it meets minimum segment thresholds.
    /// Skip events (`.skipManual`, `.skipAuto`, `.skipChapter`) bypass the filter.
    ///
    /// Thresholds (from server spec):
    /// - `contentSec > 1.0` — at least 1 second of content consumed
    /// - `durationSec > 0.5` — at least 0.5 seconds of wall-clock time elapsed
    func recordIfMeetsThreshold(_ event: ProStatsEvent) {
        // Skip events always pass — they're instantaneous by definition
        if event.eventType != .listen {
            record(event)
            return
        }

        // Apply minimum segment filter for listen events
        guard event.contentSec > Self.minContentSec,
              event.durationSec > Self.minDurationSec else {
            logger.debug("Dropped sub-threshold listen event (content=\(event.contentSec)s, duration=\(event.durationSec)s)")
            return
        }

        record(event)
    }

    /// Returns all pending events and clears the buffer.
    /// Call `restore(_:)` with the returned array if the upload fails.
    func flush() -> [ProStatsEvent] {
        let events = _pending
        _pending = []
        logger.debug("Flushed \(events.count) events")
        return events
    }

    /// Re-enqueues events after a failed upload so they aren't lost.
    /// Prepends the failed events so they are uploaded first on the next sync.
    func restore(_ events: [ProStatsEvent]) {
        guard !events.isEmpty else { return }
        _pending = events + _pending
        logger.warning("Restored \(events.count) events after upload failure — \(self._pending.count) total pending")
    }

    // MARK: - Periodic Flush Timer

    /// Starts a periodic flush timer that fires every `flushInterval` seconds.
    /// If there are pending events when the timer fires, `onFlushNeeded` is called.
    func startPeriodicFlush() {
        periodicTask?.cancel()
        periodicTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.flushInterval))
                guard !Task.isCancelled else { break }
                self.periodicFlushCheck()
            }
        }
    }

    /// Called from the periodic timer task to check and trigger flush within actor context.
    private func periodicFlushCheck() {
        let count = _pending.count
        if count > 0 {
            logger.debug("Periodic flush timer fired with \(count) pending events")
            onFlushNeeded?()
        }
    }

    /// Stops the periodic flush timer.
    func stopPeriodicFlush() {
        periodicTask?.cancel()
        periodicTask = nil
    }
}

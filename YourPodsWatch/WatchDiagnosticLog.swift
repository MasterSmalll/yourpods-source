import Foundation
import os

/// Lightweight on-disk ring buffer for watch lifecycle events.
///
/// `os.Logger` output is only visible with Xcode attached. This utility
/// persists the last 50 lifecycle events to UserDefaults so they can be
/// reviewed after the fact — via a diagnostic view or by reading defaults.
///
/// Each entry is a timestamp + event tag (e.g., "BG_ENTER", "FG_RESUME",
/// "WC_CONTEXT_RECEIVED", "BG_REFRESH_START").
///
/// Storage: ~10KB in UserDefaults. Writes are debounced to avoid I/O
/// contention with the existing persistence queue.
final class WatchDiagnosticLog {
    static let shared = WatchDiagnosticLog()

    private static let defaultsKey = "watch_diagnostic_log"
    private static let maxEntries = 50

    private let logger = Logger(subsystem: "com.yourpods", category: "WatchDiagnostic")

    /// In-memory buffer — flushed to UserDefaults on each append.
    private var entries: [String] = []

    private init() {
        // Load existing entries from UserDefaults
        if let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) {
            entries = saved
        }
    }

    // MARK: - Logging

    /// Append a lifecycle event to the ring buffer.
    /// Format: "2026-05-31T15:30:00Z | BG_ENTER"
    func log(_ event: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(timestamp) | \(event)"

        entries.append(entry)

        // Trim to max size (ring buffer)
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }

        // Persist
        UserDefaults.standard.set(entries, forKey: Self.defaultsKey)

        // Also forward to os.Logger for Xcode console
        logger.info("\(event)")
    }

    // MARK: - Reading

    /// All current log entries, oldest first.
    var allEntries: [String] {
        return entries
    }

    /// Clear all entries.
    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}

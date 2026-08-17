import XCTest
import SwiftData
import SQLite3
@testable import YourPods

/// Tests for the SuspensionGuard write-protection funnel.
///
/// Root cause (0xDEAD10CC crash class): the SQLite store lives in the app-group
/// container. If iOS suspends the process while ANY connection holds the write
/// lock (Core Data save or raw probe), RunningBoard kills the app — the crash
/// stack lands wherever the write happened to be (ftruncate, pwrite, fsync).
///
/// Fix: every synchronous SQLite write window runs inside a background-task
/// assertion via SuspensionGuard, so the process cannot be suspended mid-write.
final class SuspensionGuardTests: XCTestCase {

    private var savedShared: SuspensionGuard!

    override func setUp() {
        super.setUp()
        savedShared = SuspensionGuard.shared
    }

    override func tearDown() {
        SuspensionGuard.shared = savedShared
        savedShared = nil
        super.tearDown()
    }

    // MARK: - Core Semantics

    /// The assertion must be acquired before the body runs and released after.
    func test_withProtection_acquiresBeforeBody_releasesAfter() {
        var events: [String] = []
        let guardInstance = SuspensionGuard(acquire: { name in
            events.append("begin:\(name)")
            return { events.append("end:\(name)") }
        })

        let result = guardInstance.withProtection("probe") { () -> Int in
            events.append("body")
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(events, ["begin:probe", "body", "end:probe"],
                       "Assertion must bracket the body: begin → body → end")
    }

    /// The release closure must run even when the body throws.
    func test_withProtection_releasesOnThrow() {
        var released = false
        let guardInstance = SuspensionGuard(acquire: { _ in
            return { released = true }
        })

        struct TestError: Error {}
        XCTAssertThrowsError(
            try guardInstance.withProtection("save") { throw TestError() }
        )
        XCTAssertTrue(released,
                      "Assertion must be released even when the protected body throws")
    }

    // MARK: - Abort-on-DECLINED (a declined assertion must SKIP the write)

    /// When the system DECLINES the background-task assertion (no background
    /// budget — which happens exactly at the moment of suspension), the write
    /// MUST be skipped, never run unprotected. A dropped progress/queue/sync
    /// save is recoverable on the next cycle; a commit that straddles
    /// suspension corrupts the app-group store (0xDEAD10CC).
    func test_withProtectionOrSkip_skipsBody_whenAssertionDeclined() {
        // acquire returns nil = the OS granted no background time (DECLINED).
        let guardInstance = SuspensionGuard(acquire: { _ in nil })

        var bodyRan = false
        let result = guardInstance.withProtectionOrSkip("safeSave", declined: false) {
            bodyRan = true
            return true
        }

        XCTAssertFalse(bodyRan,
                       "A declined assertion means no background budget — the write MUST be skipped, not run unprotected")
        XCTAssertFalse(result,
                       "A skipped write returns the caller's declined fallback")
    }

    /// When the assertion is granted, the body runs and the assertion is
    /// released — identical to `withProtection` on the happy path.
    func test_withProtectionOrSkip_runsBodyAndReleases_whenAssertionGranted() {
        var released = false
        let guardInstance = SuspensionGuard(acquire: { _ in { released = true } })

        var bodyRan = false
        let result = guardInstance.withProtectionOrSkip("safeSave", declined: false) {
            bodyRan = true
            return true
        }

        XCTAssertTrue(bodyRan, "A granted assertion runs the protected body")
        XCTAssertTrue(result)
        XCTAssertTrue(released, "A granted assertion must still be released after the body")
    }

    // MARK: - safeSave Integration

    /// safeSave must run inside the suspension-protection funnel so a Core Data
    /// commit can never straddle process suspension.
    @MainActor
    func test_safeSave_runsInsideSuspensionProtection() throws {
        var events: [String] = []
        SuspensionGuard.shared = SuspensionGuard(acquire: { name in
            events.append("begin:\(name)")
            return { events.append("end:\(name)") }
        })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let context = container.mainContext
        context.insert(Podcast(url: "https://example.com/feed", title: "Test"))

        XCTAssertTrue(context.safeSave())

        XCTAssertEqual(events.filter { $0.hasPrefix("begin:") }.count, 1,
                       "safeSave must acquire the suspension assertion exactly once")
        XCTAssertEqual(events.filter { $0.hasPrefix("end:") }.count, 1,
                       "safeSave must release the suspension assertion exactly once")
        XCTAssertEqual(events.first?.hasPrefix("begin:"), true,
                       "Assertion must be acquired before the save runs")
        XCTAssertEqual(events.last?.hasPrefix("end:"), true,
                       "Assertion must be released after the save completes")
    }

    /// safeSave must SKIP its commit (not run it unprotected) when the system
    /// declines the suspension assertion, and leave the pending changes intact
    /// so a later save can retry them.
    @MainActor
    func test_safeSave_skipsCommitAndKeepsChangesPending_whenAssertionDeclined() throws {
        SuspensionGuard.shared = SuspensionGuard(acquire: { _ in nil }) // DECLINED

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let context = container.mainContext
        context.insert(Podcast(url: "https://example.com/feed", title: "Test"))

        let saved = context.safeSave()

        XCTAssertFalse(saved,
                       "When the OS declines suspension protection, safeSave must skip the commit rather than risk a straddling write")
        XCTAssertTrue(context.hasChanges,
                      "Skipped changes must remain pending for a later retry — not silently committed or dropped")
    }

    // MARK: - StoreHealthProbe Integration

    /// rawWriteProbe opens its own raw SQLite connection and commits write
    /// transactions — it must be suspension-protected like any other write.
    func test_rawWriteProbe_runsInsideSuspensionProtection() throws {
        var events: [String] = []
        SuspensionGuard.shared = SuspensionGuard(acquire: { name in
            events.append("begin:\(name)")
            return { events.append("end:\(name)") }
        })

        let storeURL = try makeTemporaryWALStore()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        XCTAssertTrue(StoreHealthProbe.rawWriteProbe(storeURL: storeURL))

        XCTAssertFalse(events.isEmpty,
                       "rawWriteProbe must acquire a suspension assertion around its writes")
        XCTAssertEqual(events.first?.hasPrefix("begin:"), true)
        XCTAssertEqual(events.last?.hasPrefix("end:"), true)
    }

    /// preflightCheck runs quick_check + write probe + TRUNCATE checkpoint
    /// (an ftruncate site) during App.init — including BGAppRefreshTask cold
    /// launches in the background. It must be suspension-protected.
    func test_preflightCheck_runsInsideSuspensionProtection() throws {
        var events: [String] = []
        SuspensionGuard.shared = SuspensionGuard(acquire: { name in
            events.append("begin:\(name)")
            return { events.append("end:\(name)") }
        })

        let storeURL = try makeTemporaryWALStore()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        XCTAssertTrue(StoreHealthProbe.preflightCheck(storeURL: storeURL))

        XCTAssertFalse(events.isEmpty,
                       "preflightCheck must acquire a suspension assertion around its checkpoint + writes")
        XCTAssertEqual(events.first?.hasPrefix("begin:"), true)
        XCTAssertEqual(events.last?.hasPrefix("end:"), true)
    }

    /// preflightCheck performs a TRUNCATE checkpoint (an ftruncate straddle
    /// site) and its `false` return DELETES the user's store. When the OS
    /// declines the assertion, it must SKIP the checkpoint and report healthy
    /// (`true`) — a declined assertion is not evidence of corruption, and must
    /// never trigger store deletion.
    func test_preflightCheck_skipsAndReportsHealthy_whenAssertionDeclined() throws {
        let storeURL = try makeCorruptStore()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        // Sanity: with a granted assertion the body runs and detects the
        // corruption (false → caller would delete the store).
        SuspensionGuard.shared = SuspensionGuard(acquire: { _ in { } })
        XCTAssertFalse(StoreHealthProbe.preflightCheck(storeURL: storeURL),
                       "Granted: the body runs quick_check and detects the corrupt store")

        // Declined: must SKIP the checkpoint and report healthy so the corrupt
        // store is NOT deleted on the basis of a missing background assertion.
        SuspensionGuard.shared = SuspensionGuard(acquire: { _ in nil })
        XCTAssertTrue(StoreHealthProbe.preflightCheck(storeURL: storeURL),
                      "Declined: skip the ftruncate checkpoint and report healthy — a declined assertion must never trigger store deletion")
    }

    // MARK: - saveContext Funnel (sweep finding: probe-then-raw-save TOCTOU)

    /// PodcastManager.saveContext was the one remaining raw modelContext.save()
    /// in production: a guarded probe followed by an UNguarded commit. The
    /// commit must route through the safeSave funnel.
    @MainActor
    func test_saveContext_commitsInsideSuspensionProtection() throws {
        var events: [String] = []
        SuspensionGuard.shared = SuspensionGuard(acquire: { name in
            events.append("begin:\(name)")
            return { events.append("end:\(name)") }
        })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let manager = PodcastManager(modelContext: container.mainContext)
        container.mainContext.insert(Podcast(url: "https://example.com/feed", title: "Test"))

        try manager.saveContext()

        XCTAssertTrue(events.contains("begin:safeSave"),
                      "saveContext must route its commit through the safeSave funnel — a guarded probe followed by an unguarded commit is the exact TOCTOU the funnel exists to prevent (events: \(events))")
    }

    // MARK: - Legacy Sentinel Probe (funnel-type invariant)

    /// run/runInstrumented are legacy entries on the funnel type itself —
    /// every StoreHealthProbe entry point must hold the assertion, including
    /// these, so future reuse cannot silently reintroduce unguarded writes.
    @MainActor
    func test_runInstrumented_runsInsideSuspensionProtection() throws {
        let sentinelKey = "test_suspensionGuard_sentinel"
        defer { UserDefaults.standard.removeObject(forKey: sentinelKey) }

        var events: [String] = []
        SuspensionGuard.shared = SuspensionGuard(acquire: { name in
            events.append("begin:\(name)")
            return { events.append("end:\(name)") }
        })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)

        _ = StoreHealthProbe.runInstrumented(
            context: container.mainContext,
            sentinelKey: sentinelKey
        )

        XCTAssertFalse(events.isEmpty,
                       "runInstrumented performs ModelContext write round-trips — it must hold a suspension assertion like every other StoreHealthProbe entry")
        XCTAssertEqual(events.first?.hasPrefix("begin:"), true)
        XCTAssertEqual(events.last?.hasPrefix("end:"), true)
    }

    // MARK: - Helpers

    /// Create a minimal WAL-mode SQLite store in a fresh temp directory.
    private func makeTemporaryWALStore() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("default.store")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE seed (id INTEGER PRIMARY KEY)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO seed (id) VALUES (1)", nil, nil, nil)
        sqlite3_close(db)
        return storeURL
    }

    /// Create a file that is not a valid SQLite database, so `PRAGMA
    /// quick_check` fails and `preflightCheckBody` returns false (corruption).
    private func makeCorruptStore() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("default.store")
        try Data("this is definitely not a sqlite database".utf8).write(to: storeURL)
        return storeURL
    }
}

import XCTest
import SwiftData
@testable import YourPods

/// Tests for the disk-write instrumentation used to diagnose the
/// store-corruption class.
///
/// Instrument before fixing: we need per-cycle write accounting (which source
/// writes, how often, for how long), a single-writer overlap detector, and a
/// granted-vs-DECLINED suspension-assertion count — emitted to the log,
/// never persisted (the instrumentation must not itself add writes).
///
/// These tests cover the in-memory accounting core. The os_log emission,
/// wall-clock timing, and FileManager size sampling are thin glue layered on top.
final class WriteInstrumentationTests: XCTestCase {

    private var savedShared: WriteInstrumentation!

    override func setUp() {
        super.setUp()
        savedShared = WriteInstrumentation.shared
    }

    override func tearDown() {
        WriteInstrumentation.shared = savedShared
        savedShared = nil
        super.tearDown()
    }

    private func makeEnabled() -> WriteInstrumentation {
        WriteInstrumentation(enabled: true)
    }

    // MARK: - Save accounting

    func test_recordSave_talliesCountAndDurationPerSource() {
        let inst = makeEnabled()
        inst.recordSave(source: "safeSave", durationMs: 4)
        inst.recordSave(source: "safeSave", durationMs: 6)
        inst.recordSave(source: "rawWriteProbe", durationMs: 10)

        let snap = inst.snapshot()
        XCTAssertEqual(snap.saves["safeSave"]?.count, 2)
        XCTAssertEqual(snap.saves["safeSave"]?.totalDurationMs, 10)
        XCTAssertEqual(snap.saves["rawWriteProbe"]?.count, 1)
        XCTAssertEqual(snap.saves["rawWriteProbe"]?.totalDurationMs, 10)
    }

    // MARK: - Defaults-write accounting (the app-group plist churn suspect)

    func test_recordDefaultsWrite_talliesPerSource() {
        let inst = makeEnabled()
        inst.recordDefaultsWrite(source: "widget")
        inst.recordDefaultsWrite(source: "widget")
        inst.recordDefaultsWrite(source: "queue")

        let snap = inst.snapshot()
        XCTAssertEqual(snap.defaultsWrites["widget"], 2)
        XCTAssertEqual(snap.defaultsWrites["queue"], 1)
    }

    // MARK: - Rows-changed per save (distinguishes bulk re-persist from a 1-row progress save)

    func test_recordRows_tracksTotalAndMaxPerSave() {
        let inst = makeEnabled()
        inst.recordRows(1)    // progress save
        inst.recordRows(300)  // bulk persistNewPodcasts
        inst.recordRows(2)

        let snap = inst.snapshot()
        XCTAssertEqual(snap.totalRowsWritten, 303)
        XCTAssertEqual(snap.maxRowsInOneSave, 300)
    }

    // MARK: - Suspension assertion accounting

    func test_recordAssertion_countsGrantedAndDeclined() {
        let inst = makeEnabled()
        inst.recordAssertion(name: "safeSave", granted: true)
        inst.recordAssertion(name: "safeSave", granted: true)
        inst.recordAssertion(name: "safeSave", granted: false)

        let snap = inst.snapshot()
        XCTAssertEqual(snap.assertionsGranted, 2)
        XCTAssertEqual(snap.assertionsDeclined, 1)
    }

    // MARK: - Single-writer overlap detection

    func test_overlappingWindows_recordOverlapAndPeakConcurrency() {
        let inst = makeEnabled()
        // Two windows open at once = two concurrent writers on the store.
        inst.beginWriteWindow()
        inst.beginWriteWindow()
        inst.endWriteWindow()
        inst.endWriteWindow()

        let snap = inst.snapshot()
        XCTAssertEqual(snap.writerOverlaps, 1, "A second writer opening while one is active is one overlap")
        XCTAssertEqual(snap.maxConcurrentWriters, 2)
    }

    /// An overlap is only actionable if we know WHICH two writers raced.
    /// Record the concurrent source names (sorted, joined) so a soak capture
    /// pinpoints the single-writer race (e.g. "preflightCheck+safeSave") instead of a
    /// bare count.
    func test_overlappingWindows_recordConcurrentSourceNames() {
        let inst = makeEnabled()
        inst.beginWriteWindow(source: "safeSave")
        inst.beginWriteWindow(source: "rawWriteProbe") // opens while safeSave is active
        inst.endWriteWindow(source: "rawWriteProbe")
        inst.endWriteWindow(source: "safeSave")

        let snap = inst.snapshot()
        XCTAssertEqual(snap.writerOverlaps, 1)
        XCTAssertEqual(snap.overlapSources["rawWriteProbe+safeSave"], 1,
                       "An overlap must record which two writers were concurrent (sorted, joined)")
    }

    func test_sequentialWindows_recordNoOverlap() {
        let inst = makeEnabled()
        inst.beginWriteWindow()
        inst.endWriteWindow()
        inst.beginWriteWindow()
        inst.endWriteWindow()

        let snap = inst.snapshot()
        XCTAssertEqual(snap.writerOverlaps, 0)
        XCTAssertEqual(snap.maxConcurrentWriters, 1)
    }

    // MARK: - Reset

    func test_reset_clearsAllCounters() {
        let inst = makeEnabled()
        inst.recordSave(source: "safeSave", durationMs: 5)
        inst.recordDefaultsWrite(source: "widget")
        inst.recordAssertion(name: "safeSave", granted: false)
        inst.beginWriteWindow(); inst.endWriteWindow()

        inst.reset()

        let snap = inst.snapshot()
        XCTAssertTrue(snap.saves.isEmpty)
        XCTAssertTrue(snap.defaultsWrites.isEmpty)
        XCTAssertEqual(snap.assertionsGranted, 0)
        XCTAssertEqual(snap.assertionsDeclined, 0)
        XCTAssertEqual(snap.writerOverlaps, 0)
        XCTAssertEqual(snap.maxConcurrentWriters, 0)
    }

    // MARK: - Disabled = zero overhead, records nothing

    func test_disabledInstance_recordsNothing() {
        let inst = WriteInstrumentation(enabled: false)
        inst.recordSave(source: "safeSave", durationMs: 5)
        inst.recordDefaultsWrite(source: "widget")
        inst.recordAssertion(name: "safeSave", granted: true)
        inst.beginWriteWindow(); inst.beginWriteWindow()

        let snap = inst.snapshot()
        XCTAssertTrue(snap.saves.isEmpty)
        XCTAssertTrue(snap.defaultsWrites.isEmpty)
        XCTAssertEqual(snap.assertionsGranted, 0)
        XCTAssertEqual(snap.assertionsDeclined, 0)
        XCTAssertEqual(snap.writerOverlaps, 0)
        XCTAssertEqual(snap.maxConcurrentWriters, 0)
    }

    // MARK: - Changed-keys attribution (which entity.property actually churns)

    /// To pinpoint the re-persist churn we need to know WHICH property on
    /// WHICH entity is being re-written. Observing NSManagedObjectContextWillSave
    /// (where changedValues() is populated) must tally `Entity.property → count`.
    @MainActor
    func test_observeContextSaves_attributesChangedPropertyByEntity() async throws {
        let inst = makeEnabled()
        WriteInstrumentation.shared = inst

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        inst.observeContextSaves()
        let ctx = container.mainContext

        let pod = Podcast(url: "https://example.com/feed", title: "Original")
        ctx.insert(pod)
        try ctx.save()

        inst.reset() // drop the insert; measure only the next change
        pod.title = "Changed Title"
        try ctx.save()

        let snap = inst.snapshot()
        XCTAssertEqual(snap.dirtyKeys["Podcast.title"], 1,
                       "a changed Podcast.title must be attributed as Entity.property in dirtyKeys")
    }

    // MARK: - Report formatting

    func test_formatReport_includesSourcesAssertionsOverlapAndFileSizes() {
        let inst = makeEnabled()
        inst.recordSave(source: "safeSave", durationMs: 12)
        inst.recordDefaultsWrite(source: "widget")
        inst.recordAssertion(name: "safeSave", granted: false)
        inst.recordRows(300)
        inst.beginWriteWindow(); inst.beginWriteWindow(); inst.endWriteWindow(); inst.endWriteWindow()

        let report = inst.formatReport(fileSizes: ["store-wal": 1_048_576])

        XCTAssertTrue(report.contains("rows"), "report should surface rows-changed per cycle")
        XCTAssertTrue(report.contains("safeSave"), "report should attribute saves by source")
        XCTAssertTrue(report.contains("widget"), "report should attribute defaults writes by source")
        XCTAssertTrue(report.contains("declined") || report.contains("DECLINED"), "report should surface declined assertions")
        XCTAssertTrue(report.contains("overlap"), "report should surface writer overlaps")
        XCTAssertTrue(report.contains("store-wal"), "report should surface sampled file sizes")
    }

    // MARK: - Integration: the SuspensionGuard funnel feeds instrumentation

    func test_withProtection_recordsOneSaveWindow_whenInstrumentationEnabled() {
        let inst = makeEnabled()
        WriteInstrumentation.shared = inst

        // A no-op acquire so we exercise withProtection's instrumentation, not UIKit.
        let guardInstance = SuspensionGuard(acquire: { _ in { } })
        guardInstance.withProtection("safeSave") { }

        let snap = inst.snapshot()
        XCTAssertEqual(snap.saves["safeSave"]?.count, 1)
        XCTAssertEqual(snap.maxConcurrentWriters, 1)
        XCTAssertEqual(snap.writerOverlaps, 0)
    }
}

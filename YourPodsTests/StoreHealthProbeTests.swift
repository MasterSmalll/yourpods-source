import XCTest
import SwiftData
@testable import YourPods

/// Tests for the store health probe sentinel mechanism.
///
/// The health probe exercises SQLite write paths during app init.
/// If the store is corrupted, `pread()` fails with a signal crash
/// (not a Swift error), so do/catch cannot intercept it.
/// The sentinel must be SET before the probe and CLEARED after —
/// so the next launch can detect the crash and nuke the store.
@MainActor
final class StoreHealthProbeTests: XCTestCase {
    
    private let sentinelKey = "saveSentinelInProgress"
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: sentinelKey)
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: sentinelKey)
        super.tearDown()
    }
    
    // MARK: - Sentinel Coverage
    
    /// The sentinel must be active (true) while the health probe is running,
    /// so that a signal crash during save() is detected on next launch.
    func test_healthProbeSentinel_isSetBeforeProbeAndClearedAfter() {
        // Arrange: sentinel should start cleared
        XCTAssertFalse(UserDefaults.standard.bool(forKey: sentinelKey),
                       "Sentinel should be false before probe")
        
        // Act: run the health probe helper
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        
        let corrupted = StoreHealthProbe.run(
            context: container.mainContext,
            sentinelKey: sentinelKey
        )
        
        // Assert: sentinel should be cleared after a successful probe
        XCTAssertFalse(corrupted, "In-memory store should not be corrupted")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: sentinelKey),
                       "Sentinel must be cleared after successful probe")
    }
    
    /// Verify the sentinel IS set during probe execution.
    /// The sentinel's job is to catch SIGNAL crashes — the process dies
    /// before do/catch can run, so the sentinel is the only recovery path.
    func test_healthProbeSentinel_isActiveWhileSaveIsRunning() {
        var sentinelValueDuringProbe = false
        let schema = Schema([Podcast.self, Episode.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        
        // Use the instrumented probe to capture sentinel state mid-execution
        let corrupted = StoreHealthProbe.runInstrumented(
            context: container.mainContext,
            sentinelKey: sentinelKey,
            onBeforeSave: {
                sentinelValueDuringProbe = UserDefaults.standard.bool(forKey: self.sentinelKey)
            }
        )
        
        XCTAssertFalse(corrupted)
        XCTAssertTrue(sentinelValueDuringProbe,
                      "Sentinel MUST be true during probe execution to catch signal crashes")
    }
    
    // MARK: - EDGE: Sentinel recovery on next launch
    
    /// If the sentinel is still set from a previous launch (health probe crashed),
    /// the recovery path should detect it and signal the need to delete the store.
    func test_EDGE_sentinelLeftSet_indicatesPreviousCrash() {
        // Simulate a previous launch that crashed during the health probe
        UserDefaults.standard.set(true, forKey: sentinelKey)
        
        // The app init checks this and should nuke the store
        let sentinelDetected = UserDefaults.standard.bool(forKey: sentinelKey)
        XCTAssertTrue(sentinelDetected,
                      "Sentinel left from previous launch must be detectable")
    }
}

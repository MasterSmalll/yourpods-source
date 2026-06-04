import XCTest
@testable import YourPods

// MARK: - Download Cleanup Settings Tests

/// Tests that download cleanup policy correctly distinguishes nil (use global)
/// from explicit values, matching the auto-queue pattern.
final class DownloadCleanupSettingsTests: XCTestCase {
    
    func test_newPodcastSettings_downloadCleanupPolicyIsNil() {
        let settings = PodcastSettings()
        XCTAssertNil(settings.downloadCleanupPolicy,
                     "New settings must default to nil for cleanup policy")
    }
    
    func test_downloadCleanupPolicy_nilFallsToGlobal() {
        let settings = PodcastSettings()
        let globalDefault: DownloadCleanupPolicy = .afterOneWeek
        
        let effective = settings.downloadCleanupPolicy ?? globalDefault
        XCTAssertEqual(effective, .afterOneWeek,
                       "nil cleanup policy should fall through to global default")
    }
    
    func test_downloadCleanupPolicy_explicitOverridesGlobal() {
        var settings = PodcastSettings()
        settings.downloadCleanupPolicy = .never
        let globalDefault: DownloadCleanupPolicy = .oncePlayed
        
        let effective = settings.downloadCleanupPolicy ?? globalDefault
        XCTAssertEqual(effective, .never,
                       "Explicit .never should override global .oncePlayed")
    }
}

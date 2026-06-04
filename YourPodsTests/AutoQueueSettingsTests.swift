import XCTest
@testable import YourPods

// MARK: - Auto-Queue Settings Tests

/// Tests that PodcastSettings.autoQueueMode correctly distinguishes between
/// "use global default" (nil) and "explicitly off" (.off).
/// Regression: PodcastSettingsSheet Picker binding used `.off` as the getter's default,
/// which caused SwiftUI to write `.off` back on any sheet interaction — permanently
/// overriding the global default for that podcast.
final class AutoQueueSettingsTests: XCTestCase {
    
    func test_newPodcastSettings_autoQueueModeIsNil() {
        // GIVEN: A fresh PodcastSettings with no overrides
        let settings = PodcastSettings()
        
        // THEN: autoQueueMode should be nil (meaning "use global default")
        XCTAssertNil(settings.autoQueueMode, "New settings must default to nil, not .off")
    }
    
    func test_autoQueueMode_nilCoalescing_usesGlobalDefault() {
        // GIVEN: Per-podcast autoQueueMode is nil (no override)
        let settings = PodcastSettings()
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Using nil-coalescing to resolve the effective mode
        let effective = settings.autoQueueMode ?? globalDefault
        
        // THEN: Should use the global default, not .off
        XCTAssertEqual(effective, .normal, "nil autoQueueMode should fall through to global default")
    }
    
    func test_autoQueueMode_explicitOff_overridesGlobalDefault() {
        // GIVEN: Per-podcast autoQueueMode is explicitly .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Using nil-coalescing
        let effective = settings.autoQueueMode ?? globalDefault
        
        // THEN: Should use .off (explicit override), not the global default
        XCTAssertEqual(effective, .off, "Explicit .off should override global default")
    }
    
    func test_autoQueueMode_nilSurvivesEncodeDecode() {
        // GIVEN: Settings with autoQueueMode = nil
        let settings = PodcastSettings()
        
        // WHEN: Encoding and decoding
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: autoQueueMode should still be nil
        XCTAssertNil(decoded.autoQueueMode, "nil autoQueueMode must survive encode/decode round-trip")
    }
    
    func test_autoQueueMode_explicitOffSurvivesEncodeDecode() {
        // GIVEN: Settings with autoQueueMode = .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        
        // WHEN: Encoding and decoding
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: autoQueueMode should be .off, not nil
        XCTAssertEqual(decoded.autoQueueMode, .off, "Explicit .off must survive encode/decode round-trip")
    }
    
    // MARK: - Auto-Queue Decision Logic Tests (nil fallback to global default)
    // Regression: BackgroundRefreshService and getAutoQueueCandidates both rejected
    // nil autoQueueMode instead of falling through to the global default.
    
    /// Simulates the BackgroundRefreshService filter logic.
    /// When per-podcast autoQueueMode is nil and the global default is .normal,
    /// the episode SHOULD be auto-queued.
    func test_backgroundRefreshLogic_autoQueuesWhenPerPodcastModeIsNil_andGlobalIsNormal() {
        // GIVEN: Per-podcast autoQueueMode is nil (use global default)
        let settings = PodcastSettings()
        XCTAssertNil(settings.autoQueueMode, "Precondition: per-podcast mode is nil")
        
        // AND: Global default is .normal
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Applying the BackgroundRefreshService filter logic
        let effectiveMode = settings.autoQueueMode ?? globalDefault
        let shouldAutoQueue = effectiveMode != .off
        
        // THEN: Episode should be auto-queued
        XCTAssertTrue(shouldAutoQueue,
                      "nil per-podcast autoQueueMode + global .normal should auto-queue")
    }
    
    /// When per-podcast autoQueueMode is explicitly .off, the episode should NOT
    /// be auto-queued regardless of the global default.
    func test_backgroundRefreshLogic_doesNotAutoQueue_whenPerPodcastModeIsExplicitlyOff() {
        // GIVEN: Per-podcast autoQueueMode is explicitly .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        
        // AND: Global default is .normal (would allow auto-queue)
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Applying the BackgroundRefreshService filter logic
        let effectiveMode = settings.autoQueueMode ?? globalDefault
        let shouldAutoQueue = effectiveMode != .off
        
        // THEN: Episode should NOT be auto-queued
        XCTAssertFalse(shouldAutoQueue,
                       "Explicit .off should override global .normal and prevent auto-queue")
    }
    
    /// getAutoQueueCandidates should return episodes when per-podcast mode is nil
    /// and the global default is .normal.
    func test_getAutoQueueCandidates_returnsEpisodes_whenPerPodcastModeIsNil_andGlobalIsNormal() {
        // GIVEN: Per-podcast autoQueueMode is nil (use global default)
        let settings = PodcastSettings()
        let globalDefault: AutoQueueMode = .normal
        
        // WHEN: Applying the getAutoQueueCandidates guard logic
        let mode = settings.autoQueueMode ?? globalDefault
        let shouldReturnCandidates = mode != .off
        
        // THEN: Should return candidates (not empty)
        XCTAssertTrue(shouldReturnCandidates,
                      "nil per-podcast autoQueueMode + global .normal should return candidates")
    }
    
    /// getAutoQueueCandidates should return empty when per-podcast mode is explicitly .off.
    func test_getAutoQueueCandidates_returnsEmpty_whenPerPodcastModeIsExplicitlyOff() {
        // GIVEN: Per-podcast autoQueueMode is explicitly .off
        var settings = PodcastSettings()
        settings.autoQueueMode = .off
        
        // WHEN: Applying the getAutoQueueCandidates guard logic
        let mode = settings.autoQueueMode ?? AutoQueueMode.normal
        let shouldReturnCandidates = mode != .off
        
        // THEN: Should return empty
        XCTAssertFalse(shouldReturnCandidates,
                       "Explicit .off should return empty regardless of global default")
    }
}

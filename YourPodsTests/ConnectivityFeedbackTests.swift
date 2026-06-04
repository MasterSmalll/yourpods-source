import XCTest
@testable import YourPods

// MARK: - OfflineBanner Logic Tests

final class OfflineBannerLogicTests: XCTestCase {
    
    // MARK: - Banner Visibility
    
    func test_offlineBanner_hiddenWhenConnected() {
        let monitor = MockNetworkMonitor(isConnected: true)
        
        let shouldShow = OfflineBannerLogic.shouldShowBanner(
            isConnected: monitor.isConnected,
            isVaultMode: false
        )
        
        XCTAssertFalse(shouldShow, "Banner should be hidden when network is connected")
    }
    
    func test_offlineBanner_visibleWhenDisconnected() {
        let monitor = MockNetworkMonitor(isExpensive: false, isConnected: false)
        
        let shouldShow = OfflineBannerLogic.shouldShowBanner(
            isConnected: monitor.isConnected,
            isVaultMode: false
        )
        
        XCTAssertTrue(shouldShow, "Banner should be visible when network is disconnected")
    }
    
    func test_offlineBanner_suppressedInVaultMode() {
        let monitor = MockNetworkMonitor(isExpensive: false, isConnected: false)
        
        let shouldShow = OfflineBannerLogic.shouldShowBanner(
            isConnected: monitor.isConnected,
            isVaultMode: true
        )
        
        XCTAssertFalse(shouldShow, "Banner should be suppressed in Vault Mode even when disconnected")
    }
    
    func test_offlineBanner_visibleInVaultModeWhenStreamingError() {
        // Even in Vault Mode, playback errors should be shown
        let shouldShow = OfflineBannerLogic.shouldShowPlaybackError(
            errorMessage: "Playback failed. Check your connection.",
            isVaultMode: true
        )
        
        XCTAssertTrue(shouldShow, "Playback errors should always be shown, even in Vault Mode")
    }
    
    // MARK: - Playback Error State
    
    func test_playbackError_hiddenWhenNoError() {
        let shouldShow = OfflineBannerLogic.shouldShowPlaybackError(
            errorMessage: nil,
            isVaultMode: false
        )
        
        XCTAssertFalse(shouldShow, "Playback error should be hidden when there is no error")
    }
    
    func test_playbackError_visibleWhenErrorSet() {
        let shouldShow = OfflineBannerLogic.shouldShowPlaybackError(
            errorMessage: "Playback failed. Check your connection.",
            isVaultMode: false
        )
        
        XCTAssertTrue(shouldShow, "Playback error should be visible when errorMessage is set")
    }
    
    func test_playbackError_hiddenForEmptyString() {
        let shouldShow = OfflineBannerLogic.shouldShowPlaybackError(
            errorMessage: "",
            isVaultMode: false
        )
        
        XCTAssertFalse(shouldShow, "Playback error should be hidden for empty error string")
    }
    
    // MARK: - Vault Mode Detection
    
    func test_isVaultMode_trueForLocalProfile() {
        let suiteName = "test_vault_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        
        let settings = SettingsManager(defaults: defaults)
        let localProfile = ServerProfile(name: "Vault", baseUrl: nil)
        settings.activeProfileId = localProfile.id
        
        // Save the profile
        let data = try! JSONEncoder().encode([localProfile])
        defaults.set(data, forKey: "serverProfiles")
        
        // Vault Mode = local profile (no baseUrl)
        let isVault = settings.isVaultMode
        XCTAssertTrue(isVault, "Should detect Vault Mode when active profile has no baseUrl")
    }
    
    func test_isVaultMode_falseForSyncProfile() {
        let suiteName = "test_sync_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        
        let settings = SettingsManager(defaults: defaults)
        let syncProfile = ServerProfile(name: "Nextcloud", baseUrl: "https://cloud.example.com")
        settings.activeProfileId = syncProfile.id
        
        let data = try! JSONEncoder().encode([syncProfile])
        defaults.set(data, forKey: "serverProfiles")
        
        let isVault = settings.isVaultMode
        XCTAssertFalse(isVault, "Should not detect Vault Mode when active profile has a baseUrl")
    }
    
    func test_isVaultMode_falseWhenNoProfile() {
        let suiteName = "test_none_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        
        let settings = SettingsManager(defaults: defaults)
        settings.activeProfileId = nil
        
        let isVault = settings.isVaultMode
        XCTAssertFalse(isVault, "Should not detect Vault Mode when no profile is active")
    }
}

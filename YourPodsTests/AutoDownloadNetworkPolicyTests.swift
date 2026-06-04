import XCTest
import SwiftData
@testable import YourPods

// MARK: - Mock Network Monitor

/// Mock for injecting network state in tests.
final class MockNetworkMonitor: NetworkMonitoring {
    var isExpensive: Bool
    var isConnected: Bool
    var onConnectivityRestored: (() -> Void)?
    
    init(isExpensive: Bool = false, isConnected: Bool = true) {
        self.isExpensive = isExpensive
        self.isConnected = isConnected
    }
}

// MARK: - AutoDownloadNetworkPolicy Tests

/// Tests for the network-gated autodownload policy logic.
/// Verifies that downloads are correctly allowed or blocked
/// based on the user's network policy and current network type.
@MainActor
final class AutoDownloadNetworkPolicyTests: XCTestCase {
    
    // MARK: - Wi-Fi Only
    
    func test_wifiOnly_allowsDownload_whenOnWiFi() {
        let policy = AutoDownloadNetworkPolicy.wifiOnly
        XCTAssertTrue(policy.shouldDownload(isExpensive: false),
                      "Wi-Fi Only should allow downloads on non-expensive (Wi-Fi) networks")
    }
    
    func test_wifiOnly_blocksDownload_whenOnCellular() {
        let policy = AutoDownloadNetworkPolicy.wifiOnly
        XCTAssertFalse(policy.shouldDownload(isExpensive: true),
                       "Wi-Fi Only should block downloads on expensive (cellular) networks")
    }
    
    // MARK: - Cellular Only
    
    func test_cellularOnly_allowsDownload_whenOnCellular() {
        let policy = AutoDownloadNetworkPolicy.cellularOnly
        XCTAssertTrue(policy.shouldDownload(isExpensive: true),
                      "Cellular Only should allow downloads on expensive (cellular) networks")
    }
    
    func test_cellularOnly_blocksDownload_whenOnWiFi() {
        let policy = AutoDownloadNetworkPolicy.cellularOnly
        XCTAssertFalse(policy.shouldDownload(isExpensive: false),
                       "Cellular Only should block downloads on non-expensive (Wi-Fi) networks")
    }
    
    // MARK: - Wi-Fi & Cellular
    
    func test_wifiAndCellular_allowsDownload_whenOnWiFi() {
        let policy = AutoDownloadNetworkPolicy.wifiAndCellular
        XCTAssertTrue(policy.shouldDownload(isExpensive: false),
                      "Wi-Fi & Cellular should allow downloads on Wi-Fi")
    }
    
    func test_wifiAndCellular_allowsDownload_whenOnCellular() {
        let policy = AutoDownloadNetworkPolicy.wifiAndCellular
        XCTAssertTrue(policy.shouldDownload(isExpensive: true),
                      "Wi-Fi & Cellular should allow downloads on cellular")
    }
    
    // MARK: - Display Names
    
    func test_displayName_isCorrect() {
        XCTAssertEqual(AutoDownloadNetworkPolicy.wifiOnly.displayName, "Wi-Fi Only")
        XCTAssertEqual(AutoDownloadNetworkPolicy.cellularOnly.displayName, "Cellular Only")
        XCTAssertEqual(AutoDownloadNetworkPolicy.wifiAndCellular.displayName, "Wi-Fi & Cellular")
    }
    
    // MARK: - Raw Value Encoding
    
    func test_rawValue_roundTrips() {
        for policy in AutoDownloadNetworkPolicy.allCases {
            let decoded = AutoDownloadNetworkPolicy(rawValue: policy.rawValue)
            XCTAssertEqual(decoded, policy,
                           "\(policy.rawValue) should round-trip through rawValue")
        }
    }
    
    // MARK: - SettingsManager Integration
    
    func test_settingsManager_defaultsToWiFiOnly() {
        // Use a clean UserDefaults suite to avoid test pollution
        let defaults = UserDefaults(suiteName: "test-autodownload-policy")!
        defaults.removePersistentDomain(forName: "test-autodownload-policy")
        
        let settings = SettingsManager(defaults: defaults)
        
        XCTAssertEqual(settings.autoDownloadNetworkPolicy, .wifiOnly,
                       "Default network policy should be Wi-Fi Only")
    }
    
    func test_settingsManager_persistsNetworkPolicy() {
        let defaults = UserDefaults(suiteName: "test-autodownload-policy-persist")!
        defaults.removePersistentDomain(forName: "test-autodownload-policy-persist")
        
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .cellularOnly
        
        // Create a new instance to verify persistence
        let settings2 = SettingsManager(defaults: defaults)
        XCTAssertEqual(settings2.autoDownloadNetworkPolicy, .cellularOnly,
                       "Network policy should persist across SettingsManager instances")
    }
    
    func test_settingsManager_setsWiFiAndCellular() {
        let defaults = UserDefaults(suiteName: "test-autodownload-policy-both")!
        defaults.removePersistentDomain(forName: "test-autodownload-policy-both")
        
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .wifiAndCellular
        
        XCTAssertEqual(settings.autoDownloadNetworkPolicy, .wifiAndCellular)
    }
    
    // MARK: - PodcastManager.isAutoDownloadAllowed Integration
    
    func test_isAutoDownloadAllowed_blocksOnCellular_whenWiFiOnly() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let manager = PodcastManager(modelContext: container.mainContext)
        
        let mockNetwork = MockNetworkMonitor(isExpensive: true)
        manager.networkMonitor = mockNetwork
        
        let defaults = UserDefaults(suiteName: "test-adnp-wifi-only-cellular")!
        defaults.removePersistentDomain(forName: "test-adnp-wifi-only-cellular")
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .wifiOnly
        
        XCTAssertFalse(manager.isAutoDownloadAllowed(settingsManager: settings),
                       "Wi-Fi Only policy should block downloads on cellular (expensive) network")
    }
    
    func test_isAutoDownloadAllowed_allowsOnWiFi_whenWiFiOnly() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let manager = PodcastManager(modelContext: container.mainContext)
        
        let mockNetwork = MockNetworkMonitor(isExpensive: false)
        manager.networkMonitor = mockNetwork
        
        let defaults = UserDefaults(suiteName: "test-adnp-wifi-only-wifi")!
        defaults.removePersistentDomain(forName: "test-adnp-wifi-only-wifi")
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .wifiOnly
        
        XCTAssertTrue(manager.isAutoDownloadAllowed(settingsManager: settings),
                      "Wi-Fi Only policy should allow downloads on Wi-Fi (non-expensive) network")
    }
    
    func test_isAutoDownloadAllowed_blocksOnWiFi_whenCellularOnly() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let manager = PodcastManager(modelContext: container.mainContext)
        
        let mockNetwork = MockNetworkMonitor(isExpensive: false)
        manager.networkMonitor = mockNetwork
        
        let defaults = UserDefaults(suiteName: "test-adnp-cellular-only-wifi")!
        defaults.removePersistentDomain(forName: "test-adnp-cellular-only-wifi")
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .cellularOnly
        
        XCTAssertFalse(manager.isAutoDownloadAllowed(settingsManager: settings),
                       "Cellular Only policy should block downloads on Wi-Fi (non-expensive) network")
    }
    
    func test_isAutoDownloadAllowed_allowsOnCellular_whenCellularOnly() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let manager = PodcastManager(modelContext: container.mainContext)
        
        let mockNetwork = MockNetworkMonitor(isExpensive: true)
        manager.networkMonitor = mockNetwork
        
        let defaults = UserDefaults(suiteName: "test-adnp-cellular-only-cellular")!
        defaults.removePersistentDomain(forName: "test-adnp-cellular-only-cellular")
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .cellularOnly
        
        XCTAssertTrue(manager.isAutoDownloadAllowed(settingsManager: settings),
                      "Cellular Only policy should allow downloads on cellular (expensive) network")
    }
    
    func test_isAutoDownloadAllowed_alwaysAllows_whenWiFiAndCellular() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        let manager = PodcastManager(modelContext: container.mainContext)
        
        let defaults = UserDefaults(suiteName: "test-adnp-both")!
        defaults.removePersistentDomain(forName: "test-adnp-both")
        let settings = SettingsManager(defaults: defaults)
        settings.autoDownloadNetworkPolicy = .wifiAndCellular
        
        // Should allow on Wi-Fi
        manager.networkMonitor = MockNetworkMonitor(isExpensive: false)
        XCTAssertTrue(manager.isAutoDownloadAllowed(settingsManager: settings),
                      "Wi-Fi & Cellular should allow downloads on Wi-Fi")
        
        // Should also allow on cellular
        manager.networkMonitor = MockNetworkMonitor(isExpensive: true)
        XCTAssertTrue(manager.isAutoDownloadAllowed(settingsManager: settings),
                      "Wi-Fi & Cellular should allow downloads on cellular")
    }
}

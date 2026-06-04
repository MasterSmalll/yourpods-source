import Foundation
import Network
import os

/// Protocol for network type detection, enabling test injection.
protocol NetworkMonitoring {
    /// True when the current network path is expensive (cellular, hotspot, or Low Data Mode).
    var isExpensive: Bool { get }
    /// True when the device has any network connectivity.
    var isConnected: Bool { get }
    /// Callback fired when connectivity transitions from disconnected → connected.
    /// AudioManager subscribes to this to auto-retry after network outages.
    var onConnectivityRestored: (() -> Void)? { get set }
}

/// Monitors network type (WiFi vs cellular) using NWPathMonitor.
/// Used to gate autodownloads and surface offline state in the UI.
///
/// `@Observable` so SwiftUI views react to connectivity changes instantly.
/// Property updates are dispatched to MainActor to ensure UI thread safety.
@Observable
final class NetworkMonitor: NetworkMonitoring {
    @ObservationIgnored private let logger = Logger(subsystem: "com.yourpods", category: "NetworkMonitor")
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.yourpods.networkmonitor")
    
    private(set) var isExpensive: Bool = false
    private(set) var isConnected: Bool = true
    
    /// Callback fired when connectivity transitions from disconnected → connected.
    @ObservationIgnored var onConnectivityRestored: (() -> Void)?
    
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Dispatch to MainActor so @Observable mutations trigger SwiftUI updates
            DispatchQueue.main.async {
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isExpensive = path.isExpensive
                self.isConnected = path.status == .satisfied
                
                // Fire restoration callback on disconnected → connected transition
                if !wasConnected && self.isConnected {
                    self.logger.info("Connectivity restored — notifying subscribers")
                    self.onConnectivityRestored?()
                }
            }
        }
        monitor.start(queue: queue)
        logger.info("Network monitor started")
    }
    
    deinit {
        monitor.cancel()
    }
}

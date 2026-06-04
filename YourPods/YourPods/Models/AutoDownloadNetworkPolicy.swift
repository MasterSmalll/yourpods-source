import Foundation

/// Controls which network types are allowed for automatic episode downloads.
/// Manual downloads from the UI are always unrestricted.
enum AutoDownloadNetworkPolicy: String, CaseIterable {
    /// Download only when on Wi-Fi (non-expensive network).
    case wifiOnly
    /// Download only when on cellular (expensive network).
    case cellularOnly
    /// Download on any available network.
    case wifiAndCellular
    
    /// User-facing display name for settings UI.
    var displayName: String {
        switch self {
        case .wifiOnly: return "Wi-Fi Only"
        case .cellularOnly: return "Cellular Only"
        case .wifiAndCellular: return "Wi-Fi & Cellular"
        }
    }
    
    /// Whether autodownloads should proceed given the current network state.
    /// - Parameter isExpensive: True when the network is cellular/hotspot/Low Data Mode.
    /// - Returns: True if downloads are allowed on this network type.
    func shouldDownload(isExpensive: Bool) -> Bool {
        switch self {
        case .wifiOnly:
            return !isExpensive
        case .cellularOnly:
            return isExpensive
        case .wifiAndCellular:
            return true
        }
    }
}

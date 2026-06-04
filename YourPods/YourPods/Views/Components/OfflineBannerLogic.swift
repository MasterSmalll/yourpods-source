import Foundation

/// Pure logic for deciding when to show offline/connectivity UI.
/// Extracted from the view layer for testability.
enum OfflineBannerLogic {
    
    /// Whether the general "No Connection" banner should display.
    /// Suppressed in Vault Mode since there's no server dependency.
    static func shouldShowBanner(isConnected: Bool, isVaultMode: Bool) -> Bool {
        guard !isVaultMode else { return false }
        return !isConnected
    }
    
    /// Whether a playback error message should display.
    /// Always shown regardless of Vault Mode — streaming can fail in any mode.
    static func shouldShowPlaybackError(errorMessage: String?, isVaultMode: Bool) -> Bool {
        guard let message = errorMessage, !message.isEmpty else { return false }
        return true
    }
}

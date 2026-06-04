import Foundation

/// Helper providing consistent label, icon, and accessibility strings for episode download
/// context menu items across the app (QueueView, HomeView, PodcastDetailView).
enum EpisodeDownloadHelper {
    
    /// Returns the menu label text for the download action.
    /// - Parameter isDownloaded: Whether the episode is currently downloaded.
    /// - Returns: "Download" or "Remove Download".
    static func downloadLabel(isDownloaded: Bool) -> String {
        isDownloaded ? "Remove Download" : "Download"
    }
    
    /// Returns the SF Symbol name for the download action icon.
    /// - Parameter isDownloaded: Whether the episode is currently downloaded.
    /// - Returns: "arrow.down.circle" or "trash".
    static func downloadIcon(isDownloaded: Bool) -> String {
        isDownloaded ? "trash" : "arrow.down.circle"
    }
    
    /// Returns the VoiceOver accessibility action name for the download button.
    /// - Parameter isDownloaded: Whether the episode is currently downloaded.
    /// - Returns: "Download" or "Remove Download".
    static func accessibilityActionName(isDownloaded: Bool) -> String {
        isDownloaded ? "Remove Download" : "Download"
    }
}

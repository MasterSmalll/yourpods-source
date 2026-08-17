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
    /// - Returns: "Download" or "Remove Download", localized.
    ///
    /// Forwards to `EpisodeAccessibility.Action` so this and the rotor action
    /// lists share one catalog key per command. A second literal here would be
    /// a second key, free to drift to a different word in German.
    static func accessibilityActionName(isDownloaded: Bool) -> String {
        isDownloaded ? EpisodeAccessibility.Action.removeDownload
                     : EpisodeAccessibility.Action.download
    }
}

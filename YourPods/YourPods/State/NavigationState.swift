import SwiftUI

/// Shared navigation state for cross-tab programmatic navigation.
@Observable
final class NavigationState {
    var selectedTab: Int
    
    init() {
        let startPage = UserDefaults.standard.string(forKey: "defaultStartPage") ?? "home"
        switch startPage {
        case "library": selectedTab = 1
        case "upnext": selectedTab = 2
        default: selectedTab = 0
        }
    }
    
    /// Set by the migration flow to trigger profile management after migration.
    var showProfileManagement = false
    /// Message to show in the post-migration alert.
    var migrationAlertMessage: String?
    
    /// Podcast to navigate to in the Library tab (set by EpisodeDetailSheet podcast link).
    var podcastToNavigate: Podcast?
    
    func switchToAddPodcasts() {
        selectedTab = 3
    }
    
    /// Navigate to a podcast's detail page in the Library tab.
    /// Dismisses any sheet, switches to Library, and queues the push.
    func navigateToLibrary(podcast: Podcast) {
        podcastToNavigate = podcast
        selectedTab = 1
    }
}

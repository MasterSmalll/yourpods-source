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
    
    func switchToAddPodcasts() {
        selectedTab = 3
    }
}

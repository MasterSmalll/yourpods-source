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

    // MARK: - Deep-link share presentation

    /// Preview sheets for not-followed shared content (root view observes these).
    var pendingSharedEpisode: SharedEpisode?
    var pendingSharedPodcast: SharedPodcast?
    /// Known (followed) shared episode → present the real EpisodeDetailSheet at root.
    var deepLinkEpisode: GuidSheetItem?
    /// Known podcast deep link → ContentView routes to Library.
    var knownPodcastFeedToOpen: String?
    /// A deep link couldn't be resolved → ContentView shows a brief alert.
    var deepLinkFailed = false

    /// Apply a router outcome to the presentation state.
    func apply(_ outcome: DeepLinkOutcome) {
        switch outcome {
        case .knownEpisode(let guid):   deepLinkEpisode = GuidSheetItem(id: guid)
        case .previewEpisode(let s):    pendingSharedEpisode = s
        case .knownPodcast(let feed):   knownPodcastFeedToOpen = feed
        case .previewPodcast(let s):    pendingSharedPodcast = s
        case .failed:                   deepLinkFailed = true
        }
    }
}

/// Identity wrapper so a known-episode deep-link guid can drive `.sheet(item:)`.
struct GuidSheetItem: Identifiable, Equatable { let id: String }

import Foundation
import SwiftUI

/// How the tab bar displays labels.
enum TabBarDisplayMode: String, Codable, CaseIterable {
    case textOnly
    case iconOnly
    case textAndIcon
}

/// Which podcast search provider to use.
enum SearchProvider: String, Codable, CaseIterable {
    case itunes
    case podcastIndex
}

/// App appearance mode.
enum AppAppearance: String, Codable, CaseIterable {
    case system
    case light
    case dark
    
    /// Convert to SwiftUI ColorScheme (nil = follow system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to do when removing an episode from the Up Next queue.
enum QueueRemovalAction: String, Codable, CaseIterable {
    /// Just remove from queue without changing play status.
    case removeOnly
    /// Remove from queue and mark the episode as played.
    case removeAndMarkPlayed
    /// Always prompt the user to choose.
    case ask
}

/// Action triggered by AirPods / lock screen next/previous track commands.
enum RemoteCommandAction: String, Codable, CaseIterable {
    /// Skip backward by the user's configured skip-back duration.
    case skipBack
    /// Skip forward by the user's configured skip-forward duration.
    case skipForward
    /// Go to the previous episode / restart current episode.
    case previousEpisode
    /// Skip to the next episode in the queue.
    case nextEpisode
    
    /// Human-readable label for the settings picker.
    var displayName: String {
        switch self {
        case .skipBack: return "Skip Back"
        case .skipForward: return "Skip Forward"
        case .previousEpisode: return "Restart Episode"
        case .nextEpisode: return "Next Episode"
        }
    }
}

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

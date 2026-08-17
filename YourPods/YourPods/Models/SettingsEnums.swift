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

/// Controls the Liquid Glass visual style on iOS 26+.
/// On iOS 17–25 this setting has no visible effect (classic materials are always used).
enum GlassAppearance: String, Codable, CaseIterable {
    /// Use the pre-iOS-26 solid/material style.
    case classic
    /// Clear glass (maximum transparency).
    case clear
    /// Standard glass (default iOS 26 appearance).
    case regular
    /// High-contrast glass (more opaque, better legibility).
    case highContrast

    /// Returned a plain `String`, so these four picker rows showed English in
    /// every language — while the footer directly beneath them, which names
    /// them, was translated. The raw values stay English: they are persisted
    /// and synced.
    var displayName: String {
        switch self {
        case .classic:
            String(localized: "settings.glass.classic", defaultValue: "Classic",
                   comment: "Glass Style picker row: the opaque pre-iOS-26 look, no translucency. Sits beside Glass, Clear Glass and High Contrast Glass; keep all four short and visibly a set.")
        case .clear:
            String(localized: "settings.glass.clear", defaultValue: "Clear Glass",
                   comment: "Glass Style picker row: maximum transparency, more of the background shows through. 'Glass' here is Apple's Liquid Glass material — use Apple's own word for it in your language if there is one. Sits beside Classic, Glass and High Contrast Glass.")
        case .regular:
            String(localized: "settings.glass.regular", defaultValue: "Glass",
                   comment: "Glass Style picker row: the default iOS 26 translucency. 'Glass' is Apple's Liquid Glass material — use Apple's own word for it in your language if there is one. Sits beside Classic, Clear Glass and High Contrast Glass.")
        case .highContrast:
            String(localized: "settings.glass.highContrast", defaultValue: "High Contrast Glass",
                   comment: "Glass Style picker row: brighter, more opaque glass for legibility. Longest of the four rows, so it sets the column width — shorter is better. Sits beside Classic, Glass and Clear Glass.")
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

    /// Wire value shared with web's `queueRemoval` vocabulary
    /// (`remove` / `removeAndMark` / `ask`).
    var serverValue: String {
        switch self {
        case .removeOnly:          return "remove"
        case .removeAndMarkPlayed: return "removeAndMark"
        case .ask:                 return "ask"
        }
    }

    /// Map the web `queueRemoval` wire value back to the iOS action. Returns nil for
    /// an unknown/forward-compat value (caller keeps the local value).
    static func fromServerValue(_ raw: String) -> QueueRemovalAction? {
        switch raw {
        case "remove":        return .removeOnly
        case "removeAndMark": return .removeAndMarkPlayed
        case "ask":           return .ask
        default:              return nil
        }
    }
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
    ///
    /// Returned a plain `String`, so these four rows showed English while the
    /// very same words, used as buttons elsewhere in the app, were translated.
    /// The English keys are reused deliberately — they already exist in the
    /// catalog with comments, and the strings genuinely are the same words.
    var displayName: String {
        switch self {
        case .skipBack: String(localized: "Skip Back")
        case .skipForward: String(localized: "Skip Forward")
        case .previousEpisode: String(localized: "Restart Episode")
        case .nextEpisode: String(localized: "Next Episode")
        }
    }
}

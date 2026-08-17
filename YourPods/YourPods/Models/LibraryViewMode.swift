import Foundation

/// Which lens the Library presents. Podcasts (the classic list) is the default;
/// Episodes is a flat, filterable cross-show list. Persisted by SettingsManager.
enum LibraryLens: String, CaseIterable {
    case podcasts
    case episodes
}

/// How the Episode lens arranges its flat list. Persisted by SettingsManager.
enum EpisodeArrangement: String, CaseIterable {
    case newest   // one flat list, pubDate descending
    case byDate   // Today / This Week / Earlier sections
    case byShow   // one section per podcast

    var displayName: String {
        switch self {
        case .newest: return "Newest First"
        case .byDate: return "By Date"
        case .byShow: return "By Show"
        }
    }
}

/// A user-assignable episode swipe action. Maps onto the existing `EpisodeMenuAction`
/// so swipes and the row "…" menu share one action pipeline.
enum EpisodeSwipeAction: String, CaseIterable {
    case addToQueue
    case playNext
    case markPlayed
    case hide
    case playNow

    /// The menu action this swipe triggers. `markPlayed`/`hide` toggle based on the
    /// episode's current state inside each call site's handler (unchanged semantics).
    var menuAction: EpisodeMenuAction {
        switch self {
        case .addToQueue: return .addToQueue
        case .playNext:   return .playNext
        case .markPlayed: return .markPlayed
        case .hide:       return .hide
        case .playNow:    return .play
        }
    }

    var displayName: String {
        switch self {
        case .addToQueue: return "Add to Queue"
        case .playNext:   return "Play Next"
        case .markPlayed: return "Mark as Played"
        case .hide:       return "Hide"
        case .playNow:    return "Play Now"
        }
    }

    var systemImage: String {
        switch self {
        case .addToQueue: return "text.append"
        case .playNext:   return "text.insert"
        case .markPlayed: return "checkmark.circle"
        case .hide:       return "eye.slash"
        case .playNow:    return "play.fill"
        }
    }
}

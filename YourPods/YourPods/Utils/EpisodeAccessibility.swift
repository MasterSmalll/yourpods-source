import Foundation

// MARK: - Episode Accessibility Helper

/// Pure-logic helper that computes VoiceOver labels, hints, and custom action names
/// for episode items across the app. Extracted from view code for testability.
enum EpisodeAccessibility {
    
    // MARK: - Episode Row (PodcastDetailView)
    
    /// Builds a descriptive VoiceOver label for an episode row.
    /// Includes: title, podcast name, pub date, duration/remaining, played/playing/downloaded status.
    static func episodeLabel(
        title: String,
        podcastTitle: String?,
        pubDate: Date?,
        durationSeconds: Int?,
        listenedSeconds: Int,
        isPlayed: Bool,
        isPlaying: Bool,
        isDownloaded: Bool,
        isHidden: Bool = false
    ) -> String {
        var parts: [String] = []
        
        // Title is always first
        parts.append(title)
        
        // Podcast name
        if let podcastTitle, !podcastTitle.isEmpty {
            parts.append(podcastTitle)
        }
        
        // State indicators (most important first)
        if isPlaying {
            parts.append("Currently playing")
        } else if isHidden {
            parts.append("Hidden")
        } else if isPlayed {
            parts.append("Played")
        }
        
        // Duration or remaining time
        if let durationSeconds {
            if listenedSeconds > 0 && !isPlayed {
                let remaining = max(0, durationSeconds - listenedSeconds)
                parts.append("\(spokenDuration(remaining)) remaining")
            } else if !isPlayed {
                parts.append(spokenDuration(durationSeconds))
            }
        }
        
        // Downloaded state
        if isDownloaded {
            parts.append("Downloaded")
        }
        
        return parts.joined(separator: ", ")
    }
    
    /// Returns the VoiceOver hint for an episode row.
    static func episodeHint() -> String {
        "Double tap to show episode details"
    }
    
    /// Returns the list of custom rotor action names for an episode row.
    /// These map to VoiceOver's "Actions" rotor — flick up/down to browse, double-tap to activate.
    static func episodeActionNames(isPlaying: Bool, isPlayed: Bool, isDownloaded: Bool, isHidden: Bool = false) -> [String] {
        var actions: [String] = []
        actions.append("Play")
        actions.append("Play Next")
        actions.append("Add to Queue")
        actions.append(isDownloaded ? "Remove Download" : "Download")
        actions.append(isPlayed ? "Mark as Unplayed" : "Mark as Played")
        actions.append(isHidden ? "Unhide" : "Hide")
        return actions
    }
    
    // MARK: - Queue Item Row (QueueView)
    
    /// Builds a descriptive VoiceOver label for a queue item row.
    static func queueItemLabel(
        title: String,
        podcastTitle: String,
        durationSeconds: Int?,
        positionSeconds: Int,
        isNowPlaying: Bool,
        progress: Double
    ) -> String {
        var parts: [String] = []
        
        parts.append(title)
        parts.append(podcastTitle)
        
        if isNowPlaying {
            let percent = Int(progress * 100)
            parts.append("Currently playing, \(percent)% listened")
        } else if let durationSeconds, durationSeconds > 0 {
            if positionSeconds > 0 {
                let remaining = max(0, durationSeconds - positionSeconds)
                parts.append("\(spokenDuration(remaining)) remaining")
            } else {
                parts.append(spokenDuration(durationSeconds))
            }
        }
        
        return parts.joined(separator: ", ")
    }
    
    /// Returns the list of custom rotor action names for a queue item row.
    static func queueItemActionNames(isNowPlaying: Bool) -> [String] {
        if isNowPlaying {
            return ["Mark as Played", "Details"]
        } else {
            return ["Play", "Play Next", "Remove from Queue", "Mark as Played"]
        }
    }
    
    // MARK: - Now Playing Bar
    
    /// Builds a VoiceOver label for the now playing bar's title area.
    static func nowPlayingLabel(
        title: String,
        podcastTitle: String,
        isPlaying: Bool
    ) -> String {
        let state = isPlaying ? "Playing" : "Paused"
        return "\(state): \(title), \(podcastTitle)"
    }
    
    // MARK: - Duration Formatting (Spoken)
    
    /// Formats seconds as a spoken-friendly duration string for VoiceOver.
    /// e.g. "45 minutes", "1 hour 23 minutes", "2 minutes 30 seconds"
    static func spokenDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        
        if hours > 0 && minutes > 0 {
            let hourWord = hours == 1 ? "hour" : "hours"
            let minuteWord = minutes == 1 ? "minute" : "minutes"
            return "\(hours) \(hourWord) \(minutes) \(minuteWord)"
        } else if hours > 0 {
            let hourWord = hours == 1 ? "hour" : "hours"
            return "\(hours) \(hourWord)"
        } else if minutes > 0 {
            let minuteWord = minutes == 1 ? "minute" : "minutes"
            return "\(minutes) \(minuteWord)"
        } else {
            let secondWord = secs == 1 ? "second" : "seconds"
            return "\(secs) \(secondWord)"
        }
    }
}

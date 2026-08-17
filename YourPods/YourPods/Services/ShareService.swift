import Foundation

/// Builds share content for episodes, podcasts, and playback positions.
/// Each method returns an array suitable for UIActivityViewController.
struct ShareService {
    
    /// Share an episode link. Prefers `episode.link`, falls back to `audioUrl`.
    static func shareEpisode(title: String, podcastTitle: String, link: String?, audioUrl: String?) -> [Any] {
        let text = "🎧 \(title) — \(podcastTitle)"
        var items: [Any] = [text]
        
        if let urlString = link ?? audioUrl, let url = URL(string: urlString) {
            items.append(url)
        }
        
        return items
    }
    
    /// Share a podcast link. Prefers `website`, falls back to `feedUrl`.
    static func sharePodcast(title: String, website: String?, feedUrl: String) -> [Any] {
        let text = "🎙️ Check out \(title)"
        var items: [Any] = [text]
        
        let urlString = website ?? feedUrl
        if let url = URL(string: urlString) {
            items.append(url)
        }
        
        return items
    }
    
    /// Caption shown above a rich YourPods share link.
    static func richShareText(episodeTitle: String?, podcastTitle: String, startSec: Int?) -> String {
        guard let episodeTitle, !episodeTitle.isEmpty else { return "🎙️ \(podcastTitle)" }
        if let startSec, startSec > 0 {
            return "🎧 \(episodeTitle) at \(PlayerManager.formatTimestamp(TimeInterval(startSec))) — \(podcastTitle)"
        }
        return "🎧 \(episodeTitle) — \(podcastTitle)"
    }

    /// Share current playback position with a formatted timestamp.
    static func sharePosition(
        episodeTitle: String,
        podcastTitle: String,
        position: TimeInterval,
        link: String?,
        audioUrl: String?
    ) -> [Any] {
        let timestamp = PlayerManager.formatTimestamp(position)
        let text = "🎧 I'm at \(timestamp) in \(episodeTitle) — \(podcastTitle)"
        var items: [Any] = [text]
        
        if let urlString = link ?? audioUrl, let url = URL(string: urlString) {
            items.append(url)
        }
        
        return items
    }
}

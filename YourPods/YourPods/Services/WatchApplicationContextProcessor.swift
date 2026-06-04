import Foundation

/// Pure-logic processor for WatchConnectivity application context payloads.
/// Lives in the iOS target for testability. The watch `WatchSessionManager`
/// uses this to process context data both in delegate callbacks and on
/// foreground resume (re-reading `receivedApplicationContext`).
///
/// **Why this exists:** `WCSession.didReceiveApplicationContext` fires once at
/// delivery time. If the app is suspended when context arrives, the data sits
/// in `receivedApplicationContext` but `@Published` properties are never updated.
/// On foreground resume, `WatchSessionManager` must re-read and process the
/// context — this struct provides the testable processing logic.
struct WatchApplicationContextProcessor {

    /// Result of processing an application context dictionary.
    struct Result {
        // Queue
        var hasQueueUpdate: Bool = false
        var queueItems: [QueueItem] = []

        // Playback info
        var hasPlaybackInfoUpdate: Bool = false
        var playbackTitle: String = "Not Playing"
        var playbackArtist: String = ""
        var playbackIsPlaying: Bool = false
        var playbackEpisodeId: String? = nil

        // Speed
        var speed: Double? = nil

        // Position sync interval
        var positionSyncInterval: Int? = nil

        // WiFi-only policy
        var wifiOnly: Bool? = nil
    }

    struct QueueItem {
        let id: String
        let title: String
        let album: String
        let artist: String
        let duration: Int
        let url: String?
        let artUri: String?
        let isAvailableOnPhone: Bool
        let position: Int
        let chapters: [[String: Any]]?
        let autoDownload: Bool
    }

    /// Process a WatchConnectivity application context dictionary.
    /// Extracts queue, playback info, speed, and settings.
    ///
    /// This is a pure function — no side effects, no @Published mutations.
    /// The caller applies the result to its own state.
    func processApplicationContext(_ context: [String: Any]) -> Result {
        var result = Result()

        // Queue
        if let queue = context["queue"] as? [[String: Any]] {
            result.hasQueueUpdate = true
            result.queueItems = queue.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return QueueItem(
                    id: id,
                    title: item["title"] as? String ?? "Unknown",
                    album: item["album"] as? String ?? "",
                    artist: item["artist"] as? String ?? "",
                    duration: item["duration"] as? Int ?? 0,
                    url: item["url"] as? String,
                    artUri: item["artUri"] as? String,
                    isAvailableOnPhone: item["isAvailableOnPhone"] as? Bool ?? false,
                    position: item["position"] as? Int ?? 0,
                    chapters: item["chapters"] as? [[String: Any]],
                    autoDownload: item["autoDownload"] as? Bool ?? false
                )
            }
        }

        // Playback info
        if let info = context["playback_info"] as? [String: Any] {
            result.hasPlaybackInfoUpdate = true
            result.playbackTitle = info["title"] as? String ?? "Not Playing"
            result.playbackArtist = info["artist"] as? String ?? ""
            result.playbackIsPlaying = info["isPlaying"] as? Bool ?? false
            result.playbackEpisodeId = info["episodeId"] as? String
        }

        // Speed
        if let speed = context["speed"] as? Double {
            result.speed = speed
        }

        // Position sync interval
        if let interval = context["positionSyncInterval"] as? Int {
            result.positionSyncInterval = interval
        }

        // WiFi-only
        if let wifiOnly = context["wifiOnly"] as? Bool {
            result.wifiOnly = wifiOnly
        }

        return result
    }
}

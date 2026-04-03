import Foundation

/// Resolves the playback URL for a watch episode, preferring local downloaded
/// files over streaming. Shared logic used by both the watch PlayerView (queue)
/// and ContentView (Now Playing navigation).
///
/// This type lives in the iOS target for testability but mirrors logic that
/// must be applied in the watch app's PlayerView and ContentView.
enum WatchPlaybackResolver {
    
    struct Resolution: Equatable {
        let url: URL
        let source: PlaybackSourceType
        let resumePosition: Int
    }
    
    enum PlaybackSourceType: Equatable {
        case local
        case streaming
        case none
    }
    
    /// Resolves the best playback URL for an episode.
    /// - Parameters:
    ///   - localPath: Relative path to the downloaded file in the documents directory, if any.
    ///   - streamUrl: Remote URL string for streaming, if any.
    ///   - position: Saved playback position in seconds for resumption.
    ///   - documentsDirectory: The documents directory to look for local files in.
    /// - Returns: A `Resolution` with the URL, source type, and resume position, or nil if no source is available.
    static func resolvePlaybackURL(
        localPath: String?,
        streamUrl: String?,
        position: Int,
        documentsDirectory: URL
    ) -> Resolution? {
        // 1. Prefer local file if it exists on disk
        if let localPath = localPath {
            let fileURL = documentsDirectory.appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return Resolution(
                    url: fileURL,
                    source: .local,
                    resumePosition: position
                )
            }
        }
        
        // 2. Fall back to stream URL
        if let streamUrl = streamUrl, let url = URL(string: streamUrl) {
            return Resolution(
                url: url,
                source: .streaming,
                resumePosition: position
            )
        }
        
        // 3. No source available
        return nil
    }
    
    /// Determines whether the watch should play an episode locally (via PlayerView)
    /// rather than remote-controlling the iPhone (via RemotePlayerView).
    /// - Parameters:
    ///   - localPath: Relative path to the downloaded file, if any.
    ///   - streamUrl: Remote URL string for streaming, if any.
    ///   - documentsDirectory: The documents directory to check for local files.
    /// - Returns: `true` if the watch can play this episode locally.
    static func shouldPlayOnWatch(
        localPath: String?,
        streamUrl: String?,
        documentsDirectory: URL
    ) -> Bool {
        // Can play locally if we have a valid local file
        if let localPath = localPath {
            let fileURL = documentsDirectory.appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return true
            }
        }
        // Can stream if we have a stream URL
        if streamUrl != nil {
            return true
        }
        return false
    }
}

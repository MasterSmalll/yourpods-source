import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
import os
import Combine

/// Protocol for WCSession to allow mocking in tests
#if canImport(WatchConnectivity)
protocol WatchSessionProtocol: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var isPaired: Bool { get }
    var isReachable: Bool { get }
    func activate()
    func updateApplicationContext(_ context: [String : Any]) throws
    func sendMessage(_ message: [String : Any], replyHandler: (([String : Any]) -> Void)?, errorHandler: ((Error) -> Void)?)
}
#endif

#if canImport(WatchConnectivity)
extension WCSession: WatchSessionProtocol {}
#endif

/// Native Watch connectivity service.
/// WCSession bridge — uses WCSessionDelegate directly.
final class WatchService: NSObject, ObservableObject {
    static let shared = WatchService()
    
    private let logger = Logger(subsystem: "com.yourpods", category: "WatchService")
    
    // Dependencies
    weak var audioManager: AudioManager?
    weak var playerManager: PlayerManager?
    weak var podcastManager: PodcastManager?
    weak var settingsManager: SettingsManager?
    
    #if canImport(WatchConnectivity)
    var session: WatchSessionProtocol = WCSession.default
    #endif
    
    // Dedup
    private var lastContextJSON: String?
    private var lastLibraryJSON: String?
    
    /// Merged application context
    private var currentContext: [String: Any] = [:]
    
    /// Custom command handler (for queue operations from watch)
    var onCustomCommand: ((String, [String: Any]) -> Void)?
    
    private override init() {
        super.init()
        #if os(iOS)
        activateIfSupported()
        #endif
    }
    
    private func activateIfSupported() {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            logger.info("WatchConnectivity not supported on this device")
            return
        }
        session.delegate = self
        session.activate()
        logger.info("WCSession activated")
        #endif
        #endif
    }
    
    // MARK: - Queue Sync
    
    /// Sync the playback queue to the watch via application context.
    @MainActor
    func syncQueue(autoSyncEnabled: Bool = true, watchSyncCount: Int = 5, watchPositionSyncInterval: Int = 30) {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard autoSyncEnabled else { return }
        // applicationContext doesn't require isReachable — it's delivered
        // when the watch app next launches, even if the screen is off.
        guard session.isPaired else { return }
        
        let upcomingQueue = audioManager?.queue ?? []
        let currentItem = audioManager?.currentItem
        
        // Combine currentItem + upcoming queue for the watch's unified list
        var fullQueue: [QueueItem] = []
        if let currentItem {
            fullQueue.append(currentItem)
        }
        fullQueue.append(contentsOf: upcomingQueue)
        
        let metadataLimit = min(fullQueue.count, 50)
        var contextQueue: [[String: Any]] = []
        
        for i in 0..<metadataLimit {
            let item = fullQueue[i]
            contextQueue.append([
                "id": item.id,
                "title": item.title,
                "album": item.podcastTitle,
                "artist": item.podcastTitle, // Watch expects 'artist' field
                "duration": item.durationSeconds ?? 0,
                "position": item.positionSeconds,
                "url": item.audioUrl,
                "artUri": item.artworkUrl ?? "",
                "autoDownload": i < watchSyncCount,
                "isAvailableOnPhone": true, // Items in queue are on phone by definition
            ])
        }
        
        currentContext["queue"] = contextQueue
        currentContext["speed"] = audioManager?.playbackRate ?? 1.0
        currentContext["positionSyncInterval"] = watchPositionSyncInterval
        
        // Push Watch download network policy from user setting
        currentContext["wifiOnly"] = settingsManager?.watchDownloadWiFiOnly ?? true
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: currentContext)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""
            
            guard jsonStr != lastContextJSON else {
                logger.debug("Skipping sync (context unchanged)")
                return
            }
            
            try session.updateApplicationContext(currentContext)
            lastContextJSON = jsonStr
            logger.info("Application context updated (\(contextQueue.count) items including current)")
            
            // If reachable, also send as message for immediate UI update
            if session.isReachable {
                session.sendMessage(["queue": contextQueue, "speed": currentContext["speed"] as Any], replyHandler: nil, errorHandler: nil)
            }
        } catch {
            if error.localizedDescription.contains("not installed") {
                logger.debug("Sync skipped (Watch app not installed)")
            } else {
                logger.error("Sync failed: \(error.localizedDescription)")
            }
        }
        #endif
        #endif
    }
    
    // MARK: - Playback State Sync
    
    @MainActor
    func updatePlaybackState() {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard session.isPaired else { return }
        
        currentContext["playback_info"] = [
            "title": audioManager?.currentItem?.title ?? "Not Playing",
            "artist": audioManager?.currentItem?.podcastTitle ?? "",
            "isPlaying": audioManager?.isPlaying ?? false,
            "episodeId": audioManager?.currentItem?.id ?? "",
        ] as [String: Any]
        
        do {
            try session.updateApplicationContext(currentContext)
        } catch {
            if !error.localizedDescription.contains("not installed") {
                logger.error("Failed to update playback state: \(error.localizedDescription)")
            }
        }
        #endif
        #endif
    }
    
    // MARK: - Library Sync
    
    @MainActor
    func syncLibrary() {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard session.isPaired, session.isReachable else { return }
        guard let subscriptions = podcastManager?.subscriptions else { return }
        
        let libraryData: [[String: Any]] = subscriptions.map { podcast in
            [
                "title": podcast.title,
                "feedUrl": podcast.url,
                "artUri": podcast.logoUrl ?? "",
                "author": podcast.author ?? "",
            ]
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: libraryData),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        
        guard jsonStr != lastLibraryJSON else {
            logger.debug("Skipping library sync (unchanged)")
            return
        }
        
        session.sendMessage(["library": libraryData], replyHandler: nil) { error in
            if error.localizedDescription.contains("not installed") {
                self.logger.debug("Library sync skipped (Watch app not installed)")
            } else {
                self.logger.error("Library sync failed: \(error.localizedDescription)")
            }
        }
        lastLibraryJSON = jsonStr
        logger.info("Library synced: \(libraryData.count) podcasts")
        
        // Proactively send recently updated episodes alongside library
        sendRecentEpisodes()
        #endif
        #endif
    }
    
    // MARK: - Send Episodes
    
    func sendEpisodes(feedUrl: String, episodes: [[String: Any]]) {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard session.isPaired, session.isReachable else { return }
        
        session.sendMessage([
            "episodes_for_feed": [
                "feedUrl": feedUrl,
                "episodes": episodes,
            ]
        ], replyHandler: nil) { error in
            self.logger.error("Failed to send episodes to watch: \(error.localizedDescription)")
        }
        logger.info("Sent \(episodes.count) episodes for \(feedUrl) to watch")
        #endif
        #endif
    }
    
    // MARK: - Recently Updated Episodes
    
    /// Send the 10 most recent unplayed episodes across all subscriptions to the watch.
    @MainActor
    func sendRecentEpisodes() {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard session.isPaired, session.isReachable else { return }
        guard let subscriptions = podcastManager?.subscriptions else { return }
        
        let dateFormatter = ISO8601DateFormatter()
        
        // Filter episodes using the shared 2-month recency cutoff
        let filtered = RecentlyUpdatedFilter.filter(
            episodes: subscriptions.flatMap { $0.episodes },
            limit: 10
        )
        
        let recentEpisodes: [[String: Any]] = filtered.map { episode in
            let podcast = episode.podcast
            return [
                "id": episode.guid,
                "title": episode.title,
                "duration": episode.durationSeconds ?? 0,
                "audioUrl": episode.audioUrl ?? "",
                "imageUrl": episode.imageUrl ?? podcast?.logoUrl ?? "",
                "podcastTitle": podcast?.title ?? "",
                "podcastArtUri": podcast?.logoUrl ?? "",
                "pubDate": episode.pubDate.map { dateFormatter.string(from: $0) } ?? "",
            ] as [String: Any]
        }
        
        session.sendMessage(["recent_episodes": recentEpisodes], replyHandler: nil) { error in
            self.logger.error("Failed to send recent episodes to watch: \(error.localizedDescription)")
        }
        logger.info("Sent \(recentEpisodes.count) recent episodes to watch")
        #endif
        #endif
    }
}

// MARK: - WCSessionDelegate

#if os(iOS)
#if canImport(WatchConnectivity)
extension WatchService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            logger.error("WCSession activation failed: \(error.localizedDescription)")
        } else {
            logger.info("WCSession activated: \(activationState.rawValue)")
            // Perform initial queue sync on activation
            DispatchQueue.main.async {
                self.syncQueue()
                self.updatePlaybackState()
            }
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        logger.info("WCSession became inactive")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        logger.info("WCSession deactivated — reactivating")
        session.activate()
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleMessage(message)
        replyHandler(["status": "ok"])
    }
    
    private func handleMessage(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        logger.info("Received command from watch: \(command)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            switch command {
            case "play":
                self.audioManager?.play()
                
            case "pause":
                self.audioManager?.pause()
                
            case "skipForward":
                self.audioManager?.seekRelative(seconds: Double(self.settingsManager?.skipForwardSeconds ?? 30))
                
            case "skipBackward":
                self.audioManager?.seekRelative(seconds: -Double(self.settingsManager?.skipBackwardSeconds ?? 15))
                
            case "remove_from_queue":
                if let episodeId = message["episodeId"] as? String {
                    self.onCustomCommand?("remove_from_queue", ["episodeId": episodeId])
                }
                
            case "mark_as_played":
                if let episodeId = message["episodeId"] as? String {
                    self.onCustomCommand?("mark_as_played", ["episodeId": episodeId])
                }
                
            case "refresh_queue":
                self.onCustomCommand?("refresh_queue", [:])
                
            case "playQueue":
                self.audioManager?.play()
                
            case "playLatest":
                if let podcastName = message["podcastName"] as? String {
                    self.onCustomCommand?("playLatest", ["podcastName": podcastName])
                }
                
            case "update_progress":
                if let episodeId = message["episodeId"] as? String,
                   let position = message["position"] as? Int {
                    self.onCustomCommand?("update_progress", [
                        "episodeId": episodeId,
                        "position": position,
                    ])
                }
                
            case "request_library":
                self.onCustomCommand?("request_library", [:])
                
            case "request_episodes":
                if let feedUrl = message["feedUrl"] as? String {
                    self.onCustomCommand?("request_episodes", ["feedUrl": feedUrl])
                }
                
            case "request_recent_episodes":
                self.onCustomCommand?("request_recent_episodes", [:])
                
            default:
                self.logger.warning("Unknown watch command: \(command)")
            }
        }
    }
}
#endif
#endif

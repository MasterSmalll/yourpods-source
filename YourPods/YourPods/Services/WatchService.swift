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

/// Native Watch connectivity service using WCSessionDelegate.
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
    /// Position-blind fingerprint of the last pushed context (see `stableContextFingerprint`).
    private var lastStableFingerprint: String?
    /// Wall-clock time of the last actual `updateApplicationContext` push.
    private var lastContextPushAt: Date = .distantPast
    /// JSON of the last pushed `playback_info` block, to dedupe `updatePlaybackState()`.
    private var lastPlaybackInfoJSON: String?
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

    /// Assemble the watch queue payload (currentItem + upcoming, capped at 50).
    @MainActor
    func buildQueuePayload(watchSyncCount: Int = 5) -> [[String: Any]] {
        let upcomingQueue = audioManager?.queue ?? []
        let currentItem = audioManager?.currentItem

        var fullQueue: [QueueItem] = []
        if let currentItem { fullQueue.append(currentItem) }
        fullQueue.append(contentsOf: upcomingQueue)

        let metadataLimit = min(fullQueue.count, 50)
        return (0..<metadataLimit).map { i in
            let item = fullQueue[i]
            return WatchWireFormat.encodeQueueItem(.init(
                id: item.id,
                title: item.title,
                album: item.podcastTitle,
                artist: item.podcastTitle,
                duration: item.durationSeconds ?? 0,
                position: item.positionSeconds,
                url: item.audioUrl,
                artUri: item.artworkUrl,
                autoDownload: i < watchSyncCount,
                isAvailableOnPhone: true,
                chapters: nil))
        }
    }

    /// Reply payload for the watch's refresh_queue round-trip.
    @MainActor
    func refreshQueueReply() -> [String: Any] {
        let limit = settingsManager?.watchSyncPodcastLimit ?? 5
        return ["status": "ok", "queue": buildQueuePayload(watchSyncCount: limit)]
    }

    /// Sync using the user's actual settings. All internal triggers
    /// (activation, refresh_queue) must use this, never bare syncQueue().
    @MainActor
    func syncQueueWithSettings() {
        syncQueue(
            autoSyncEnabled: settingsManager?.watchSyncEnabled ?? true,
            watchSyncCount: settingsManager?.watchSyncPodcastLimit ?? 5,
            watchPositionSyncInterval: settingsManager?.watchPositionSyncInterval ?? 30
        )
    }

    /// Sync the playback queue to the watch via application context.
    @MainActor
    func syncQueue(autoSyncEnabled: Bool = true, watchSyncCount: Int = 5, watchPositionSyncInterval: Int = 30) {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard autoSyncEnabled else {
            logger.debug("Sync skipped (watch sync disabled in settings)")
            return
        }
        // applicationContext doesn't require isReachable — it's delivered
        // when the watch app next launches, even if the screen is off.
        guard session.isPaired else {
            logger.debug("syncQueue dropped — watch not paired")
            return
        }
        
        let contextQueue = buildQueuePayload(watchSyncCount: watchSyncCount)

        currentContext["queue"] = contextQueue
        currentContext["speed"] = audioManager?.playbackRate ?? 1.0
        currentContext["positionSyncInterval"] = watchPositionSyncInterval
        
        // Push Watch download network policy from user setting
        currentContext["wifiOnly"] = settingsManager?.watchDownloadWiFiOnly ?? true

        // Skip-interval parity — stable metadata (not per-tick position), so it
        // MUST participate in the fingerprint below: adding/changing these should
        // trigger a push, unlike the position fields the fingerprint strips.
        currentContext["skipForwardSeconds"] = settingsManager?.skipForwardSeconds ?? 30
        currentContext["skipBackwardSeconds"] = settingsManager?.skipBackwardSeconds ?? 15

        // Fingerprint that IGNORES per-item positions: position ticks every ~5s
        // during playback and previously forced a full context push each time.
        let stableFingerprint = Self.stableContextFingerprint(of: currentContext)
        let positionInterval = TimeInterval(watchPositionSyncInterval)
        let positionOnlyChange = (stableFingerprint == lastStableFingerprint)

        if positionOnlyChange, Date().timeIntervalSince(lastContextPushAt) < positionInterval {
            logger.debug("Skipping context push (position-only change within \(Int(positionInterval))s)")
            return
        }

        do {
            try session.updateApplicationContext(currentContext)
            lastStableFingerprint = stableFingerprint
            lastContextPushAt = Date()
            logger.info("Application context updated (\(contextQueue.count) items including current)")
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

    /// Deterministic serialization of the context with volatile position
    /// fields zeroed, so position ticks don't count as changes.
    private static func stableContextFingerprint(of context: [String: Any]) -> String {
        var stripped = context
        if let queue = context["queue"] as? [[String: Any]] {
            stripped["queue"] = queue.map { item -> [String: Any] in
                var copy = item
                copy["position"] = 0
                return copy
            }
        }
        guard JSONSerialization.isValidJSONObject(stripped),
              let data = try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys]) else {
            return UUID().uuidString  // un-serializable → treat as changed
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Playback State Sync
    
    @MainActor
    func updatePlaybackState() {
        #if os(iOS)
        #if canImport(WatchConnectivity)
        guard session.isPaired else {
            logger.debug("updatePlaybackState dropped — watch not paired")
            return
        }

        let info: [String: Any] = [
            "title": audioManager?.currentItem?.title ?? "Not Playing",
            "artist": audioManager?.currentItem?.podcastTitle ?? "",
            "isPlaying": audioManager?.isPlaying ?? false,
            "episodeId": audioManager?.currentItem?.id ?? "",
        ]
        // playback_info is tiny but updateApplicationContext resends the WHOLE
        // merged context (queue included) — only push when it actually changed.
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else {
            logger.error("Failed to serialize playback info; skipping push")
            return
        }
        let json = String(decoding: data, as: UTF8.self)
        guard json != lastPlaybackInfoJSON else {
            logger.debug("Skipping playback state push (unchanged)")
            return
        }
        lastPlaybackInfoJSON = json

        currentContext["playback_info"] = info
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
        guard session.isPaired, session.isReachable else {
            logger.debug("syncLibrary dropped — watch unreachable (isPaired: \(self.session.isPaired), isReachable: \(self.session.isReachable))")
            return
        }
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
        guard session.isPaired, session.isReachable else {
            // Firing guard — the watch's request_episodes and this reply can
            // race an asymmetric reachability window (reachable when the watch
            // asked, unreachable by the time iOS replies), silently dropping
            // episodes the watch is still waiting on. Not redesigned here: the
            // watch already recovers via its own request timeout → failed state
            // → retry.
            logger.debug("sendEpisodes(\(feedUrl)) dropped — watch unreachable (isPaired: \(self.session.isPaired), isReachable: \(self.session.isReachable))")
            return
        }

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
        guard session.isPaired, session.isReachable else {
            // Same asymmetric-reachability drop as sendEpisodes — log so a
            // silently-dropped "Recently Updated" push is diagnosable.
            logger.debug("sendRecentEpisodes dropped — watch unreachable (isPaired: \(self.session.isPaired), isReachable: \(self.session.isReachable))")
            return
        }
        guard let subscriptions = podcastManager?.subscriptions else { return }
        
        let dateFormatter = ISO8601DateFormatter()
        
        // Filter episodes using the shared 2-month recency cutoff
        let filtered = RecentlyUpdatedFilter.filter(
            episodes: subscriptions.flatMap { $0.episodes },
            limit: 10
        ).episodes
        
        let recentEpisodes: [[String: Any]] = filtered.map { episode in
            let podcast = episode.podcast
            var dict = WatchWireFormat.encodeEpisodeListItem(.init(
                guid: episode.guid,
                title: episode.title,
                duration: episode.durationSeconds ?? 0,
                audioUrl: episode.audioUrl,
                imageUrl: episode.imageUrl ?? podcast?.logoUrl))
            dict["podcastTitle"] = podcast?.title ?? ""
            dict["podcastArtUri"] = podcast?.logoUrl ?? ""
            dict["pubDate"] = episode.pubDate.map { dateFormatter.string(from: $0) } ?? ""
            return dict
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
                self.syncQueueWithSettings()
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
        if message["command"] as? String == "refresh_queue" {
            Task { @MainActor [weak self] in
                guard let self else {
                    // self is gone, so the instance logger is unreachable — log inline.
                    Logger(subsystem: "com.yourpods", category: "WatchService")
                        .warning("WatchService deallocated during refresh_queue reply; sending gone")
                    replyHandler(["status": "gone"])
                    return
                }
                replyHandler(self.refreshQueueReply())
                self.handleMessage(message)  // still refresh the durable applicationContext
            }
        } else {
            handleMessage(message)
            replyHandler(["status": "ok"])
        }
    }

    /// Durable delivery path: progress sent via `transferUserInfo` arrives here even when the app was
    /// backgrounded/unreachable when the watch sent it. Routes through the same handler as live messages.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleMessage(userInfo)
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

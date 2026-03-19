import Foundation
import os
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Service that manages iOS Live Activities / Dynamic Island for podcast playback.
///
/// Uses shared UserDefaults via App Group to pass data to the widget extension.
/// Button taps on the Dynamic Island are received via URL scheme (yourpods://action/...)
/// and forwarded to a callback so PlayerManager can route them to play/pause/skip.
///
/// Port of live_activity_service.dart — identical data model and URL scheme.
final class LiveActivityService {
    static let shared = LiveActivityService()
    
    private let logger = Logger(subsystem: "com.yourpods", category: "LiveActivity")
    
    static let appGroupId = "group.com.asecretcompany.yourpods"
    static let urlScheme = "yourpods"
    
    private var currentActivityId: String?
    private var initialized = false
    
    /// Callback invoked when a button on the Dynamic Island is tapped.
    /// The action will be one of: "togglePlay", "skipForward", "skipBackward"
    var onAction: ((String) -> Void)?
    
    private let sharedDefaults: UserDefaults?
    
    private init() {
        sharedDefaults = UserDefaults(suiteName: Self.appGroupId)
    }
    
    // MARK: - Init
    
    func initialize() {
        #if os(iOS)
        guard !initialized else { return }
        initialized = true
        logger.info("LiveActivityService initialized")
        #endif
    }
    
    // MARK: - URL Scheme Handling
    
    /// Call from SceneDelegate/AppDelegate when receiving a yourpods:// URL
    func handleURL(_ url: URL) {
        guard url.scheme == Self.urlScheme,
              url.host == "action" else { return }
        
        // Remove leading slash from path
        let path = url.path
        let action = path.hasPrefix("/") ? String(path.dropFirst()) : path
        
        guard !action.isEmpty else { return }
        
        logger.info("Live Activity action: \(action)")
        onAction?(action)
    }
    
    // MARK: - Activity Lifecycle
    
    @available(iOS 16.2, *)
    func startActivity(
        episodeTitle: String,
        podcastName: String,
        artUrl: String?,
        isPlaying: Bool,
        positionSeconds: Int,
        durationSeconds: Int
    ) {
        #if os(iOS)
        guard initialized else { return }
        
        // If already active, update instead
        if currentActivityId != nil {
            updateActivity(
                episodeTitle: episodeTitle,
                podcastName: podcastName,
                artUrl: artUrl,
                isPlaying: isPlaying,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds
            )
            return
        }
        
        let attributes = LiveActivitiesAppAttributes()
        let contentState = LiveActivitiesAppAttributes.ContentState()
        
        // Write data to shared UserDefaults (widget reads from here)
        writeToSharedDefaults(
            activityId: attributes.id,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            artUrl: artUrl,
            isPlaying: isPlaying,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds
        )
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: contentState, staleDate: nil),
                pushType: nil
            )
            currentActivityId = activity.id
            logger.info("Created activity \(activity.id)")
        } catch {
            logger.error("Error creating activity: \(error.localizedDescription)")
        }
        #endif
    }
    
    @available(iOS 16.2, *)
    func updateActivity(
        episodeTitle: String,
        podcastName: String,
        artUrl: String?,
        isPlaying: Bool,
        positionSeconds: Int,
        durationSeconds: Int
    ) {
        #if os(iOS)
        guard initialized else { return }
        
        if currentActivityId == nil {
            startActivity(
                episodeTitle: episodeTitle,
                podcastName: podcastName,
                artUrl: artUrl,
                isPlaying: isPlaying,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds
            )
            return
        }
        
        // Find the running activity and update shared UserDefaults
        for activity in Activity<LiveActivitiesAppAttributes>.activities {
            if activity.id == currentActivityId {
                writeToSharedDefaults(
                    activityId: activity.attributes.id,
                    episodeTitle: episodeTitle,
                    podcastName: podcastName,
                    artUrl: artUrl,
                    isPlaying: isPlaying,
                    positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds
                )
                
                Task {
                    let contentState = LiveActivitiesAppAttributes.ContentState()
                    await activity.update(.init(state: contentState, staleDate: nil))
                }
                break
            }
        }
        #endif
    }
    
    @available(iOS 16.2, *)
    func endActivity() {
        #if os(iOS)
        guard initialized, let activityId = currentActivityId else { return }
        
        for activity in Activity<LiveActivitiesAppAttributes>.activities {
            if activity.id == activityId {
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    logger.info("Ended activity \(activityId)")
                }
                break
            }
        }
        currentActivityId = nil
        #endif
    }
    
    // MARK: - Shared UserDefaults (Widget reads from here)
    
    private func writeToSharedDefaults(
        activityId: UUID,
        episodeTitle: String,
        podcastName: String,
        artUrl: String?,
        isPlaying: Bool,
        positionSeconds: Int,
        durationSeconds: Int
    ) {
        let prefix = "\(activityId)_"
        let progressFraction = durationSeconds > 0 ? Double(positionSeconds) / Double(durationSeconds) : 0.0
        
        sharedDefaults?.set(episodeTitle, forKey: "\(prefix)episodeTitle")
        sharedDefaults?.set(podcastName, forKey: "\(prefix)podcastName")
        sharedDefaults?.set(isPlaying, forKey: "\(prefix)isPlaying")
        sharedDefaults?.set(positionSeconds, forKey: "\(prefix)positionSeconds")
        sharedDefaults?.set(durationSeconds, forKey: "\(prefix)durationSeconds")
        sharedDefaults?.set(progressFraction, forKey: "\(prefix)progressFraction")
        
        if let artUrl, !artUrl.isEmpty {
            // Download artwork to shared container for widget access
            downloadArtwork(url: artUrl, key: "\(prefix)artUri")
        }
    }
    
    /// Download artwork and save to shared App Group container.
    private func downloadArtwork(url: String, key: String) {
        guard let artURL = URL(string: url) else { return }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: artURL)
                
                // Save to shared container
                if let containerURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: Self.appGroupId
                ) {
                    let imageFile = containerURL.appendingPathComponent("live_activity_art.jpg")
                    try data.write(to: imageFile)
                    sharedDefaults?.set(imageFile.path, forKey: key)
                }
            } catch {
                logger.error("Failed to download artwork: \(error.localizedDescription)")
            }
        }
    }
    
    func dispose() {
        if #available(iOS 16.2, *) {
            endActivity()
        }
    }
}

// MARK: - LiveActivitiesAppAttributes (shared with widget extension)
// When building as SPM/main app, this provides the type.
// The widget extension has its own copy.

#if os(iOS)
import ActivityKit

struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
    public typealias LiveDeliveryData = ContentState
    
    public struct ContentState: Codable, Hashable { }
    
    var id = UUID()
}
#endif

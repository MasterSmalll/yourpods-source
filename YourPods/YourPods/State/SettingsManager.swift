import Foundation
import os

/// Global app settings. Port of settings_provider.dart.
///
/// All properties are computed (backed by UserDefaults), so we use manual
/// `access(keyPath:)` / `withMutation(keyPath:)` calls to make `@Observable`
/// track them correctly. Without this, SwiftUI Pickers and Toggles revert
/// immediately because the observation framework never sees the mutations.
@Observable
final class SettingsManager {
    @ObservationIgnored private let logger = Logger(subsystem: "com.yourpods", category: "SettingsManager")
    @ObservationIgnored private let defaults = UserDefaults.standard
    
    // MARK: - Playback Settings
    
    var playbackSpeed: Double {
        get {
            access(keyPath: \.playbackSpeed)
            return defaults.double(forKey: "playbackSpeed").nonZero ?? 1.0
        }
        set {
            withMutation(keyPath: \.playbackSpeed) {
                defaults.set(newValue, forKey: "playbackSpeed")
            }
        }
    }
    
    var skipIntroSeconds: Int {
        get {
            access(keyPath: \.skipIntroSeconds)
            return defaults.integer(forKey: "skipIntroSeconds")
        }
        set {
            withMutation(keyPath: \.skipIntroSeconds) {
                defaults.set(newValue, forKey: "skipIntroSeconds")
            }
        }
    }
    
    var skipOutroSeconds: Int {
        get {
            access(keyPath: \.skipOutroSeconds)
            return defaults.integer(forKey: "skipOutroSeconds")
        }
        set {
            withMutation(keyPath: \.skipOutroSeconds) {
                defaults.set(newValue, forKey: "skipOutroSeconds")
            }
        }
    }
    
    var skipForwardSeconds: Int {
        get {
            access(keyPath: \.skipForwardSeconds)
            return defaults.object(forKey: "skipForwardSeconds") as? Int ?? 30
        }
        set {
            withMutation(keyPath: \.skipForwardSeconds) {
                defaults.set(newValue, forKey: "skipForwardSeconds")
            }
        }
    }
    
    var skipBackwardSeconds: Int {
        get {
            access(keyPath: \.skipBackwardSeconds)
            return defaults.object(forKey: "skipBackwardSeconds") as? Int ?? 15
        }
        set {
            withMutation(keyPath: \.skipBackwardSeconds) {
                defaults.set(newValue, forKey: "skipBackwardSeconds")
            }
        }
    }
    
    // MARK: - Headphone / Remote Command Actions
    
    var nextTrackAction: RemoteCommandAction {
        get {
            access(keyPath: \.nextTrackAction)
            guard let raw = defaults.string(forKey: "nextTrackAction"),
                  let action = RemoteCommandAction(rawValue: raw) else { return .nextEpisode }
            return action
        }
        set {
            withMutation(keyPath: \.nextTrackAction) {
                defaults.set(newValue.rawValue, forKey: "nextTrackAction")
            }
        }
    }
    
    var previousTrackAction: RemoteCommandAction {
        get {
            access(keyPath: \.previousTrackAction)
            guard let raw = defaults.string(forKey: "previousTrackAction"),
                  let action = RemoteCommandAction(rawValue: raw) else { return .skipBack }
            return action
        }
        set {
            withMutation(keyPath: \.previousTrackAction) {
                defaults.set(newValue.rawValue, forKey: "previousTrackAction")
            }
        }
    }
    
    // MARK: - Sync Settings
    
    var syncInterval: Int {
        get {
            access(keyPath: \.syncInterval)
            return defaults.object(forKey: "syncInterval") as? Int ?? 30
        }
        set {
            withMutation(keyPath: \.syncInterval) {
                defaults.set(newValue, forKey: "syncInterval")
            }
        }
    }
    
    var syncConflictStrategy: SyncStrategy {
        get {
            access(keyPath: \.syncConflictStrategy)
            guard let raw = defaults.string(forKey: "syncConflictStrategy"),
                  let strategy = SyncStrategy(rawValue: raw) else { return .ask }
            return strategy
        }
        set {
            withMutation(keyPath: \.syncConflictStrategy) {
                defaults.set(newValue.rawValue, forKey: "syncConflictStrategy")
            }
        }
    }
    
    var queueSyncStrategy: QueueSyncStrategy {
        get {
            access(keyPath: \.queueSyncStrategy)
            guard let raw = defaults.string(forKey: "queueSyncStrategy"),
                  let strategy = QueueSyncStrategy(rawValue: raw) else { return .ask }
            return strategy
        }
        set {
            withMutation(keyPath: \.queueSyncStrategy) {
                defaults.set(newValue.rawValue, forKey: "queueSyncStrategy")
            }
        }
    }
    
    // MARK: - Display Settings
    
    var appearance: AppAppearance {
        get {
            access(keyPath: \.appearance)
            guard let raw = defaults.string(forKey: "appearance"),
                  let mode = AppAppearance(rawValue: raw) else { return .system }
            return mode
        }
        set {
            withMutation(keyPath: \.appearance) {
                defaults.set(newValue.rawValue, forKey: "appearance")
            }
        }
    }
    
    var showPercentListened: Bool {
        get {
            access(keyPath: \.showPercentListened)
            return defaults.object(forKey: "showPercentListened") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showPercentListened) {
                defaults.set(newValue, forKey: "showPercentListened")
            }
        }
    }
    
    var tabBarDisplayMode: TabBarDisplayMode {
        get {
            access(keyPath: \.tabBarDisplayMode)
            guard let raw = defaults.string(forKey: "tabBarDisplayMode"),
                  let mode = TabBarDisplayMode(rawValue: raw) else { return .textAndIcon }
            return mode
        }
        set {
            withMutation(keyPath: \.tabBarDisplayMode) {
                defaults.set(newValue.rawValue, forKey: "tabBarDisplayMode")
            }
        }
    }
    
    // MARK: - Auto-Queue / Download Defaults
    
    var defaultAutoQueueMode: AutoQueueMode {
        get {
            access(keyPath: \.defaultAutoQueueMode)
            guard let raw = defaults.string(forKey: "defaultAutoQueueMode"),
                  let mode = AutoQueueMode(rawValue: raw) else { return .off }
            return mode
        }
        set {
            withMutation(keyPath: \.defaultAutoQueueMode) {
                defaults.set(newValue.rawValue, forKey: "defaultAutoQueueMode")
            }
        }
    }
    
    var defaultArchiveOnComplete: Bool {
        get {
            access(keyPath: \.defaultArchiveOnComplete)
            return defaults.bool(forKey: "defaultArchiveOnComplete")
        }
        set {
            withMutation(keyPath: \.defaultArchiveOnComplete) {
                defaults.set(newValue, forKey: "defaultArchiveOnComplete")
            }
        }
    }
    
    var defaultAutoDownload: Bool {
        get {
            access(keyPath: \.defaultAutoDownload)
            return defaults.bool(forKey: "defaultAutoDownload")
        }
        set {
            withMutation(keyPath: \.defaultAutoDownload) {
                defaults.set(newValue, forKey: "defaultAutoDownload")
            }
        }
    }
    
    var defaultDownloadCleanupPolicy: DownloadCleanupPolicy {
        get {
            access(keyPath: \.defaultDownloadCleanupPolicy)
            // Try new key first
            if let raw = defaults.string(forKey: "defaultDownloadCleanupPolicy"),
               let policy = DownloadCleanupPolicy(rawValue: raw) {
                return policy
            }
            // Migrate from legacy Bool key
            if defaults.object(forKey: "defaultRemoveAfterPlay") != nil {
                return defaults.bool(forKey: "defaultRemoveAfterPlay") ? .oncePlayed : .never
            }
            return .oncePlayed
        }
        set {
            withMutation(keyPath: \.defaultDownloadCleanupPolicy) {
                defaults.set(newValue.rawValue, forKey: "defaultDownloadCleanupPolicy")
            }
        }
    }
    
    // MARK: - Queue Management
    
    var queueRemovalAction: QueueRemovalAction {
        get {
            access(keyPath: \.queueRemovalAction)
            guard let raw = defaults.string(forKey: "queueRemovalAction"),
                  let action = QueueRemovalAction(rawValue: raw) else { return .ask }
            return action
        }
        set {
            withMutation(keyPath: \.queueRemovalAction) {
                defaults.set(newValue.rawValue, forKey: "queueRemovalAction")
            }
        }
    }
    
    var hasChosenQueueRemovalAction: Bool {
        get {
            access(keyPath: \.hasChosenQueueRemovalAction)
            return defaults.bool(forKey: "hasChosenQueueRemovalAction")
        }
        set {
            withMutation(keyPath: \.hasChosenQueueRemovalAction) {
                defaults.set(newValue, forKey: "hasChosenQueueRemovalAction")
            }
        }
    }
    
    // MARK: - Feed Cache
    
    var feedCacheDurationHours: Int {
        get {
            access(keyPath: \.feedCacheDurationHours)
            return defaults.object(forKey: "feedCacheDurationHours") as? Int ?? 4
        }
        set {
            withMutation(keyPath: \.feedCacheDurationHours) {
                defaults.set(newValue, forKey: "feedCacheDurationHours")
            }
        }
    }
    
    // MARK: - Search Provider
    
    var searchProvider: SearchProvider {
        get {
            access(keyPath: \.searchProvider)
            guard let raw = defaults.string(forKey: "searchProvider"),
                  let provider = SearchProvider(rawValue: raw) else { return .itunes }
            return provider
        }
        set {
            withMutation(keyPath: \.searchProvider) {
                defaults.set(newValue.rawValue, forKey: "searchProvider")
            }
        }
    }
    
    var podcastIndexApiKey: String? {
        get {
            access(keyPath: \.podcastIndexApiKey)
            return KeychainHelper.shared.podcastIndexCredential(forAccount: "apiKey")
        }
        set {
            withMutation(keyPath: \.podcastIndexApiKey) {
                if let value = newValue, !value.isEmpty {
                    KeychainHelper.shared.savePodcastIndexCredential(value, forAccount: "apiKey")
                } else {
                    KeychainHelper.shared.deletePodcastIndexCredential(forAccount: "apiKey")
                }
            }
        }
    }
    
    var podcastIndexApiSecret: String? {
        get {
            access(keyPath: \.podcastIndexApiSecret)
            return KeychainHelper.shared.podcastIndexCredential(forAccount: "apiSecret")
        }
        set {
            withMutation(keyPath: \.podcastIndexApiSecret) {
                if let value = newValue, !value.isEmpty {
                    KeychainHelper.shared.savePodcastIndexCredential(value, forAccount: "apiSecret")
                } else {
                    KeychainHelper.shared.deletePodcastIndexCredential(forAccount: "apiSecret")
                }
            }
        }
    }
    
    // MARK: - Apple Watch
    
    var watchSyncEnabled: Bool {
        get {
            access(keyPath: \.watchSyncEnabled)
            return defaults.object(forKey: "watchSyncEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.watchSyncEnabled) {
                defaults.set(newValue, forKey: "watchSyncEnabled")
            }
        }
    }
    
    var watchSyncPodcastLimit: Int {
        get {
            access(keyPath: \.watchSyncPodcastLimit)
            return defaults.object(forKey: "watchSyncPodcastLimit") as? Int ?? 5
        }
        set {
            withMutation(keyPath: \.watchSyncPodcastLimit) {
                defaults.set(newValue, forKey: "watchSyncPodcastLimit")
            }
        }
    }
    
    /// Interval (in seconds) at which the watch sends position updates to the phone
    /// during on-watch playback. Lower values = more timely sync but higher battery drain.
    /// Clamped to a minimum of 10 seconds.
    var watchPositionSyncInterval: Int {
        get {
            access(keyPath: \.watchPositionSyncInterval)
            return defaults.object(forKey: "watchPositionSyncInterval") as? Int ?? 30
        }
        set {
            withMutation(keyPath: \.watchPositionSyncInterval) {
                defaults.set(max(newValue, 10), forKey: "watchPositionSyncInterval")
            }
        }
    }
    
    // MARK: - Background Refresh
    
    var backgroundRefreshEnabled: Bool {
        get {
            access(keyPath: \.backgroundRefreshEnabled)
            return defaults.object(forKey: "backgroundRefreshEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.backgroundRefreshEnabled) {
                defaults.set(newValue, forKey: "backgroundRefreshEnabled")
            }
        }
    }
    
    var backgroundRefreshInterval: Int {
        get {
            access(keyPath: \.backgroundRefreshInterval)
            return defaults.object(forKey: "backgroundRefreshInterval") as? Int ?? 60
        }
        set {
            withMutation(keyPath: \.backgroundRefreshInterval) {
                defaults.set(newValue, forKey: "backgroundRefreshInterval")
            }
        }
    }
    
    // MARK: - gPodder Settings
    
    var hidePlayedEpisodes: Bool {
        get {
            access(keyPath: \.hidePlayedEpisodes)
            return defaults.bool(forKey: "hidePlayedEpisodes")
        }
        set {
            withMutation(keyPath: \.hidePlayedEpisodes) {
                defaults.set(newValue, forKey: "hidePlayedEpisodes")
            }
        }
    }
    
    var saveGPodderPassword: Bool {
        get {
            access(keyPath: \.saveGPodderPassword)
            return defaults.bool(forKey: "saveGPodderPassword")
        }
        set {
            withMutation(keyPath: \.saveGPodderPassword) {
                defaults.set(newValue, forKey: "saveGPodderPassword")
            }
        }
    }
    
    // MARK: - App Settings
    
    var defaultStartPage: String {
        get {
            access(keyPath: \.defaultStartPage)
            return defaults.string(forKey: "defaultStartPage") ?? "home"
        }
        set {
            withMutation(keyPath: \.defaultStartPage) {
                defaults.set(newValue, forKey: "defaultStartPage")
            }
        }
    }
    
    // MARK: - Active Profile
    
    var activeProfileId: String? {
        get {
            access(keyPath: \.activeProfileId)
            return defaults.string(forKey: "activeProfileId")
        }
        set {
            withMutation(keyPath: \.activeProfileId) {
                defaults.set(newValue, forKey: "activeProfileId")
            }
        }
    }
    
    // MARK: - Onboarding
    
    var hasCompletedOnboarding: Bool {
        get {
            access(keyPath: \.hasCompletedOnboarding)
            return defaults.bool(forKey: "hasCompletedOnboarding")
        }
        set {
            withMutation(keyPath: \.hasCompletedOnboarding) {
                defaults.set(newValue, forKey: "hasCompletedOnboarding")
            }
        }
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

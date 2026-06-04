import Foundation
import os

/// Global app settings.
///
/// All properties are computed (backed by UserDefaults), so we use manual
/// `access(keyPath:)` / `withMutation(keyPath:)` calls to make `@Observable`
/// track them correctly. Without this, SwiftUI Pickers and Toggles revert
/// immediately because the observation framework never sees the mutations.
@Observable
final class SettingsManager {
    @ObservationIgnored private let logger = Logger(subsystem: "com.yourpods", category: "SettingsManager")
    @ObservationIgnored private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
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
            return defaults.object(forKey: "syncInterval") as? Int ?? 60
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
    
    var autoDownloadNetworkPolicy: AutoDownloadNetworkPolicy {
        get {
            access(keyPath: \.autoDownloadNetworkPolicy)
            guard let raw = defaults.string(forKey: "autoDownloadNetworkPolicy"),
                  let policy = AutoDownloadNetworkPolicy(rawValue: raw) else { return .wifiOnly }
            return policy
        }
        set {
            withMutation(keyPath: \.autoDownloadNetworkPolicy) {
                defaults.set(newValue.rawValue, forKey: "autoDownloadNetworkPolicy")
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
    
    /// Whether watch downloads should be restricted to Wi-Fi only.
    /// Separate from the iPhone's autoDownloadNetworkPolicy because the
    /// watch has much tighter battery and radio constraints.
    /// Default: true (Wi-Fi only) to preserve watch battery.
    var watchDownloadWiFiOnly: Bool {
        get {
            access(keyPath: \.watchDownloadWiFiOnly)
            return defaults.object(forKey: "watchDownloadWiFiOnly") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.watchDownloadWiFiOnly) {
                defaults.set(newValue, forKey: "watchDownloadWiFiOnly")
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
    
    /// Whether to post local notifications when new episodes are discovered during background refresh.
    /// Default: false (privacy-first — users must opt in).
    var newEpisodeNotificationsEnabled: Bool {
        get {
            access(keyPath: \.newEpisodeNotificationsEnabled)
            return defaults.bool(forKey: "newEpisodeNotificationsEnabled")
        }
        set {
            withMutation(keyPath: \.newEpisodeNotificationsEnabled) {
                defaults.set(newValue, forKey: "newEpisodeNotificationsEnabled")
            }
        }
    }
    
    /// Whether to show unplayed episode count as the app icon badge.
    /// Independent from notifications — users can enable badges, notifications, or both.
    /// Default: false (privacy-first — users must opt in).
    var appBadgeEnabled: Bool {
        get {
            access(keyPath: \.appBadgeEnabled)
            return defaults.bool(forKey: "appBadgeEnabled")
        }
        set {
            withMutation(keyPath: \.appBadgeEnabled) {
                defaults.set(newValue, forKey: "appBadgeEnabled")
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
    
    // MARK: - P3 — Privacy Preserving Playback
    
    /// Global toggle for P3 (Privacy Preserving Playback).
    /// When enabled, known tracking/ad-insertion redirects are stripped from episode URLs.
    /// Per-podcast overrides take precedence over this global setting.
    var p3Enabled: Bool {
        get {
            access(keyPath: \.p3Enabled)
            return defaults.bool(forKey: "p3Enabled")
        }
        set {
            withMutation(keyPath: \.p3Enabled) {
                defaults.set(newValue, forKey: "p3Enabled")
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
    
    // MARK: - Vault Mode Detection
    
    /// True when the active profile is a Vault Mode (on-device, no sync) profile.
    /// Used to suppress network-related UI when there's no server dependency.
    var isVaultMode: Bool {
        access(keyPath: \.isVaultMode)
        guard let activeId = defaults.string(forKey: "activeProfileId"),
              let data = defaults.data(forKey: "serverProfiles"),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data),
              let active = profiles.first(where: { $0.id == activeId }) else {
            return false
        }
        return active.isLocal
    }
    
    /// The currently active profile, if any.
    var activeProfile: ServerProfile? {
        guard let activeId = defaults.string(forKey: "activeProfileId"),
              let data = defaults.data(forKey: "serverProfiles"),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return nil
        }
        return profiles.first(where: { $0.id == activeId })
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

    // MARK: - YourPods Pro: Profile Sync

    /// Whether the first profile pull for this `profileName` has been applied.
    ///
    /// The guard is per-profile-name so switching profiles or adding a second
    /// device correctly re-pulls defaults from the server on first connect.
    func proFirstSyncCompleted(profileName: String) -> Bool {
        defaults.bool(forKey: "proFirstSyncCompleted_\(profileName)")
    }

    /// Mark the first profile pull as complete for `profileName`.
    func markProFirstSyncCompleted(profileName: String) {
        defaults.set(true, forKey: "proFirstSyncCompleted_\(profileName)")
    }

    /// Apply server profile settings locally **only on the first pull** for `profileName`.
    ///
    /// After the first pull the local device is the source of truth; subsequent
    /// pulls are pushed TO the server (not from it). This prevents a remote
    /// default from overwriting the user's configured preferences on later syncs.
    ///
    /// - Parameters:
    ///   - settings: The decoded `ProProfileSettings` from `GET /settings/profile`.
    ///   - profileName: The profile name (used as the first-sync guard key).
    func applyFromProfile(_ settings: ProProfileSettings, profileName: String) {
        guard !proFirstSyncCompleted(profileName: profileName) else {
            logger.debug("Profile sync: first sync already done for '\(profileName)' — skipping server apply")
            return
        }

        let p = settings.resolvedPayload

        if case .double(let v) = p["playbackSpeed"] { playbackSpeed = v }
        if case .int(let v) = p["skipForwardSec"] { skipForwardSeconds = v }
        if case .int(let v) = p["skipBackwardSec"] { skipBackwardSeconds = v }
        if case .int(let v) = p["skipIntroSec"] { skipIntroSeconds = v }
        if case .int(let v) = p["skipOutroSec"] { skipOutroSeconds = v }
        if case .bool(let v) = p["autoDownload"] { defaultAutoDownload = v }
        if case .bool(let v) = p["archiveOnComplete"] { defaultArchiveOnComplete = v }
        if case .bool(let v) = p["p3Enabled"] { p3Enabled = v }
        if case .bool(let v) = p["newEpisodeNotificationsEnabled"] { newEpisodeNotificationsEnabled = v }
        if case .bool(let v) = p["appBadgeEnabled"] { appBadgeEnabled = v }
        if case .string(let raw) = p["autopilot"],
           let mode = AutoQueueMode.fromServerValue(raw) {
            defaultAutoQueueMode = mode
        }

        markProFirstSyncCompleted(profileName: profileName)
        logger.info("Profile sync: applied server settings from '\(profileName)'")
    }

    /// Serialise the current settings as a profile payload for `PATCH /settings/profile`.
    ///
    /// Only includes settings that are meaningful to sync across devices.
    /// Device-specific settings (e.g. `watchSyncEnabled`) are intentionally excluded.
    func asProfilePayload() -> [String: AnyCodableValue] {
        [
            "playbackSpeed":    .double(playbackSpeed),
            "skipForwardSec":   .int(skipForwardSeconds),
            "skipBackwardSec":  .int(skipBackwardSeconds),
            "skipIntroSec":     .int(skipIntroSeconds),
            "skipOutroSec":     .int(skipOutroSeconds),
            "autopilot":        .string(defaultAutoQueueMode.serverValue),
            "autoDownload":     .bool(defaultAutoDownload),
            "archiveOnComplete":.bool(defaultArchiveOnComplete),
            "p3Enabled":        .bool(p3Enabled),
            "newEpisodeNotificationsEnabled": .bool(newEpisodeNotificationsEnabled),
            "appBadgeEnabled":  .bool(appBadgeEnabled)
        ]
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

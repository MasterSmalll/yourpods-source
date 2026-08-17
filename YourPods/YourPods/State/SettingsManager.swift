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
    
    // MARK: - Annotations (Notes)

    /// Obsidian vault name for deep-linking notes via `obsidian://` URI.
    /// Empty string means the user hasn't configured a vault.
    var obsidianVaultName: String {
        get {
            access(keyPath: \.obsidianVaultName)
            return defaults.string(forKey: "obsidianVaultName") ?? ""
        }
        set {
            withMutation(keyPath: \.obsidianVaultName) {
                defaults.set(newValue, forKey: "obsidianVaultName")
            }
        }
    }

    /// ISO 8601 cursor for `GET /annotations?since=` delta pulls.
    /// `nil` means no sync has happened — triggers a full pull.
    var lastAnnotationSyncedAt: String? {
        get {
            access(keyPath: \.lastAnnotationSyncedAt)
            return defaults.string(forKey: "lastAnnotationSyncedAt")
        }
        set {
            withMutation(keyPath: \.lastAnnotationSyncedAt) {
                defaults.set(newValue, forKey: "lastAnnotationSyncedAt")
            }
        }
    }

    /// One-time guard for the annotation snake_case→camelCase push heal.
    /// When false on launch, the app re-dirties all local annotations and resets
    /// `lastAnnotationSyncedAt` so the next sync re-pushes notes stranded by the
    /// broken push and re-pulls full server state. Set true after it runs once.
    var didHealAnnotationSyncCasing: Bool {
        get {
            access(keyPath: \.didHealAnnotationSyncCasing)
            return defaults.bool(forKey: "didHealAnnotationSyncCasing")
        }
        set {
            withMutation(keyPath: \.didHealAnnotationSyncCasing) {
                defaults.set(newValue, forKey: "didHealAnnotationSyncCasing")
            }
        }
    }

    /// Remote folder path on Nextcloud for note sync (relative to user's WebDAV root).
    /// Default: `Notes/YourPods`.
    var nextcloudNotesFolder: String {
        get {
            access(keyPath: \.nextcloudNotesFolder)
            return defaults.string(forKey: "nextcloudNotesFolder") ?? NextcloudNotesService.defaultFolder
        }
        set {
            withMutation(keyPath: \.nextcloudNotesFolder) {
                defaults.set(newValue, forKey: "nextcloudNotesFolder")
            }
        }
    }

    /// How to export notes to Obsidian. Default: per-episode file.
    var obsidianExportMode: ObsidianExportMode {
        get {
            access(keyPath: \.obsidianExportMode)
            guard let raw = defaults.string(forKey: "obsidianExportMode"),
                  let mode = ObsidianExportMode(rawValue: raw) else { return .perEpisode }
            return mode
        }
        set {
            withMutation(keyPath: \.obsidianExportMode) {
                defaults.set(newValue.rawValue, forKey: "obsidianExportMode")
            }
        }
    }

    /// Which backend to use for Nextcloud notes sync: raw WebDAV or Notes REST API.
    /// Default: `.webdav` (universal — works without Nextcloud Notes app).
    var nextcloudNotesMode: NextcloudNotesMode {
        get {
            access(keyPath: \.nextcloudNotesMode)
            guard let raw = defaults.string(forKey: "nextcloudNotesMode"),
                  let mode = NextcloudNotesMode(rawValue: raw) else { return .webdav }
            return mode
        }
        set {
            withMutation(keyPath: \.nextcloudNotesMode) {
                defaults.set(newValue.rawValue, forKey: "nextcloudNotesMode")
            }
        }
    }

    /// Whether to automatically sync notes to Nextcloud on each sync cycle.
    /// Only applies to gPodder/Nextcloud profiles. Default: false.
    var nextcloudNotesSyncEnabled: Bool {
        get {
            access(keyPath: \.nextcloudNotesSyncEnabled)
            return defaults.bool(forKey: "nextcloudNotesSyncEnabled")
        }
        set {
            withMutation(keyPath: \.nextcloudNotesSyncEnabled) {
                defaults.set(newValue, forKey: "nextcloudNotesSyncEnabled")
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
    
    var glassAppearance: GlassAppearance {
        get {
            access(keyPath: \.glassAppearance)
            guard let raw = defaults.string(forKey: "glassAppearance"),
                  let mode = GlassAppearance(rawValue: raw) else { return .regular }
            return mode
        }
        set {
            withMutation(keyPath: \.glassAppearance) {
                defaults.set(newValue.rawValue, forKey: "glassAppearance")
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

    // MARK: - Pro Nudge

    /// Whether the user tapped "Don't show this again" on the Settings Pro
    /// upgrade nudge. Persisted so the row stays hidden across launches. Pro
    /// users never see the row regardless of this flag (the account-header tier
    /// badge covers them). Defaults to `false` so a fresh install shows it once.
    var proNudgeDismissed: Bool {
        get {
            access(keyPath: \.proNudgeDismissed)
            return defaults.bool(forKey: "proNudgeDismissed")
        }
        set {
            withMutation(keyPath: \.proNudgeDismissed) {
                defaults.set(newValue, forKey: "proNudgeDismissed")
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
    
    // MARK: - Auto-Hide Old Episodes
    
    /// When true, automatically hide all but the most recent episodes when subscribing to a new podcast.
    var autoHideOldEpisodes: Bool {
        get {
            access(keyPath: \.autoHideOldEpisodes)
            return defaults.object(forKey: "autoHideOldEpisodes") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoHideOldEpisodes) {
                defaults.set(newValue, forKey: "autoHideOldEpisodes")
            }
        }
    }
    
    /// Number of most recent episodes to keep visible when auto-hiding. Default: 3.
    var autoHideKeepRecentCount: Int {
        get {
            access(keyPath: \.autoHideKeepRecentCount)
            return defaults.object(forKey: "autoHideKeepRecentCount") as? Int ?? 3
        }
        set {
            withMutation(keyPath: \.autoHideKeepRecentCount) {
                defaults.set(newValue, forKey: "autoHideKeepRecentCount")
            }
        }
    }
    
    // MARK: - Duration-Based Auto-Hide
    
    /// When true, automatically hide episodes that have been unplayed for longer
    /// than `autoHideUnplayedDays`. Runs on each sync/refresh cycle.
    var autoHideUnplayedEnabled: Bool {
        get {
            access(keyPath: \.autoHideUnplayedEnabled)
            return defaults.bool(forKey: "autoHideUnplayedEnabled")
        }
        set {
            withMutation(keyPath: \.autoHideUnplayedEnabled) {
                defaults.set(newValue, forKey: "autoHideUnplayedEnabled")
            }
        }
    }
    
    /// Number of days an episode can remain unplayed before being auto-hidden. Default: 30.
    var autoHideUnplayedDays: Int {
        get {
            access(keyPath: \.autoHideUnplayedDays)
            return defaults.object(forKey: "autoHideUnplayedDays") as? Int ?? 30
        }
        set {
            withMutation(keyPath: \.autoHideUnplayedDays) {
                defaults.set(newValue, forKey: "autoHideUnplayedDays")
            }
        }
    }
    
    // MARK: - Recently Updated Limit
    
    /// Maximum number of episodes to show in the Recently Updated section. Default: 27.
    var recentlyUpdatedLimit: Int {
        get {
            access(keyPath: \.recentlyUpdatedLimit)
            return defaults.object(forKey: "recentlyUpdatedLimit") as? Int ?? 27
        }
        set {
            withMutation(keyPath: \.recentlyUpdatedLimit) {
                defaults.set(newValue, forKey: "recentlyUpdatedLimit")
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

    // MARK: - Library View Preferences

    var libraryLens: LibraryLens {
        get {
            access(keyPath: \.libraryLens)
            return LibraryLens(rawValue: defaults.string(forKey: "libraryLens") ?? "") ?? .podcasts
        }
        set {
            withMutation(keyPath: \.libraryLens) {
                defaults.set(newValue.rawValue, forKey: "libraryLens")
            }
        }
    }

    var libraryEpisodeArrangement: EpisodeArrangement {
        get {
            access(keyPath: \.libraryEpisodeArrangement)
            return EpisodeArrangement(rawValue: defaults.string(forKey: "libraryEpisodeArrangement") ?? "") ?? .newest
        }
        set {
            withMutation(keyPath: \.libraryEpisodeArrangement) {
                defaults.set(newValue.rawValue, forKey: "libraryEpisodeArrangement")
            }
        }
    }

    var episodeSwipeLeading: EpisodeSwipeAction {
        get {
            access(keyPath: \.episodeSwipeLeading)
            return EpisodeSwipeAction(rawValue: defaults.string(forKey: "episodeSwipeLeading") ?? "") ?? .playNext
        }
        set {
            withMutation(keyPath: \.episodeSwipeLeading) {
                defaults.set(newValue.rawValue, forKey: "episodeSwipeLeading")
            }
        }
    }

    var episodeSwipeTrailing: EpisodeSwipeAction {
        get {
            access(keyPath: \.episodeSwipeTrailing)
            return EpisodeSwipeAction(rawValue: defaults.string(forKey: "episodeSwipeTrailing") ?? "") ?? .addToQueue
        }
        set {
            withMutation(keyPath: \.episodeSwipeTrailing) {
                defaults.set(newValue.rawValue, forKey: "episodeSwipeTrailing")
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

    // MARK: - Translation disclosure

    /// Languages whose AI-translation disclosure the user has already seen.
    ///
    /// Once **per language**, not once ever. Switching from German to Italian
    /// means being shown a translation nobody has warned you about, and the
    /// German sheet you dismissed was written in German — a language you may
    /// not have been reading at the time.
    ///
    /// Deliberately not synced: it is about this install's first impression of
    /// each language, and a second device set to a different language should
    /// still say it.
    var translationDisclosureSeenLanguages: Set<String> {
        get {
            access(keyPath: \.translationDisclosureSeenLanguages)
            return Set(defaults.stringArray(forKey: "translationDisclosureSeenLanguages") ?? [])
        }
        set {
            withMutation(keyPath: \.translationDisclosureSeenLanguages) {
                defaults.set(Array(newValue).sorted(), forKey: "translationDisclosureSeenLanguages")
            }
        }
    }

    /// Records that this language's disclosure has been shown and dismissed.
    func markTranslationDisclosureSeen(for language: String) {
        translationDisclosureSeenLanguages.insert(language)
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

    /// Reconcile local global settings against the server's merged profile payload.
    ///
    /// Replaces the legacy "apply once on first sync, then local wins forever"
    /// model with an ongoing **three-way merge** (base snapshot / local / remote):
    ///
    /// - A key the user did **not** change locally adopts the server value
    ///   (web→iOS settings propagation — the behaviour the first-sync guard blocked).
    /// - A key the user **did** change locally is preserved and returned in the
    ///   sparse push payload (iOS→web). The server merges JSONB per key
    ///   (`payload || EXCLUDED.payload`), so a *full-blob* PATCH would clobber
    ///   another device's keys — therefore we push **only changed keys**.
    /// - A genuine same-key conflict (both changed since base) is resolved by
    ///   `syncConflictStrategy`: server-canonical for `.serverWins`/`.ask`,
    ///   local for `.deviceWins`. Settings conflicts never raise a UI prompt.
    ///
    /// The server stores one `updated_at` per profile blob (no per-key timestamps),
    /// so true newest-decision-wins is impossible here; same-key conflicts use the
    /// strategy above (per-key event-time ordering is a later phase).
    ///
    /// - Parameters:
    ///   - settings: decoded `ProProfileSettings` from `GET /settings/profile`,
    ///     or `nil` when the pull was gated/failed (free tier / offline).
    ///   - profileName: the profile name (also the base-snapshot key).
    /// - Returns: the **sparse** payload of keys this device should `PATCH`
    ///   (only keys where the local value won the merge).
    @discardableResult
    func applyFromProfile(_ settings: ProProfileSettings?, profileName: String) -> [String: AnyCodableValue] {
        let local = asProfilePayload()
        let remote = settings?.resolvedPayload
        let baseKey = "proSettingsBase_\(profileName)"
        let base = loadProfileBaseSnapshot(forKey: baseKey)

        // ── First reconcile for this profile ──────────────────────────────
        if base == nil {
            if proFirstSyncCompleted(profileName: profileName) {
                // Migration from the legacy local-wins-forever model: seed base = local
                // and re-assert local (local-wins) so the user's established prefs survive
                // the upgrade — but push only the keys that actually differ from the
                // server, honouring the sparse-PATCH rule. Never adopt a server value here.
                saveProfileBaseSnapshot(local, forKey: baseKey)
                logger.info("Profile sync: migrated '\(profileName)' to reconcile model (base seeded from local)")
                // No server view: push only genuine customizations, never the full blob
                // (a full blob clobbers another device's keys). With a server view, push
                // only keys that differ from the server.
                guard let remote else { return customizedProfileKeys(in: local) }
                var push: [String: AnyCodableValue] = [:]
                for (key, value) in local where !Self.settingValuesEqual(value, remote[key]) {
                    push[key] = value
                }
                return push
            }
            guard let remote else {
                // Fresh device, no server view (free tier / offline): seed base = local
                // and push only the user's actual customizations — NOT the full default
                // blob, which would clobber another free device's customized keys.
                saveProfileBaseSnapshot(local, forKey: baseKey)
                markProFirstSyncCompleted(profileName: profileName)
                return customizedProfileKeys(in: local)
            }
            // Fresh device, server reachable: adopt server wholesale; seed keys the
            // server lacks with the local value.
            applyServerValues(remote)
            // Base reflects what actually applied: a key whose remote value this build
            // could not parse keeps its local value in base (not the raw remote string).
            var newBase = asProfilePayload()
            for (key, value) in remote where newBase[key] == nil { newBase[key] = value }
            saveProfileBaseSnapshot(newBase, forKey: baseKey)
            markProFirstSyncCompleted(profileName: profileName)
            var push: [String: AnyCodableValue] = [:]
            for (key, value) in local where remote[key] == nil { push[key] = value }
            logger.info("Profile sync: fresh adopt for '\(profileName)' — \(remote.count) server keys, seeded \(push.count)")
            return push
        }

        // ── Steady-state three-way merge ──────────────────────────────────
        guard let base else { return [:] }   // unreachable (handled above)
        let strategy = syncConflictStrategy   // capture once — stable for this cycle
        var merged = base
        var push: [String: AnyCodableValue] = [:]

        for key in local.keys {
            let (mergedValue, pushValue) = Self.resolveSettingKey(
                base: base[key],
                local: local[key],
                remote: remote?[key],
                hasRemote: remote != nil,
                strategy: strategy
            )
            if let mergedValue {
                // Apply locally only when we adopted a value different from current local.
                if !Self.settingValuesEqual(mergedValue, local[key]) {
                    applyServerValues([key: mergedValue])
                    // Persist what ACTUALLY applied: an unparseable enum value leaves the
                    // local property unchanged, so base must reflect the local value (not the
                    // raw remote string). Otherwise the next sync sees false dirt and pushes
                    // the stale local value back, clobbering the newer remote value.
                    merged[key] = asProfilePayload()[key] ?? mergedValue
                } else {
                    merged[key] = mergedValue
                }
            }
            if let pushValue { push[key] = pushValue }
        }

        saveProfileBaseSnapshot(merged, forKey: baseKey)
        return push
    }

    /// Pure three-way resolution for a single global setting key.
    ///
    /// - Returns: `merged` — the value to store as the new base / apply locally;
    ///   `push` — non-nil when this device should `PATCH` the key.
    static func resolveSettingKey(
        base: AnyCodableValue?,
        local: AnyCodableValue?,
        remote: AnyCodableValue?,
        hasRemote: Bool,
        strategy: SyncStrategy
    ) -> (merged: AnyCodableValue?, push: AnyCodableValue?) {
        let localChanged = !settingValuesEqual(local, base)

        guard hasRemote else {
            // No server view this cycle: keep local; push if dirty.
            return (local, localChanged ? local : nil)
        }

        if !localChanged {
            // User didn't touch the key → server is canonical.
            if let remote { return (remote, nil) }
            return (local, nil)   // server omitted the key; keep local, don't push
        }

        // Local changed since base.
        let remoteChanged = remote != nil && !settingValuesEqual(remote, base)
        if !remoteChanged {
            return (local, local)            // server unchanged → local wins, push it
        }
        if settingValuesEqual(remote, local) {
            return (local, nil)              // already converged
        }
        // Genuine conflict: both changed since base, to different values.
        switch strategy {
        case .deviceWins:
            return (local, local)
        case .serverWins, .ask:
            return (remote, nil)             // server-canonical (locked decision)
        }
    }

    /// Numeric-aware equality for setting values: `.int(2)` == `.double(2.0)`,
    /// and `nil`/`.null` are treated as equal (absent vs explicit null).
    static func settingValuesEqual(_ a: AnyCodableValue?, _ b: AnyCodableValue?) -> Bool {
        switch (a, b) {
        case (nil, nil),
             (.some(.null), nil), (nil, .some(.null)), (.some(.null), .some(.null)):
            return true
        case let (.some(x), .some(y)):
            if x == y { return true }
            if let dx = x.asDouble, let dy = y.asDouble { return dx == dy }
            return false
        default:
            return false
        }
    }

    /// Apply a (possibly sparse) server payload to the corresponding local settings.
    /// Numeric keys tolerate either `.int` or `.double` server representations.
    private func applyServerValues(_ p: [String: AnyCodableValue]) {
        if let v = p["playbackSpeed"]?.asDouble { playbackSpeed = v }
        if let v = p["skipForwardSec"]?.asInt { skipForwardSeconds = v }
        if let v = p["skipBackwardSec"]?.asInt { skipBackwardSeconds = v }
        if let v = p["skipIntroSec"]?.asInt { skipIntroSeconds = v }
        if let v = p["skipOutroSec"]?.asInt { skipOutroSeconds = v }
        if case .bool(let v)? = p["autoDownload"] { defaultAutoDownload = v }
        if case .bool(let v)? = p["archiveOnComplete"] { defaultArchiveOnComplete = v }
        if case .bool(let v)? = p["p3Enabled"] { p3Enabled = v }
        if case .bool(let v)? = p["newEpisodeNotificationsEnabled"] { newEpisodeNotificationsEnabled = v }
        if case .bool(let v)? = p["appBadgeEnabled"] { appBadgeEnabled = v }
        if case .string(let raw)? = p["autopilot"], let mode = AutoQueueMode.fromServerValue(raw) {
            defaultAutoQueueMode = mode
        }
        if case .string(let raw)? = p["glassAppearance"], let mode = GlassAppearance(rawValue: raw) {
            glassAppearance = mode
        }
        if case .string(let raw)? = p["syncConflictStrategy"], let strategy = SyncStrategy(rawValue: raw) {
            syncConflictStrategy = strategy
        }
        // Global prefs ported to sync (#2). Translate web wire vocab → iOS local vocab.
        if case .string(let raw)? = p["queueRemoval"], let action = QueueRemovalAction.fromServerValue(raw) {
            queueRemovalAction = action
        }
        if case .bool(let v)? = p["autoHideOldEpisodes"] { autoHideOldEpisodes = v }
        if let v = p["autoHideKeepRecentCount"]?.asInt { autoHideKeepRecentCount = v }
        if case .string(let raw)? = p["startPage"] { defaultStartPage = Self.startPageLocalValue(raw) }
        if let v = p["syncIntervalSec"]?.asInt { syncInterval = v }
    }

    /// The factory-default global profile payload (every synced setting at its shipped
    /// default). Derived once from a fresh, isolated `SettingsManager` so it can never
    /// drift from the real defaults. Used to push only genuine customizations when there
    /// is no server view.
    private static let factoryDefaultProfilePayload: [String: AnyCodableValue] = {
        let suiteName = "com.yourpods.factory-default-probe"
        guard let probe = UserDefaults(suiteName: suiteName) else { return [:] }
        probe.removePersistentDomain(forName: suiteName)
        let payload = SettingsManager(defaults: probe).asProfilePayload()
        probe.removePersistentDomain(forName: suiteName)
        return payload
    }()

    /// Keys whose local value differs from the factory default — the user's genuine
    /// customizations. Pushing only these (instead of the full blob) keeps the
    /// sparse-PATCH guarantee when there is no server view to merge against.
    private func customizedProfileKeys(in local: [String: AnyCodableValue]) -> [String: AnyCodableValue] {
        let defaults = Self.factoryDefaultProfilePayload
        var out: [String: AnyCodableValue] = [:]
        for (key, value) in local where !Self.settingValuesEqual(value, defaults[key]) {
            out[key] = value
        }
        return out
    }

    /// Load the last-reconciled server payload snapshot (the three-way merge base).
    private func loadProfileBaseSnapshot(forKey key: String) -> [String: AnyCodableValue]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodableValue].self, from: data)
    }

    /// Persist the reconciled payload as the new base snapshot.
    private func saveProfileBaseSnapshot(_ payload: [String: AnyCodableValue], forKey key: String) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
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
            "appBadgeEnabled":  .bool(appBadgeEnabled),
            "glassAppearance":  .string(glassAppearance.rawValue),
            "syncConflictStrategy": .string(syncConflictStrategy.rawValue),
            // Global prefs ported to sync. Wire keys/vocab match the web client.
            "queueRemoval":     .string(queueRemovalAction.serverValue),
            "autoHideOldEpisodes": .bool(autoHideOldEpisodes),
            "autoHideKeepRecentCount": .int(autoHideKeepRecentCount),
            "startPage":        .string(Self.startPageWireValue(defaultStartPage)),
            "syncIntervalSec":  .int(syncInterval)
        ]
    }

    /// iOS `defaultStartPage` vocab (`home`/`library`/`upnext`) ↔ web `startPage` wire
    /// vocab (`home`/`library`/`upNext`). Only `upnext` differs in case.
    private static func startPageWireValue(_ local: String) -> String {
        local == "upnext" ? "upNext" : local
    }

    /// Inverse of `startPageWireValue` — web wire vocab → iOS local vocab.
    private static func startPageLocalValue(_ wire: String) -> String {
        wire == "upNext" ? "upnext" : wire
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

private extension AnyCodableValue {
    /// Numeric value as `Double` (representation-agnostic: `.int`/`.double`).
    var asDouble: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
    /// Numeric value as `Int`, rounding a `.double` to nearest. Out-of-range or
    /// non-finite doubles return `nil` (NOT a trap): `Int(_:)` of a double beyond
    /// `Int64`'s range is an uncatchable fatal error, and a hostile/buggy server
    /// number must never crash a sync (incl. background). `Int(exactly:)` of the
    /// already-rounded value is boundary-correct (handles ±inf, NaN, and the 2^63
    /// edge that a manual `<= Double(Int.max)` range check would miss).
    var asInt: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v.rounded())
        default: return nil
        }
    }
}

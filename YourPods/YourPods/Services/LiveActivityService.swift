import Foundation
import os
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Service that manages iOS Live Activities / Dynamic Island for podcast playback.
///
/// Uses shared UserDefaults via App Group to pass data to the widget extension.
/// Button taps on the Dynamic Island are received via URL scheme (yourpods://action/...)
/// and forwarded to a callback so PlayerManager can route them to play/pause/skip.
///
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
                    try data.write(to: imageFile, options: .atomic)
                    sharedDefaults?.set(imageFile.path, forKey: key)
                }
            } catch {
                logger.error("Failed to download artwork: \(error.localizedDescription)")
            }
        }
    }
    
    #if os(iOS)
    /// Stable, filesystem-safe per-episode filename for widget artwork.
    /// Per-episode names mean the widget never reads a half-written or stale
    /// fixed file, and a fresh path string forces WidgetKit to re-decode.
    static func widgetArtFilename(for episodeId: String) -> String {
        var safe = String(episodeId.unicodeScalars.map { scalar in
            (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
                ? Character(scalar) : "_"
        })
        if safe.count > 100 { safe = String(safe.suffix(100)) }
        return "widget_art_\(safe).jpg"
    }

    /// Resolve widget artwork from the in-process image cache (no network) and
    /// write it to a per-episode file in the App Group container. Returns the
    /// path, or nil on a cache miss. Skips the JPEG re-encode when the file for
    /// this episode already exists — so the ~5s progress tick (which re-pushes
    /// widget data with `reloadTimeline: false`) doesn't rewrite the file.
    private func resolveCachedWidgetArtwork(url: String, episodeId: String) -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupId) else { return nil }
        let dest = containerURL.appendingPathComponent(Self.widgetArtFilename(for: episodeId))

        // Already written for this episode — reuse without re-encoding.
        if FileManager.default.fileExists(atPath: dest.path) { return dest.path }

        guard let image = cachedImage(for: url),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try jpeg.write(to: dest, options: .atomic)
            return dest.path
        } catch {
            logger.error("Failed to write cached widget artwork: \(error.localizedDescription)")
            return nil
        }
    }

    /// Pull an image from the shared in-process cache (memory → disk). No network.
    private func cachedImage(for url: String) -> UIImage? {
        if let mem = ImageCacheStore.shared.cache.object(forKey: url as NSString) { return mem }
        if let disk = ImageCacheStore.shared.loadFromDisk(key: url) {
            ImageCacheStore.shared.cache.setObject(disk, forKey: url as NSString)
            return disk
        }
        return nil
    }

    /// Delete stale per-episode artwork files (and the legacy fixed file),
    /// keeping only artwork for currently visible episodes (now-playing + up-next),
    /// to bound App Group container growth.
    private func cleanupOldWidgetArtwork(keeping episodeIds: Set<String>, in containerURL: URL) {
        let keepNames = Set(episodeIds.map { Self.widgetArtFilename(for: $0) })
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: containerURL.path) else { return }
        for name in names where name.hasPrefix("widget_art") && name.hasSuffix(".jpg") {
            if keepNames.contains(name) { continue }
            try? fm.removeItem(at: containerURL.appendingPathComponent(name))
        }
    }

    /// Download artwork for the Home Screen widget on a cache miss, writing the
    /// same per-episode atomic file and seeding the image cache for next time.
    private func downloadWidgetArtwork(url: String, episodeId: String) {
        guard let artURL = URL(string: url) else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: artURL)

                guard let containerURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: Self.appGroupId
                ) else { return }

                let dest = containerURL.appendingPathComponent(Self.widgetArtFilename(for: episodeId))
                try data.write(to: dest, options: .atomic)

                // Seed the cache so the next widget update reuses it without a fetch.
                if let image = UIImage(data: data) {
                    ImageCacheStore.shared.cache.setObject(image, forKey: url as NSString)
                    ImageCacheStore.shared.saveToDisk(image: image, key: url)
                }

                var widgetData = ComplicationDataStore.shared.read()
                widgetData.artworkPath = dest.path
                ComplicationDataStore.shared.write(widgetData)

                // Keep artwork for all currently visible episodes (now-playing + up-next).
                let currentData = ComplicationDataStore.shared.read()
                var keepIds: Set<String> = [episodeId]
                // Infer up-next episode IDs from their artwork filenames if available.
                for upNext in currentData.upNextItems {
                    if let path = upNext.artworkPath,
                       let filename = path.split(separator: "/").last {
                        // Extract episode ID from "widget_art_<id>.jpg"
                        let name = String(filename)
                        if name.hasPrefix("widget_art_") && name.hasSuffix(".jpg") {
                            let id = String(name.dropFirst("widget_art_".count).dropLast(".jpg".count))
                            keepIds.insert(id)
                        }
                    }
                }
                cleanupOldWidgetArtwork(keeping: keepIds, in: containerURL)
                WidgetCenter.shared.reloadTimelines(ofKind: "YourPodsPlayback")
                logger.debug("Widget artwork downloaded for \(episodeId)")
            } catch {
                logger.error("Failed to download widget artwork: \(error.localizedDescription)")
            }
        }
    }
    #endif
    
    // MARK: - Home Screen Widget Data
    
    /// Write current playback state and Up Next queue to shared data store
    /// so the Home Screen widget can display it.
    ///
    /// - Parameters:
    ///   - episodeTitle: Title of the currently playing episode, or nil if nothing playing
    ///   - podcastName: Name of the current podcast
    ///   - artworkPath: Local file path to artwork in the shared container
    ///   - artworkUrl: Remote URL to download artwork from (used when artworkPath is nil)
    ///   - isPlaying: Whether playback is active
    ///   - positionSeconds: Current playback position
    ///   - durationSeconds: Total episode duration
    ///   - upNextItems: Queue items for the large widget's Up Next list
    ///   - reloadTimeline: Whether to trigger a WidgetCenter timeline reload.
    ///     Pass `false` during periodic progress updates — the widget's projected
    ///     timeline entries already advance the progress bar. Reloading every 5s
    ///     replaces those entries and makes the progress bar appear frozen.
    func updateWidgetData(
        episodeTitle: String?,
        podcastName: String?,
        artworkPath: String?,
        artworkUrl: String? = nil,
        episodeId: String? = nil,
        isPlaying: Bool,
        positionSeconds: Int,
        durationSeconds: Int,
        upNextItems: [(title: String, podcastTitle: String, artworkPath: String?, artworkUrl: String?, episodeId: String?)],
        reloadTimeline: Bool = true
    ) {
        #if os(iOS)
        // Resolve artwork for each up-next item (same pattern as now-playing).
        let widgetUpNextItems = upNextItems.map { item -> WidgetUpNextItem in
            var resolvedPath = item.artworkPath
            if resolvedPath == nil, let url = item.artworkUrl, !url.isEmpty,
               let eid = item.episodeId {
                resolvedPath = resolveCachedWidgetArtwork(url: url, episodeId: eid)
            }
            return WidgetUpNextItem(
                title: item.title,
                podcastTitle: item.podcastTitle,
                artworkPath: resolvedPath
            )
        }
        
        // Resolve artwork.
        // 1) An explicit caller-provided local path always wins.
        // 2) Otherwise write the already-cached now-playing image to a per-episode
        //    file (no network — survives backgrounding). The per-episode filename
        //    also forces WidgetKit to re-decode rather than reuse a cached decode
        //    of a stale fixed path. The old "reuse widget_art.jpg if it exists"
        //    fallback is intentionally gone — it was the source of the widget
        //    showing the *previous* episode's artwork after auto-advance.
        var resolvedArtworkPath = artworkPath
        if resolvedArtworkPath == nil, let episodeId, let artworkUrl, !artworkUrl.isEmpty {
            resolvedArtworkPath = resolveCachedWidgetArtwork(url: artworkUrl, episodeId: episodeId)
        }

        let data = ComplicationData(
            nowPlayingTitle: episodeTitle,
            nowPlayingPodcast: podcastName,
            isPlaying: isPlaying,
            upNextTitle: upNextItems.first?.title,
            upNextPodcast: upNextItems.first?.podcastTitle,
            queueCount: upNextItems.count,
            lastUpdated: Date(),
            artworkPath: resolvedArtworkPath,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            upNextItems: widgetUpNextItems
        )
        
        // Instrumentation: this app-group UserDefaults write fires every ~5s
        // during playback (via PlayerManager.pushWidgetUpdate) and is the prime
        // suspect for the sustained background disk-write volume. Count only the
        // writes that actually hit disk — the store dedups materially-unchanged
        // burst pushes, so recording unconditionally over-counts the "widget"
        // source and misleads 0xDEAD10CC disk-write triage.
        if ComplicationDataStore.shared.write(data) {
            WriteInstrumentation.shared.recordDefaultsWrite(source: "widget")
        }

        if reloadTimeline {
            WidgetCenter.shared.reloadTimelines(ofKind: "YourPodsPlayback")
        }
        
        // Cleanup old artwork files, keeping all currently visible episodes.
        var keepIds = Set<String>()
        if let episodeId { keepIds.insert(episodeId) }
        for item in upNextItems {
            if let eid = item.episodeId { keepIds.insert(eid) }
        }
        if !keepIds.isEmpty, let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            cleanupOldWidgetArtwork(keeping: keepIds, in: containerURL)
        }

        // Cache miss: fall back to a network download (rare — the now-playing
        // load usually populates the cache first). Writes the same per-episode
        // atomic file and seeds the cache for next time. Safe in the background
        // because auto-advance downloads run while the `audio` background mode
        // keeps the app alive.
        if resolvedArtworkPath == nil, let episodeId, let artworkUrl, !artworkUrl.isEmpty {
            downloadWidgetArtwork(url: artworkUrl, episodeId: episodeId)
        }
        
        logger.debug("Updated widget data: \(episodeTitle ?? "nil"), playing=\(isPlaying), queue=\(upNextItems.count), art=\(resolvedArtworkPath ?? "nil"), reload=\(reloadTimeline)")
        #endif
    }

    
    /// Clear widget data when playback stops.
    func clearWidgetData() {
        #if os(iOS)
        ComplicationDataStore.shared.write(.empty)

        // Remove all per-episode artwork files so the container doesn't grow.
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            cleanupOldWidgetArtwork(keeping: [], in: containerURL)
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "YourPodsPlayback")

        logger.debug("Cleared widget data")
        #endif
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

import Foundation
import CoreGraphics
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Stores chapter artwork extracted from audio files.
///
/// Every reference implementation that ships chapter art (MNAVChapters, Pocket
/// Casts, OutcastID3) eagerly decodes a full-resolution image per chapter and
/// holds them all resident. That is the widget-artwork OOM crash class, and
/// chapter images are big — 61–104 KB typical, 2.75 MB observed. Instead we
/// downsample through ImageIO at extraction time, hand the result to the shared
/// ImageCacheStore (memory NSCache + LRU-trimmed disk), and keep only a key on
/// the model. Raw bytes are discarded immediately.
enum ChapterArtworkStore {

    private static let logger = Logger(subsystem: "com.yourpods", category: "chapters")

    /// Chapter art is shown from `ChapterListSheet`'s 40 pt list thumbnail
    /// (`ChapterListSheet.swift:111`) up to `PlayerView`'s 300 pt
    /// `maxWidth`/`maxHeight` artwork frame (`PlayerView.swift:39`) — the
    /// largest on-screen surface. 300 pt × 3x (iPhone Pro-class displays) is
    /// 900 px, which this matches so the player renders at native resolution.
    ///
    /// **Memory budget.** `ImageCacheStore` caps `cache` at `countLimit = 50`
    /// with no `totalCostLimit` (`CachedAsyncImage.swift:142`) — so item
    /// count is the primary eviction backstop. A decoded 900×900 RGBA image
    /// is ~3.24 MB, so a worst-case 30-chapter episode holds ~97 MB resident
    /// (vs. ~43 MB at 600 px) and can evict podcast/episode artwork sharing
    /// the same cache. The chapter `setObject` call sites below DO pass a
    /// per-object byte `cost` (see `decodedByteCost(of:)`), so `NSCache` can
    /// weigh a 3 MB chapter bitmap by size — not merely as one of 50 equal
    /// slots — when it reclaims under memory pressure. Accepted because:
    /// `cache` is a purgeable `NSCache` the system can reclaim under memory
    /// pressure, not a hard allocation; and the widget extension — where this
    /// repo's documented OOM crash class actually kills the process at a hard
    /// ~30 MB budget — does not link this cache at all (`project.yml`:
    /// `YourPodsWidgets` sources only `YourPodsWidgets/` +
    /// `WidgetArtworkLoader.swift`, never
    /// `Views/Components/CachedAsyncImage.swift`). So 900 px is main-app
    /// cache pressure on a reclaimable store, not an extension kill risk.
    /// Do not raise `ImageCacheStore`'s `totalCostLimit` to compensate here —
    /// that changes shared behavior for every other caller and is out of
    /// this store's scope.
    static let maxPixelSize = 900

    /// Namespaced so chapter keys can never collide with the artwork-URL keys
    /// ImageCacheStore holds for episode and podcast images.
    static func cacheKey(audioUrl: String, index: Int) -> String {
        "chapterart:\(stableHash(audioUrl)):\(index)"
    }

    /// Downsample and cache. Returns the key, or nil if the bytes could not be
    /// decoded (truncated APIC, unknown format) — the caller then leaves
    /// `embeddedImageKey` nil and the UI falls back to episode art.
    ///
    /// Synchronous and blocking: ImageIO decode, then a JPEG encode and a
    /// disk write inside `ImageCacheStore`. Callers must invoke this off the
    /// main thread — a long enough main-thread stall is a watchdog kill, the
    /// same class as the "no synchronous SwiftData on the main thread" rule.
    /// (Not `0xDEAD10CC`, which is the separate suspension-time-write kill for
    /// unguarded SQLite writes into the app-group store; this is a plain JPEG
    /// file write.)
    @discardableResult
    static func store(imageData: Data, audioUrl: String, index: Int) -> String? {
        // Guard the cache-key seed: `EmbeddedChapterExtractor.chapters(for:)`
        // proceeds for a downloaded item whose `audioUrl` is empty, and an
        // empty `audioUrl` collapses every episode's key onto
        // `stableHash("")` — one episode's chapter art would resolve for
        // another. Effectively unreachable today (an episode with no audio
        // URL can't be downloaded, so no `localFileUrl` exists either), but a
        // one-line guard keeps a future path from silently sharing keys.
        guard !audioUrl.isEmpty else {
            logger.debug("⟦CHAPTERS⟧ artwork skip — empty audioUrl would collide on stableHash(\"\") idx=\(index)")
            return nil
        }
        guard let cgImage = WatchArtworkDownsampler.downsample(data: imageData,
                                                               maxPixelSize: maxPixelSize) else {
            logger.debug("⟦CHAPTERS⟧ artwork decode failed idx=\(index) bytes=\(imageData.count)")
            return nil
        }

        #if canImport(UIKit)
        let image = UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif

        let key = cacheKey(audioUrl: audioUrl, index: index)
        ImageCacheStore.shared.cache.setObject(image, forKey: key as NSString,
                                               cost: decodedByteCost(of: image))
        ImageCacheStore.shared.saveToDisk(image: image, key: key)
        return key
    }

    /// Resolve a stored image: memory first, then disk (promoting back into
    /// memory). Nil after eviction — the key is re-derivable, so the cost is a
    /// re-extract, not a permanent loss.
    static func image(forKey key: String) -> PlatformImage? {
        if let memory = ImageCacheStore.shared.cache.object(forKey: key as NSString) {
            return memory
        }
        if let disk = ImageCacheStore.shared.loadFromDisk(key: key) {
            ImageCacheStore.shared.cache.setObject(disk, forKey: key as NSString,
                                                   cost: decodedByteCost(of: disk))
            return disk
        }
        return nil
    }

    // MARK: - Private

    /// Decoded byte size of a cached image, for `NSCache`'s `cost` accounting.
    /// `ImageCacheStore.cache` sets a `countLimit` but no `totalCostLimit`, so
    /// before this every chapter image entered the cache cost-less and item
    /// count was the ONLY eviction backstop — a worst-case chaptered episode
    /// could hold tens of ~3.24 MB 900×900 bitmaps resident in a cache shared
    /// with podcast/episode artwork. Passing the real per-object cost is the
    /// cheap mitigation (no cache restructuring, no spec change): it lets
    /// `NSCache` weigh an entry by SIZE rather than treating a 3 MB chapter
    /// bitmap as just one of 50 equal slots. `bytesPerRow * height` is the
    /// exact decoded footprint. A nil `cgImage` — which should never happen
    /// for an image we just built or just loaded from disk — falls back to 0,
    /// i.e. the pre-cost behaviour, never a crash.
    private static func decodedByteCost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return 0 }
        #elseif canImport(AppKit)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        #endif
        return cg.bytesPerRow * cg.height
    }

    /// Deterministic across launches — unlike `String.hashValue`, which is
    /// seeded per process and would orphan every disk-cached chapter image on
    /// relaunch.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in Data(string.utf8) {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}

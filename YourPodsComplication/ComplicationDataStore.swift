import Foundation

/// Lightweight model for an Up Next queue item in the widget.
struct WidgetUpNextItem: Codable, Equatable {
    let title: String
    let podcastTitle: String
    let artworkPath: String?
}

/// Shared data store for widgets and Apple Watch complications.
///
/// Both the watch app, widget extensions, and the main app read/write through
/// this store using an App Group container so widgets and the complication can
/// access the latest playback and queue state.
struct ComplicationData: Codable {
    var nowPlayingTitle: String?
    var nowPlayingPodcast: String?
    var isPlaying: Bool
    var upNextTitle: String?
    var upNextPodcast: String?
    var queueCount: Int
    var lastUpdated: Date

    // Widget-specific fields. The watch complication doesn't render these —
    // see `meaningfullyDiffers`, which deliberately ignores them.
    var artworkPath: String?
    var positionSeconds: Int
    var durationSeconds: Int
    var upNextItems: [WidgetUpNextItem]

    static let empty = ComplicationData(
        nowPlayingTitle: nil,
        nowPlayingPodcast: nil,
        isPlaying: false,
        upNextTitle: nil,
        upNextPodcast: nil,
        queueCount: 0,
        lastUpdated: Date(),
        artworkPath: nil,
        positionSeconds: 0,
        durationSeconds: 0,
        upNextItems: []
    )

    /// Custom decoder with backward-compatible defaults for new fields.
    /// Existing watchOS complications won't have the new widget keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nowPlayingTitle = try c.decodeIfPresent(String.self, forKey: .nowPlayingTitle)
        nowPlayingPodcast = try c.decodeIfPresent(String.self, forKey: .nowPlayingPodcast)
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        upNextTitle = try c.decodeIfPresent(String.self, forKey: .upNextTitle)
        upNextPodcast = try c.decodeIfPresent(String.self, forKey: .upNextPodcast)
        queueCount = try c.decodeIfPresent(Int.self, forKey: .queueCount) ?? 0
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
        artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath)
        positionSeconds = try c.decodeIfPresent(Int.self, forKey: .positionSeconds) ?? 0
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        upNextItems = try c.decodeIfPresent([WidgetUpNextItem].self, forKey: .upNextItems) ?? []
    }

    /// Memberwise init
    init(
        nowPlayingTitle: String?,
        nowPlayingPodcast: String?,
        isPlaying: Bool,
        upNextTitle: String?,
        upNextPodcast: String?,
        queueCount: Int,
        lastUpdated: Date,
        artworkPath: String? = nil,
        positionSeconds: Int = 0,
        durationSeconds: Int = 0,
        upNextItems: [WidgetUpNextItem] = []
    ) {
        self.nowPlayingTitle = nowPlayingTitle
        self.nowPlayingPodcast = nowPlayingPodcast
        self.isPlaying = isPlaying
        self.upNextTitle = upNextTitle
        self.upNextPodcast = upNextPodcast
        self.queueCount = queueCount
        self.lastUpdated = lastUpdated
        self.artworkPath = artworkPath
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.upNextItems = upNextItems
    }

    /// Equality ignoring `lastUpdated`. The widget data is re-pushed in bursts
    /// during sync / scene transitions carrying a fresh `lastUpdated` stamp but
    /// otherwise identical state. Comparing on the material fields lets the store
    /// skip those redundant app-group writes (see `ComplicationDataStore.write`).
    func isMateriallyEqual(to other: ComplicationData) -> Bool {
        nowPlayingTitle == other.nowPlayingTitle &&
        nowPlayingPodcast == other.nowPlayingPodcast &&
        isPlaying == other.isPlaying &&
        upNextTitle == other.upNextTitle &&
        upNextPodcast == other.upNextPodcast &&
        queueCount == other.queueCount &&
        artworkPath == other.artworkPath &&
        positionSeconds == other.positionSeconds &&
        durationSeconds == other.durationSeconds &&
        upNextItems == other.upNextItems
    }

    /// True when a field the complication actually renders changed.
    /// lastUpdated alone must not burn the complication reload budget.
    ///
    /// Deliberately narrower than `isMateriallyEqual` (used by the Home Screen
    /// widget's write-dedup, which also tracks artwork/position/duration/
    /// upNextItems): the watch complication only ever renders now-playing +
    /// up-next title/podcast/play-state/queue-count, so ticking position every
    /// second must not count as "meaningful" here.
    func meaningfullyDiffers(from other: ComplicationData) -> Bool {
        nowPlayingTitle != other.nowPlayingTitle
            || nowPlayingPodcast != other.nowPlayingPodcast
            || isPlaying != other.isPlaying
            || upNextTitle != other.upNextTitle
            || upNextPodcast != other.upNextPodcast
            || queueCount != other.queueCount
    }
}

/// Reads and writes ``ComplicationData`` to shared `UserDefaults`.
///
/// The App Group identifier must match the one configured in both
/// targets' entitlements and the Apple Developer portal.
final class ComplicationDataStore {
    static let shared = ComplicationDataStore()

    /// Must match the App Group configured in the target entitlements.
    /// The watch app + complication share one group on the WATCH; the iOS app
    /// + its widgets share a different one on the PHONE (separate devices,
    /// separate containers — the ids only need to be consistent per platform).
    #if os(watchOS)
    static let appGroupId = "group.com.asecretcompany.yourpods.watch"
    #else
    static let appGroupId = "group.com.asecretcompany.yourpods"
    #endif

    private let defaults: UserDefaults?
    private let key = "complication_data"

    /// In-memory snapshot of the last state we persisted, used to drop redundant
    /// writes that differ only by `lastUpdated`. Every write to the app-group
    /// store is a suspension-straddle risk (0xDEAD10CC); the widget pipeline
    /// re-pushes identical state in bursts, so this collapses a burst to one write.
    private var lastWritten: ComplicationData?

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroupId)
    }

    #if DEBUG
    /// Test-only init for injecting custom UserDefaults.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }
    #endif

    /// Write the latest complication state.
    ///
    /// Skips the app-group write when the state is materially unchanged from the
    /// last write (only `lastUpdated` differs) — a redundant write is pure
    /// suspension-straddle risk with no UI benefit.
    /// Returns `true` if the state was actually persisted, `false` if the write
    /// was skipped (materially unchanged, or encoding failed). Callers use this
    /// to count only real app-group writes (e.g. `WriteInstrumentation`).
    @discardableResult
    func write(_ data: ComplicationData) -> Bool {
        if let lastWritten, lastWritten.isMateriallyEqual(to: data) { return false }
        guard let encoded = try? JSONEncoder().encode(data) else { return false }
        defaults?.set(encoded, forKey: key)
        lastWritten = data
        return true
    }

    /// Read the current complication state, or `.empty` if none.
    func read() -> ComplicationData {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ComplicationData.self, from: data) else {
            return .empty
        }
        return decoded
    }
}

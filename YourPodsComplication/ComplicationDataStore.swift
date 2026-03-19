import Foundation

/// Shared data store for Apple Watch complications.
///
/// Both the watch app and the WidgetKit extension read/write through
/// this store using an App Group container so the complication can
/// access the latest playback and queue state.
struct ComplicationData: Codable {
    var nowPlayingTitle: String?
    var nowPlayingPodcast: String?
    var isPlaying: Bool
    var upNextTitle: String?
    var upNextPodcast: String?
    var queueCount: Int
    var lastUpdated: Date
    
    static let empty = ComplicationData(
        nowPlayingTitle: nil,
        nowPlayingPodcast: nil,
        isPlaying: false,
        upNextTitle: nil,
        upNextPodcast: nil,
        queueCount: 0,
        lastUpdated: Date()
    )
}

/// Reads and writes ``ComplicationData`` to shared `UserDefaults`.
///
/// The App Group identifier must match the one configured in both
/// targets' entitlements and the Apple Developer portal.
final class ComplicationDataStore {
    static let shared = ComplicationDataStore()
    
    /// Must match the App Group configured in Xcode capabilities.
    static let appGroupId = "group.com.asecretcompany.yourpods"
    
    private let defaults: UserDefaults?
    private let key = "complication_data"
    
    private init() {
        defaults = UserDefaults(suiteName: Self.appGroupId)
    }
    
    /// Write the latest complication state.
    func write(_ data: ComplicationData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults?.set(encoded, forKey: key)
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

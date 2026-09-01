import Foundation
import Combine

/// A timestamp captured hands-free on Apple Watch and delivered to the iPhone.
struct SyncedCapturedMoment: Codable, Identifiable, Hashable {
    let id: String
    let episodeId: String
    let podcastTitle: String
    let episodeTitle: String
    let timestampSec: Double
    let capturedAt: Date
}

/// Phone-side persistent store for Apple Watch podcast captures.
///
/// UUID-based deduplication makes delivery idempotent: the Watch may retry via
/// both live messages and durable transferUserInfo without creating duplicates.
@MainActor
final class CapturedMomentStore: ObservableObject {
    static let shared = CapturedMomentStore()

    @Published private(set) var moments: [SyncedCapturedMoment]

    private let defaultsKey = "iphone_captured_moments_v1"
    private let limit = 2000

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SyncedCapturedMoment].self, from: data) {
            moments = decoded.sorted { $0.capturedAt > $1.capturedAt }
        } else {
            moments = []
        }
    }

    @discardableResult
    func ingest(_ payload: [String: Any]) -> Bool {
        guard let id = payload["id"] as? String,
              let episodeId = payload["episodeId"] as? String,
              let podcastTitle = payload["podcastTitle"] as? String,
              let episodeTitle = payload["episodeTitle"] as? String,
              let timestamp = Self.doubleValue(payload["timestampSec"]),
              let capturedAtValue = Self.doubleValue(payload["capturedAt"]) else {
            return false
        }

        guard !moments.contains(where: { $0.id == id }) else {
            return true
        }

        let moment = SyncedCapturedMoment(
            id: id,
            episodeId: episodeId,
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            timestampSec: timestamp,
            capturedAt: Date(timeIntervalSince1970: capturedAtValue)
        )

        moments.append(moment)
        moments.sort { $0.capturedAt > $1.capturedAt }
        if moments.count > limit {
            moments.removeLast(moments.count - limit)
        }
        persist()
        return true
    }

    func clearAll() {
        moments.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(moments) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

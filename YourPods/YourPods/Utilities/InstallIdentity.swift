import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Per-install unique device identifier for action stamping.
///
/// Distinct from `profile.deviceId` (used for gpodder.net API path parameters)
/// and `proProfileName` (sync bucket). This ID identifies which physical device
/// generated an EpisodeAction, enabling correct cross-device conflict detection.
enum InstallIdentity {
    static let installIdKey = "com.yourpods.installId"

    /// Per-install unique device identifier.
    /// Created once, persisted in UserDefaults.
    /// Includes device model for server-side debugging/analytics.
    static var installId: String {
        if let existing = UserDefaults.standard.string(forKey: installIdKey), !existing.isEmpty {
            return existing
        }
        let model = deviceModelShort
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let newId = "yourpods-\(model)-\(suffix)"
        UserDefaults.standard.set(newId, forKey: installIdKey)
        return newId
    }

    /// Short device model name ("iPhone", "iPad", "Mac").
    private static var deviceModelShort: String {
        #if os(iOS) || os(visionOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #elseif os(macOS)
        return "Mac"
        #elseif os(watchOS)
        return "Watch"
        #else
        return "ios"
        #endif
    }
}

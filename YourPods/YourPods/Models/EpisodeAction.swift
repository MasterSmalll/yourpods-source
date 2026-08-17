import Foundation

/// Represents a gPodder episode action for sync.
struct EpisodeAction: Codable, Identifiable, Sendable {
    var id: String { "\(podcast)|\(episode)|\(timestamp)" }
    
    let podcast: String
    let episode: String
    let guid: String?
    let action: String  // "play", "new", "download", "delete"
    let timestamp: Int   // Unix epoch seconds
    let position: Int?
    let started: Int?
    let total: Int?
    let device: String?
    
    /// Encode for upload to gPodder server.
    func toUploadJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "podcast": podcast,
            "episode": episode,
            "action": action,
            "timestamp": ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: TimeInterval(timestamp))
            ),
        ]
        if let guid { dict["guid"] = guid }
        if let position { dict["position"] = position }
        if let started { dict["started"] = started }
        if let total { dict["total"] = total }
        if let device { dict["device"] = device }
        return dict
    }
    
    /// Parse from gPodder server JSON.
    static func from(json: [String: Any]) -> EpisodeAction? {
        guard let podcast = json["podcast"] as? String,
              let episode = json["episode"] as? String,
              let action = json["action"] as? String
        else { return nil }
        
        let timestamp: Int
        if let ts = json["timestamp"] as? Int {
            timestamp = ts
        } else if let tsStr = json["timestamp"] as? String,
                  let date = ISO8601DateFormatter().date(from: tsStr) {
            timestamp = Int(date.timeIntervalSince1970)
        } else {
            timestamp = Int(Date().timeIntervalSince1970)
        }
        
        return EpisodeAction(
            podcast: podcast,
            episode: episode,
            guid: json["guid"] as? String,
            action: action,
            timestamp: timestamp,
            position: json["position"] as? Int,
            started: json["started"] as? Int,
            total: json["total"] as? Int,
            device: json["device"] as? String
        )
    }
    
    /// Copy this action but preserve the device field from an existing action
    /// when this action's device is nil. Used by the echo guard to prevent
    /// losing the local device stamp when the server echoes back our action
    /// without a device field.
    func preservingDevice(from existing: EpisodeAction) -> EpisodeAction {
        EpisodeAction(
            podcast: podcast,
            episode: episode,
            guid: guid,
            action: action,
            timestamp: timestamp,
            position: position,
            started: started,
            total: total,
            device: device ?? existing.device
        )
    }
}

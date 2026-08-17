import Foundation
import CryptoKit

/// Deterministic download filenames + orphan-file detection for the watch.
/// hashValue is process-seeded — using it for filenames meant a re-download
/// after relaunch produced a second copy of the same episode.
enum WatchDownloadHygiene {

    static func filename(forEpisodeId episodeId: String) -> String {
        let sanitized = episodeId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if sanitized.count <= 100 {
            return "\(sanitized).mp3"
        }
        let digest = SHA256.hash(data: Data(episodeId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return "episode_\(hex).mp3"
    }

    /// Files that no episode references and no download is producing.
    static func orphans(existingFiles: [String], referenced: Set<String>) -> [String] {
        existingFiles.filter { $0.hasSuffix(".mp3") && !referenced.contains($0) }
    }
}

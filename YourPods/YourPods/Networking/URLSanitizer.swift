import Foundation
import os

/// Centralized URL sanitization for user-entered URLs (gPodder servers, podcast feeds).
/// Defaults bare domains to HTTPS. Preserves explicit HTTP (user may need it for
/// self-hosted servers) but provides detection so the UI can warn.
enum URLSanitizer {
    private static let logger = Logger(subsystem: "com.yourpods", category: "URLSanitizer")
    
    /// Sanitize a user-entered URL:
    /// - Trims whitespace
    /// - Strips trailing "/"
    /// - Defaults bare domains (no scheme) to "https://"
    /// - Preserves explicit "http://" or "https://"
    /// - Logs a warning when HTTP is detected
    static func sanitize(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("/") { result = String(result.dropLast()) }
        
        let lower = result.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            result = "https://\(result)"
        }
        
        if isInsecure(result) {
            logger.warning("Insecure HTTP URL detected: \(result, privacy: .private). Credentials and data will be sent unencrypted.")
        }
        
        return result
    }
    
    /// Returns `true` if the URL uses plain HTTP (not HTTPS).
    static func isInsecure(_ url: String) -> Bool {
        url.lowercased().hasPrefix("http://")
    }
    
    // DESIGN DECISION: HTTP is intentionally allowed for gPodder and podcast servers.
    // Many users self-host on local networks (e.g., http://192.168.1.50/nextcloud)
    // without TLS. We default bare URLs to HTTPS via sanitize(), and the UI shows a
    // warning when HTTP is used, but we do NOT reject HTTP connections.
    // Do NOT add HTTPS enforcement or make GPodderClient.init throwing for this reason.
    
    /// Returns the HTTPS equivalent of an HTTP URL, or `nil` if the URL
    /// is already HTTPS or has no explicit HTTP scheme.
    /// Used by the UI to offer a one-tap "Switch to HTTPS" suggestion.
    static func suggestedHTTPSURL(_ url: String) -> String? {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") else { return nil }
        // Replace the scheme prefix (case-insensitive) with https://
        return "https://" + url.dropFirst("http://".count)
    }
}

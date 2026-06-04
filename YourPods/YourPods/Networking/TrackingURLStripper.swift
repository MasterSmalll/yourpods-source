import Foundation
import os

/// Result of stripping tracking/ad-insertion prefixes from a podcast episode URL.
struct StrippedURLResult: Equatable {
    /// The cleaned URL (or original if no trackers found).
    let url: String
    /// Names of tracking/DAI services that were removed.
    let trackersRemoved: [String]
    /// True if tracking query parameters were stripped.
    let queryParamsStripped: Bool
    /// True if any stripping occurred.
    var wasModified: Bool { !trackersRemoved.isEmpty || queryParamsStripped }

    init(url: String, trackersRemoved: [String], queryParamsStripped: Bool = false) {
        self.url = url
        self.trackersRemoved = trackersRemoved
        self.queryParamsStripped = queryParamsStripped
    }
}

/// P3 — Privacy Preserving Playback: client-side URL de-tracking.
///
/// Strips known tracking and dynamic ad-insertion prefixes from podcast episode
/// URLs so the user's device never contacts those services.
///
/// Podcast episode URLs are often wrapped in multiple tracking layers:
/// ```
/// https://pdst.fm/e/chrt.fm/track/1234/dts.podtrac.com/redirect.mp3/cdn.example.com/ep.mp3
/// ```
/// This service extracts the innermost CDN URL without making any network requests.
///
/// **Design**: The pattern list is static and easily extensible. Adding a new tracker
/// is a single entry in the `prefixPatterns` array — no architecture changes needed.
enum TrackingURLStripper {
    private static let logger = Logger(subsystem: "com.yourpods", category: "TrackingURLStripper")

    // MARK: - Tracker Prefix Patterns

    /// A known tracking/DAI prefix pattern.
    ///
    /// Each pattern describes how a tracking service wraps the actual audio URL:
    /// - `host`: The domain of the tracking service (matched case-insensitively).
    /// - `pathPrefix`: A regex pattern matching the service's path prefix. The captured
    ///   URL (everything AFTER this prefix) is the next layer or the final CDN URL.
    /// - `name`: Human-readable name for logging and UI.
    private struct PrefixPattern {
        let host: String
        let pathPrefixRegex: NSRegularExpression
        let name: String

        init(host: String, pathPrefix: String, name: String) {
            self.host = host
            // The regex matches from the start of the path. The part after the match
            // is the embedded URL (without scheme).
            // swiftlint:disable:next force_try
            self.pathPrefixRegex = try! NSRegularExpression(pattern: "^" + pathPrefix, options: [])
            self.name = name
        }
    }

    /// All known prefix-style tracking and DAI patterns.
    ///
    /// **Prefix-style** means the tracking URL wraps the actual URL as its path suffix:
    /// `https://tracker.example/prefix/<actual_url_without_scheme>`
    ///
    /// Order doesn't matter — we iterate until no more patterns match.
    private static let prefixPatterns: [PrefixPattern] = [
        // ── Analytics / Download Tracking ───────────────────────────────────
        PrefixPattern(host: "dts.podtrac.com",       pathPrefix: "/redirect\\.[a-zA-Z0-9]+/",  name: "Podtrac"),
        PrefixPattern(host: "play.podtrac.com",      pathPrefix: "/redirect\\.[a-zA-Z0-9]+/",  name: "Podtrac"),
        PrefixPattern(host: "chrt.fm",               pathPrefix: "/track/[^/]+/",               name: "Chartable"),
        PrefixPattern(host: "chtbl.com",             pathPrefix: "/track/[^/]+/",               name: "Chartable"),
        PrefixPattern(host: "pdst.fm",               pathPrefix: "/e/",                         name: "Podsights"),
        PrefixPattern(host: "prfx.byspotify.com",   pathPrefix: "/e/",                         name: "Podsights"),
        PrefixPattern(host: "op3.dev",               pathPrefix: "/e/",                         name: "OP3"),
        PrefixPattern(host: "mgln.ai",               pathPrefix: "/e/",                         name: "Magellan AI"),
        PrefixPattern(host: "verifi.podscribe.com",  pathPrefix: "/rss/p/",                     name: "Podscribe"),
        PrefixPattern(host: "pscrb.fm",              pathPrefix: "/e/",                         name: "Podscribe"),
        PrefixPattern(host: "claritaspod.com",       pathPrefix: "/measure/",                   name: "Claritas"),
        PrefixPattern(host: "www.claritaspod.com",   pathPrefix: "/measure/",                   name: "Claritas"),
        PrefixPattern(host: "prefix.artsai.com",     pathPrefix: "/e/",                         name: "ArtsAI"),
        PrefixPattern(host: "artsai.com",            pathPrefix: "/e/",                         name: "ArtsAI"),
        PrefixPattern(host: "2.gum.fm",              pathPrefix: "/[^/]+/",                     name: "Gumshoe"),
        PrefixPattern(host: "pdcn.co",               pathPrefix: "/e/",                         name: "Podcorn"),
        PrefixPattern(host: "backtracks.fm",         pathPrefix: "/e/",                         name: "Backtracks"),
        PrefixPattern(host: "pdrl.fm",               pathPrefix: "/e/",                         name: "PodRoll"),
        PrefixPattern(host: "podroll.fm",            pathPrefix: "/e/",                         name: "PodRoll"),
        PrefixPattern(host: "rss.pdrl.fm",           pathPrefix: "/e/",                         name: "PodRoll"),
        PrefixPattern(host: "cohst.app",             pathPrefix: "/e/",                         name: "CoHost"),
        PrefixPattern(host: "cohostpodcasting.com",  pathPrefix: "/e/",                         name: "CoHost"),
        PrefixPattern(host: "prefix.up.audio",       pathPrefix: "/[^/]+/",                     name: "Up.Audio"),
        PrefixPattern(host: "adbarker.com",          pathPrefix: "/e/",                         name: "AdBarker"),
        PrefixPattern(host: "veritonic.com",         pathPrefix: "/e/",                         name: "Veritonic"),
        PrefixPattern(host: "swap.fm",               pathPrefix: "/track/[^/]+/",               name: "Swap.fm"),
        PrefixPattern(host: "tracking.swap.fm",      pathPrefix: "/track/[^/]+/",               name: "Swap.fm"),
        PrefixPattern(host: "pfx.vpixl.com",         pathPrefix: "/[^/]+/",                     name: "vPixl"),

        // ── Dynamic Content Insertion ───────────────────────────────────────
        // These services insert dynamic content into the audio stream at
        // request time. Resolving through them returns the original CDN URL.
        PrefixPattern(host: "traffic.megaphone.fm",  pathPrefix: "/[^/]+/",                     name: "Megaphone"),
        PrefixPattern(host: "adswizz.com",           pathPrefix: "/e/",                         name: "AdsWizz"),
        PrefixPattern(host: "pcm.adswizz.com",       pathPrefix: "/e/",                         name: "AdsWizz"),
    ]

    // MARK: - Tracking Query Parameters

    /// Known tracking query parameter prefixes that are safe to strip.
    /// These are analytics/attribution params — removing them does not affect playback.
    private static let trackingQueryParamPrefixes: [String] = [
        "utm_",       // Google Analytics / Urchin Tracking Module
    ]

    // MARK: - Public API

    /// Strip all known tracking/DAI prefixes from a podcast episode URL.
    ///
    /// Iteratively removes known prefix patterns until no more are found,
    /// handling nested tracking wrappers (e.g., Podsights → Chartable → Podtrac → CDN).
    ///
    /// - Parameter url: The original episode URL from the RSS feed.
    /// - Returns: A `StrippedURLResult` with the cleaned URL and metadata.
    static func strip(_ url: String) -> StrippedURLResult {
        // Guard: skip empty strings and local file paths
        guard !url.isEmpty, !url.hasPrefix("/") else {
            return StrippedURLResult(url: url, trackersRemoved: [])
        }

        var currentUrl = url
        var removedTrackers: [String] = []
        var didStrip = true

        // Iterate until no more patterns match (handles nested wrappers)
        while didStrip {
            didStrip = false
            for pattern in prefixPatterns {
                if let stripped = tryStrip(currentUrl, with: pattern) {
                    removedTrackers.append(pattern.name)
                    currentUrl = stripped
                    didStrip = true
                    break  // Restart loop — new URL might match a different pattern
                }
            }
        }

        if !removedTrackers.isEmpty {
            logger.debug("P3 stripped [\(removedTrackers.joined(separator: ", "))] → \(currentUrl)")
        }

        // Phase 2: Strip known tracking query parameters (e.g., utm_*)
        let queryResult = stripTrackingQueryParams(from: currentUrl)
        if queryResult.didStrip {
            currentUrl = queryResult.url
            logger.debug("P3 stripped tracking query params → \(currentUrl)")
        }

        return StrippedURLResult(url: currentUrl, trackersRemoved: removedTrackers, queryParamsStripped: queryResult.didStrip)
    }

    // MARK: - Private

    /// Attempt to strip a single tracker prefix from a URL.
    ///
    /// - Returns: The embedded URL (with `https://` scheme) if the pattern matched, or `nil`.
    private static func tryStrip(_ urlString: String, with pattern: PrefixPattern) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == pattern.host,
              let path = components.path.isEmpty ? nil : components.path else {
            return nil
        }

        let nsPath = path as NSString
        let range = NSRange(location: 0, length: nsPath.length)

        guard let match = pattern.pathPrefixRegex.firstMatch(in: path, options: [], range: range) else {
            return nil
        }

        // Everything after the matched prefix is the embedded URL (without scheme)
        let remainder = nsPath.substring(from: match.range.upperBound)

        guard !remainder.isEmpty else { return nil }

        // The embedded URL typically has no scheme — prepend https://
        // Unless it already starts with http:// or https://
        if remainder.lowercased().hasPrefix("http://") || remainder.lowercased().hasPrefix("https://") {
            return remainder
        }

        return "https://" + remainder
    }

    // MARK: - Query Parameter Stripping

    /// Result of stripping tracking query parameters.
    private struct QueryStripResult {
        let url: String
        let didStrip: Bool
    }

    /// Strip known tracking query parameters from a URL.
    ///
    /// Removes parameters whose names start with known tracking prefixes (e.g., `utm_`).
    /// Non-tracking parameters (e.g., `token`, `expires`) are preserved.
    ///
    /// - Parameter url: The URL to strip query parameters from.
    /// - Returns: A `QueryStripResult` with the cleaned URL and whether stripping occurred.
    private static func stripTrackingQueryParams(from url: String) -> QueryStripResult {
        guard var components = URLComponents(string: url),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return QueryStripResult(url: url, didStrip: false)
        }

        let cleanedItems = queryItems.filter { item in
            !trackingQueryParamPrefixes.contains { prefix in
                item.name.lowercased().hasPrefix(prefix)
            }
        }

        // If no items were removed, return original
        guard cleanedItems.count < queryItems.count else {
            return QueryStripResult(url: url, didStrip: false)
        }

        // If all items were tracking params, remove the query string entirely
        components.queryItems = cleanedItems.isEmpty ? nil : cleanedItems
        let result = components.string ?? url
        return QueryStripResult(url: result, didStrip: true)
    }
}

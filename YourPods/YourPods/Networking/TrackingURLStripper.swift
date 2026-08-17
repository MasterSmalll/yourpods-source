import Foundation
import os

/// Result of stripping tracking/ad-insertion prefixes from a podcast episode URL.
struct StrippedURLResult: Equatable {
    /// The cleaned URL (or original if no trackers found).
    let url: String
    /// Names of tracking services that were removed.
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

/// Marker type so `Bundle(for:)` resolves the bundle that ships the tracker JSON
/// (the app/framework bundle, in both the app process and the app-hosted test runner).
final class TrackingURLStripperBundleToken {}

/// P3 — Privacy Preserving Playback: client-side URL de-tracking.
///
/// Strips known tracking/attribution redirect prefixes from podcast episode URLs so
/// the device never contacts those services. The pattern set is data-driven (OPAWG
/// snapshot + curated supplemental — see the `Resources/` JSON); a single generic
/// extractor matches a known tracker host, then locates the embedded audio URL by
/// scanning the path.
///
/// `opawg-prefixes.snapshot.json` is a snapshot of https://github.com/opawg/podcast-prefixes
/// (MIT), reproduced under its licence — see `NOTICE.md`. Its `notes` fields are the
/// upstream maintainers' commentary, not ours.
///
/// Podcast episode URLs are often wrapped in multiple tracking layers:
/// ```
/// https://pdst.fm/e/chrt.fm/track/1234/dts.podtrac.com/redirect.mp3/cdn.example.com/ep.mp3
/// ```
/// This service extracts the innermost CDN URL without making any network requests.
///
/// Dynamic Ad Insertion (DAI) is deliberately NOT handled: stitched ads are baked into
/// the audio file served from the same host, so there is no inner URL to reveal — P3 is
/// a privacy tool, not an ad-blocker.
enum TrackingURLStripper {
    private static let logger = Logger(subsystem: "com.yourpods", category: "TrackingURLStripper")

    // MARK: - Pattern model

    /// How a pattern matches a URL host.
    enum HostMatch: Equatable {
        case exact(String)    // host == value (case-insensitive)
        case suffix(String)   // host == base OR host ends with ".base" (OPAWG ".gum.fm" form)
    }

    /// A known tracking prefix, matched by host. The embedded audio URL is found by
    /// scanning the path — no per-service path regex is needed.
    struct PrefixPattern: Equatable {
        let name: String
        let match: HostMatch

        func matches(host: String) -> Bool {
            let h = host.lowercased()
            switch match {
            case .exact(let v):
                return h == v.lowercased()
            case .suffix(let base):
                let b = base.lowercased()
                return h == b || h.hasSuffix("." + b)
            }
        }
    }

    // MARK: - Tracking query parameters (code-defined; survive a snapshot-load failure)

    /// Param-name prefixes to strip (case-insensitive).
    private static let trackingQueryParamPrefixes: [String] = ["utm_"]
    /// Exact param names to strip (compared lowercased). AdsWizz attribution params.
    private static let trackingQueryParamNames: Set<String> = ["awcollectionid", "awepisodeid"]

    /// Final labels that must never be mistaken for an embedded host.
    private static let audioExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "ogg", "opus", "wav", "flac", "mp4"]

    // MARK: - Pattern source (data-driven, loaded once from the bundle)

    /// One OPAWG (or supplemental) registry entry. Extra OPAWG fields are ignored.
    struct OPAWGEntry: Decodable, Equatable {
        let prefixpattern: String
        let prefixname: String
        init(prefixpattern: String, prefixname: String) {
            self.prefixpattern = prefixpattern
            self.prefixname = prefixname
        }
    }

    /// All tracker patterns: the OPAWG snapshot merged with the curated supplemental
    /// (supplemental wins on host collision). Loaded once, cached for process lifetime.
    /// Degrades to `[]` (safe pass-through) if the bundled JSON is missing or malformed.
    static let patterns: [PrefixPattern] = loadPatterns()

    static func loadPatterns() -> [PrefixPattern] {
        let bundle = Bundle(for: TrackingURLStripperBundleToken.self)
        let snapshot = loadEntries(named: "opawg-prefixes.snapshot", in: bundle)
        let supplemental = loadEntries(named: "trackers-supplemental", in: bundle)
        return makePatterns(snapshot: snapshot, supplemental: supplemental)
    }

    private static func loadEntries(named name: String, in bundle: Bundle) -> [OPAWGEntry] {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            logger.error("P3: could not read \(name).json from bundle")
            return []
        }
        return decodeEntries(data)
    }

    static func decodeEntries(_ data: Data) -> [OPAWGEntry] {
        do {
            return try JSONDecoder().decode([OPAWGEntry].self, from: data)
        } catch {
            logger.error("P3: failed to decode tracker entries: \(error.localizedDescription)")
            return []
        }
    }

    /// Merge snapshot ∪ supplemental, deduped by host matcher; supplemental wins on collision.
    static func makePatterns(snapshot: [OPAWGEntry], supplemental: [OPAWGEntry]) -> [PrefixPattern] {
        var byKey: [String: PrefixPattern] = [:]
        var order: [String] = []
        for entry in snapshot + supplemental {   // supplemental last → overwrites on collision
            let pattern = map(entry)
            let key = dedupeKey(pattern.match)
            if byKey[key] == nil { order.append(key) }
            byKey[key] = pattern
        }
        return order.compactMap { byKey[$0] }
    }

    /// Map an OPAWG entry to a `PrefixPattern`. A leading "." means a subdomain-suffix match
    /// (OPAWG ".gum.fm" form); otherwise the host is everything up to the first "/".
    private static func map(_ entry: OPAWGEntry) -> PrefixPattern {
        let raw = entry.prefixpattern
        if raw.hasPrefix(".") {
            let afterDot = String(raw.dropFirst())
            let base = afterDot.split(separator: "/").first.map(String.init) ?? afterDot
            return PrefixPattern(name: entry.prefixname, match: .suffix(base))
        }
        let host = raw.split(separator: "/").first.map(String.init) ?? raw
        return PrefixPattern(name: entry.prefixname, match: .exact(host))
    }

    private static func dedupeKey(_ match: HostMatch) -> String {
        switch match {
        case .exact(let v): return "exact:" + v.lowercased()
        case .suffix(let b): return "suffix:" + b.lowercased()
        }
    }

    // MARK: - Public API

    /// Strip all known tracking prefixes from a podcast episode URL.
    ///
    /// Iteratively removes known prefix patterns until no more are found, handling nested
    /// tracking wrappers (e.g., Podsights → Chartable → Podtrac → CDN), then strips known
    /// tracking query parameters.
    ///
    /// - Parameter url: The original episode URL from the RSS feed.
    /// - Returns: A `StrippedURLResult` with the cleaned URL and metadata.
    static func strip(_ url: String) -> StrippedURLResult {
        // Guard: skip empty strings and local file paths
        guard !url.isEmpty, !url.hasPrefix("/") else {
            return StrippedURLResult(url: url, trackersRemoved: [])
        }

        var currentUrl = url
        var removed: [String] = []
        var didStrip = true

        // Iterate until no more patterns match (handles nested wrappers).
        while didStrip {
            didStrip = false
            guard let host = URLComponents(string: currentUrl)?.host?.lowercased() else { break }
            for pattern in patterns where pattern.matches(host: host) {
                if let inner = extractEmbeddedURL(from: currentUrl) {
                    removed.append(pattern.name)
                    currentUrl = inner
                    didStrip = true
                    break  // Restart loop — new URL might match a different pattern
                }
            }
        }

        if !removed.isEmpty {
            logger.debug("P3 stripped [\(removed.joined(separator: ", "))] → \(currentUrl)")
        }

        let q = stripTrackingQueryParams(from: currentUrl)
        if q.didStrip {
            currentUrl = q.url
            logger.debug("P3 stripped tracking query params → \(currentUrl)")
        }

        return StrippedURLResult(url: currentUrl, trackersRemoved: removed, queryParamsStripped: q.didStrip)
    }

    // MARK: - Embedded URL extraction

    /// For a URL whose host is a known tracker, find the embedded audio URL by scanning
    /// path segments for the first registrable domain (2+ labels, alphabetic TLD ≥2 chars,
    /// final label NOT an audio extension) that is followed by more path. Returns `nil` if
    /// none is found (the URL then passes through unchanged).
    private static func extractEmbeddedURL(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        let path = components.percentEncodedPath
        guard !path.isEmpty else { return nil }

        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        for (index, seg) in segments.enumerated() where index < segments.count - 1 {
            if isRegistrableDomain(seg) {
                let rest = segments[index...].joined(separator: "/")
                return appendQuery("https://" + rest, from: components)
            }
        }
        return nil
    }

    private static func appendQuery(_ base: String, from components: URLComponents) -> String {
        guard let q = components.percentEncodedQuery, !q.isEmpty else { return base }
        return base + "?" + q
    }

    /// A segment is a registrable domain if it has ≥2 dot-separated labels, an alphabetic
    /// TLD of ≥2 chars, and its final label is NOT an audio/media extension (so `redirect.mp3`
    /// is never mistaken for the embedded host).
    private static func isRegistrableDomain(_ segment: String) -> Bool {
        let hostPart = segment.split(separator: ":").first.map(String.init) ?? segment
        let labels = hostPart.split(separator: ".").map(String.init)
        guard labels.count >= 2, let tld = labels.last?.lowercased() else { return false }
        guard tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        if audioExtensions.contains(tld) { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    // MARK: - Query parameter stripping

    /// Strip known tracking query parameters. Removes params whose names start with a known
    /// tracking prefix (e.g. `utm_`) or exactly match a known tracking name; preserves
    /// non-tracking params (e.g. `token`, `expires`).
    private static func stripTrackingQueryParams(from url: String) -> (url: String, didStrip: Bool) {
        guard var components = URLComponents(string: url),
              let items = components.queryItems, !items.isEmpty else {
            return (url, false)
        }

        let cleaned = items.filter { item in
            let name = item.name.lowercased()
            if trackingQueryParamPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            if trackingQueryParamNames.contains(name) { return false }
            return true
        }

        guard cleaned.count < items.count else { return (url, false) }
        components.queryItems = cleaned.isEmpty ? nil : cleaned
        return (components.string ?? url, true)
    }
}

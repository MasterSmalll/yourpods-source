import Foundation
import os

/// Robust RSS/Atom feed date parser. One normalization pass + an ordered cascade
/// covering RFC822/2822, RFC3339/ISO8601, asctime, zoneless, and date-only forms.
/// Mirrors the multi-format strategy of ChapterService. Formatters are not
/// thread-safe; the RSS XMLParser runs single-threaded per parse, and these are
/// per-call locals, so there is no shared-state hazard.
enum FeedDateParser {
    private static let logger = Logger(subsystem: "com.yourpods", category: "sync")

    private static let namedZones: [String: String] = [
        "GMT": "+0000", "UT": "+0000", "UTC": "+0000", "Z": "+0000",
        "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500",
        "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700",
        "CET": "+0100", "CEST": "+0200",
    ]

    static func parse(_ raw: String) -> Date? {
        let s = normalize(raw)
        guard !s.isEmpty else { return nil }

        // 1. ISO8601 fast path (Atom + extended RSS).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        // 2-4. DateFormatter cascade (POSIX locale, GMT default for zoneless).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z",
            "EEE, d MMMM yyyy HH:mm:ss Z", "d MMM yy HH:mm:ss Z",
            "EEE, d MMM yyyy, HH:mm:ss Z", "EEE MMM d HH:mm:ss yyyy", // asctime
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd", // date-only — the qurangarden fix
        ]
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }

        // 5. Weekday-strip recursion (handles 4-letter weekdays / odd prefixes).
        if let comma = s.firstIndex(of: ","),
           s[..<comma].allSatisfy({ $0.isLetter }) {
            let tail = String(s[s.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            if tail != s { return parse(tail) }
        }

        logger.debug("FeedDateParser: unparsed date '\(raw, privacy: .public)'")
        return nil
    }

    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: #"\bSept\b"#, with: "Sep", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression) // trailing (zone)
        // Substitute a trailing named zone with a numeric offset.
        for (name, offset) in namedZones {
            if s.hasSuffix(" \(name)") {
                s = String(s.dropLast(name.count)) + offset
                break
            }
        }
        // Strip the colon from a trailing numeric offset (+02:00 -> +0200).
        s = s.replacingOccurrences(of: #"([+-]\d\d):(\d\d)$"#, with: "$1$2", options: .regularExpression)
        // Normalize a trailing fractional-second run to 3 digits.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = s[s.index(after: r.lowerBound)..<r.upperBound]
            let three = String((digits + "000").prefix(3))
            s.replaceSubrange(r, with: "." + three)
        }
        return s
    }
}

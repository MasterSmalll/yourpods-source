import Foundation
import os
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Transcript data model
struct Transcript {
    let items: [TranscriptItem]
    let type: String
}

/// The transcript formats we can parse.
///
/// The raw value is the canonical MIME type, and also the `Transcript.type` we report
/// back — except `.srt`, which reports `application/srt` for historical reasons.
enum TranscriptFormat: String, Sendable, CaseIterable {
    case plainText = "text/plain"
    case html = "text/html"
    case json = "application/json"
    case vtt = "text/vtt"
    case srt = "application/x-subrip"
    case markdown = "text/markdown"
    case rtf = "application/rtf"

    /// Match a feed's `type="..."`, tolerating MIME parameters and casing.
    static func forMimeType(_ raw: String?) -> TranscriptFormat? {
        guard let raw else { return nil }
        // "text/plain; charset=utf-8" -> "text/plain"
        let mime = raw.components(separatedBy: ";")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !mime.isEmpty else { return nil }
        switch mime {
        case "text/plain", "text/txt": return .plainText
        case "text/html", "application/xhtml+xml": return .html
        case "application/json": return .json
        case "text/vtt", "text/webvtt": return .vtt
        case "application/x-subrip", "application/srt", "text/srt": return .srt
        case "text/markdown", "text/x-markdown": return .markdown
        case "application/rtf", "text/rtf": return .rtf
        default: return nil
        }
    }

    /// Match a URL's path extension, ignoring query strings, fragments, and casing.
    ///
    /// Presigned CDN transcript URLs (`…/t.txt?token=…`) and extension-less REST
    /// endpoints are both routine, so this must never see the raw URL string.
    static func forURL(_ url: String) -> TranscriptFormat? {
        var path = url
        if var comps = URLComponents(string: url) {
            comps.query = nil
            comps.fragment = nil
            path = comps.path.isEmpty ? (comps.string ?? url) : comps.path
        } else if let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(url[url.startIndex..<cut])
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "txt", "text": return .plainText
        case "html", "htm", "xhtml": return .html
        case "json": return .json
        case "vtt": return .vtt
        case "srt": return .srt
        case "md", "markdown", "mdown": return .markdown
        case "rtf": return .rtf
        default: return nil
        }
    }

    /// Last resort when the feed declares nothing and the URL carries no extension.
    ///
    /// Defaults to `.plainText` rather than `.srt`: prose parsed as SRT yields zero
    /// items, and a zero-item transcript makes the Transcript button disappear.
    static func sniffing(_ content: String) -> TranscriptFormat {
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1024)
        if head.hasPrefix(#"{\rtf"#) { return .rtf }
        if head.hasPrefix("{") { return .json }
        if content.contains("WEBVTT") { return .vtt }
        if head.hasPrefix("<") || head.localizedCaseInsensitiveContains("<html") || head.contains("<p>") { return .html }
        if content.contains("-->") { return .srt }
        return .plainText
    }

    /// Resolution order: the feed's declared type, then the URL, then the bytes.
    static func detect(declaredType: String?, url: String, content: String) -> TranscriptFormat {
        forMimeType(declaredType) ?? forURL(url) ?? sniffing(content)
    }

    /// Whether a zero-item parse is worth retrying as plain text.
    ///
    /// True for the grammar-based formats: prose mislabelled as SubRip/WebVTT/JSON is
    /// still readable, so showing it beats showing nothing. False for the markup formats
    /// — they already terminate in the plain-text parser, so zero items there means there
    /// was genuinely no text, and retrying would present raw markup *as* the transcript.
    /// RTF sits between: retry only when the bytes aren't really RTF, so a corrupt-but-real
    /// RTF never spills control words.
    func retriesAsPlainText(given content: String) -> Bool {
        switch self {
        case .srt, .vtt, .json:
            return true
        case .rtf:
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(#"{\rtf"#)
        case .plainText, .html, .markdown:
            return false
        }
    }
}

struct TranscriptItem: Identifiable {
    let id = UUID()
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    
    var end: TimeInterval { start + duration }
}

/// Fetches and parses transcripts in SRT, VTT, JSON, plain text, and HTML formats.
actor TranscriptService {
    static let shared = TranscriptService()
    private let logger = Logger(subsystem: "com.yourpods", category: "TranscriptService")
    
    private var memoryCache: [String: Transcript] = [:]
    private let cacheDuration: TimeInterval = 24 * 3600
    
    /// A transcript's location and its declared format.
    struct Source: Equatable, Sendable {
        let url: String
        let type: String?
    }

    /// Picks the transcript to load, preferring the live `Episode` over a `QueueItem`'s
    /// enqueue-time snapshot.
    ///
    /// `QueueItem` freezes `transcriptUrl` when the episode is queued, but feeds routinely
    /// publish a transcript days after the episode itself. Trusting the snapshot means an
    /// episode queued before its transcript existed never shows one — no refresh fixes it,
    /// because the snapshot is what the player reads.
    nonisolated static func resolveSource(
        snapshotUrl: String?, snapshotType: String?,
        liveUrl: String?, liveType: String?
    ) -> Source? {
        if let liveUrl, !liveUrl.isEmpty {
            return Source(url: liveUrl, type: liveType)
        }
        if let snapshotUrl, !snapshotUrl.isEmpty {
            return Source(url: snapshotUrl, type: snapshotType)
        }
        return nil
    }

    /// Synchronous entry point for unit tests.
    static func parseContentSync(_ content: String, url: String, type: String?) -> Transcript {
        let instance = TranscriptService()
        // Actors require async context, but parsing is pure/sync — call the static helpers directly
        return instance.parseContentDirect(content, url: url, type: type)
    }
    
    func fetchTranscript(url: String, type: String? = nil) async -> Transcript? {
        // Memory cache
        if let cached = memoryCache[url] { return cached }
        
        // Disk cache
        let cacheFile = getCacheFile(for: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < cacheDuration,
           let content = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let transcript = parseContentDirect(content, url: url, type: type)
            memoryCache[url] = transcript
            return transcript
        }
        
        // Network
        guard let requestUrl = URL(string: url) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: requestUrl)
            guard let content = String(data: data, encoding: .utf8) else { return nil }
            try? content.write(to: cacheFile, atomically: true, encoding: .utf8)
            let transcript = parseContentDirect(content, url: url, type: type)
            memoryCache[url] = transcript
            return transcript
        } catch {
            logger.error("Failed to fetch transcript: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Parsing
    
    /// Core routing — determines format and dispatches to the right parser.
    /// `nonisolated` so it can be called from the static test helper without async.
    nonisolated func parseContentDirect(_ content: String, url: String, type: String?) -> Transcript {
        let format = TranscriptFormat.detect(declaredType: type, url: url, content: content)
        let transcript = parse(content, as: format)
        guard transcript.items.isEmpty, format.retriesAsPlainText(given: content) else { return transcript }

        // Backstop: a detection miss otherwise ends as a zero-item transcript, and the UI
        // gates the Transcript button on items.count > 0 — so a wrong guess makes the
        // button silently vanish. Showing readable text beats showing nothing.
        let fallback = parsePlainText(content)
        guard !fallback.items.isEmpty else { return transcript }
        logger.debug("Transcript parsed as \(format.rawValue, privacy: .public) yielded no items — falling back to plain text")
        return fallback
    }

    nonisolated private func parse(_ content: String, as format: TranscriptFormat) -> Transcript {
        switch format {
        case .json: return parseJSON(content)
        case .vtt: return parseVTT(content)
        case .plainText: return parsePlainText(content)
        case .html: return parseHTML(content)
        case .markdown: return parseMarkdown(content)
        case .rtf: return parseRTF(content)
        case .srt: return parseSRT(content)
        }
    }
    
    // MARK: - Plain Text Parser
    
    /// Parses plain text transcripts with optional `[HH:MM:SS]` timestamps.
    /// Segments are separated by blank lines. Each segment's timestamp comes from
    /// the first `[HH:MM:SS]` marker on its first line.
    /// If no timestamps are found, the entire text becomes a single item at 0:00.
    nonisolated func parsePlainText(_ content: String) -> Transcript {
        let timestampPattern = /\[(\d{1,2}:\d{2}:\d{2})\]/
        
        // Split into segments on blank lines
        let rawSegments = content.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Check if any segment has a timestamp
        let hasTimestamps = rawSegments.contains { $0.contains(timestampPattern) }
        
        guard hasTimestamps else {
            // No timestamps — single item with all text
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Transcript(items: [], type: "text/plain") }
            return Transcript(
                items: [TranscriptItem(text: text, start: 0, duration: 0)],
                type: "text/plain"
            )
        }
        
        // Parse each segment
        var items: [TranscriptItem] = []
        for segment in rawSegments {
            // Find the first timestamp in this segment
            guard let match = segment.firstMatch(of: timestampPattern) else { continue }
            let timeStr = String(match.1)
            let start = parseTimestamp(timeStr)
            
            // Clean the text: remove the leading [HH:MM:SS] but preserve inline ones and speaker labels
            let text = segment
                .replacing(/^\[(\d{1,2}:\d{2}:\d{2})\]\s*/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !text.isEmpty else { continue }
            items.append(TranscriptItem(text: text, start: start, duration: 0))
        }
        
        // Calculate durations from the gap between consecutive timestamps
        for i in 0..<items.count {
            if i + 1 < items.count {
                let duration = items[i + 1].start - items[i].start
                items[i] = TranscriptItem(text: items[i].text, start: items[i].start, duration: duration)
            } else {
                // Last item — default 30s duration
                items[i] = TranscriptItem(text: items[i].text, start: items[i].start, duration: 30)
            }
        }
        
        return Transcript(items: items, type: "text/plain")
    }
    
    // MARK: - HTML Parser
    
    /// Strips HTML markup, preserving paragraph boundaries as blank lines, then parses
    /// as plain text.
    ///
    /// Entities are decoded *after* tags are stripped. Decoding first would turn a
    /// literal `&lt;p&gt;` into `<p>` and then strip it as if it were real markup.
    nonisolated func parseHTML(_ content: String) -> Transcript {
        var result = content

        // Drop non-content elements wholesale. Stripping only their tags leaves the
        // <title>/CSS/JS *text* behind, which then reads as transcript body.
        for tag in ["head", "script", "style"] {
            result = Self.replacingMatches(
                in: result,
                pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: "",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        }

        // Block-level closes become segment boundaries; <br> becomes a line break.
        result = Self.replacingMatches(in: result, pattern: "</(?:p|div|li|h[1-6])>", with: "\n\n", options: .caseInsensitive)
        result = Self.replacingMatches(in: result, pattern: "<br\\s*/?>", with: "\n", options: .caseInsensitive)
        result = Self.replacingMatches(in: result, pattern: "<[^>]+>", with: "", options: [])

        let parsed = parsePlainText(Self.decodingHTMLEntities(result))
        // Preserve the HTML type marker
        return Transcript(items: parsed.items, type: "text/html")
    }

    // MARK: - Markdown Parser

    /// Strips Markdown syntax and parses the remainder as plain text.
    ///
    /// Deliberately not a full Markdown parser — transcripts only ever use a thin
    /// slice of it (headings, emphasis, links), and the timestamps are what matter.
    nonisolated func parseMarkdown(_ content: String) -> Transcript {
        var result = content
        // Links and images: [text](url) -> text. Before emphasis, since link text may carry it.
        result = Self.replacingMatches(in: result, pattern: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: [])
        // Fenced code blocks: drop the fences, keep the contents.
        result = Self.replacingMatches(in: result, pattern: "```[a-zA-Z0-9]*", with: "", options: [])
        // Headings and blockquote markers at line start.
        result = Self.replacingMatches(in: result, pattern: "^[ \\t]{0,3}#{1,6}[ \\t]*", with: "", options: .anchorsMatchLines)
        result = Self.replacingMatches(in: result, pattern: "^[ \\t]{0,3}>[ \\t]?", with: "", options: .anchorsMatchLines)
        // Emphasis. Paired-delimiter patterns so snake_case words survive.
        for pattern in [#"\*\*\*([^*]+)\*\*\*"#, #"\*\*([^*]+)\*\*"#, #"\*([^*\n]+)\*"#,
                        "___([^_]+)___", "__([^_]+)__", "_([^_\n]+)_"] {
            result = Self.replacingMatches(in: result, pattern: pattern, with: "$1", options: [])
        }
        result = result.replacingOccurrences(of: "`", with: "")

        let parsed = parsePlainText(result)
        return Transcript(items: parsed.items, type: TranscriptFormat.markdown.rawValue)
    }

    // MARK: - RTF Parser

    /// Decodes RTF to plain text via the system text importer, then parses it.
    ///
    /// Safe off the main thread: the RTF importer is the Cocoa text system, not the
    /// WebKit-backed HTML importer that Apple restricts to the main thread.
    nonisolated func parseRTF(_ content: String) -> Transcript {
        let rtfType = TranscriptFormat.rtf.rawValue
        guard let data = content.data(using: .utf8) else { return Transcript(items: [], type: rtfType) }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        guard let decoded = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            logger.error("Failed to decode RTF transcript")
            return Transcript(items: [], type: rtfType)
        }
        let parsed = parsePlainText(decoded.string)
        return Transcript(items: parsed.items, type: rtfType)
    }

    // MARK: - Text Helpers

    nonisolated private static func replacingMatches(
        in string: String, pattern: String, with template: String,
        options: NSRegularExpression.Options
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return string }
        return regex.stringByReplacingMatches(
            in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template
        )
    }

    /// Decodes named and numeric HTML entities.
    ///
    /// `&amp;` is decoded last: doing it first turns `&amp;lt;` into `&lt;` and then
    /// into `<`, corrupting text that legitimately shows escaped markup.
    nonisolated static func decodingHTMLEntities(_ string: String) -> String {
        var result = string
        let named: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
            ("&hellip;", "\u{2026}"), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}")
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = decodingNumericEntities(result)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Decodes `&#8217;` and `&#x2014;` style entities. Malformed ones are left alone.
    nonisolated private static func decodingNumericEntities(_ string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") else { return string }
        let source = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return string }

        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = !source.substring(with: match.range(at: 1)).isEmpty
            let digits = source.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                result += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
    
    private nonisolated func parseJSON(_ content: String) -> Transcript {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["segments"] as? [[String: Any]] else {
            return Transcript(items: [], type: "application/json")
        }
        
        let items = segments.compactMap { seg -> TranscriptItem? in
            guard let body = seg["body"] as? String,
                  let start = seg["startTime"] as? Double,
                  let end = seg["endTime"] as? Double else { return nil }
            return TranscriptItem(text: body, start: start, duration: end - start)
        }
        return Transcript(items: items, type: "application/json")
    }
    
    private nonisolated func parseSRT(_ content: String) -> Transcript {
        var items: [TranscriptItem] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            if Int(lines[i]) != nil { i += 1; continue }
            if lines[i].contains("-->") {
                let parts = lines[i].components(separatedBy: "-->")
                let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces))
                let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
                i += 1
                var text = ""
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    text += (text.isEmpty ? "" : "\n") + lines[i]
                    i += 1
                }
                items.append(TranscriptItem(text: text, start: start, duration: end - start))
            } else {
                i += 1
            }
        }
        return Transcript(items: items, type: "application/srt")
    }
    
    private nonisolated func parseVTT(_ content: String) -> Transcript {
        var items: [TranscriptItem] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            if lines[i] == "WEBVTT" || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1; continue
            }
            if lines[i].contains("-->") {
                let parts = lines[i].components(separatedBy: "-->")
                let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces))
                let endStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
                let end = parseTimestamp(endStr)
                i += 1
                var text = ""
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    text += (text.isEmpty ? "" : "\n") + lines[i]
                    i += 1
                }
                items.append(TranscriptItem(text: text, start: start, duration: end - start))
            } else {
                i += 1
            }
        }
        return Transcript(items: items, type: "text/vtt")
    }
    
    private nonisolated func parseTimestamp(_ ts: String) -> TimeInterval {
        let cleaned = ts.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        switch parts.count {
        case 3:
            let h = Double(parts[0]) ?? 0
            let m = Double(parts[1]) ?? 0
            let s = Double(parts[2]) ?? 0
            return h * 3600 + m * 60 + s
        case 2:
            let m = Double(parts[0]) ?? 0
            let s = Double(parts[1]) ?? 0
            return m * 60 + s
        default:
            return 0
        }
    }
    
    private func getCacheFile(for url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appendingPathComponent("transcript_\(hash).cache")
    }
}

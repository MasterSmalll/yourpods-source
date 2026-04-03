import Foundation
import os
import CryptoKit

/// Transcript data model
struct Transcript {
    let items: [TranscriptItem]
    let type: String
}

struct TranscriptItem: Identifiable {
    let id = UUID()
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    
    var end: TimeInterval { start + duration }
}

/// Fetches and parses transcripts in SRT, VTT, JSON, plain text, and HTML formats.
/// Port of transcript_service.dart.
actor TranscriptService {
    static let shared = TranscriptService()
    private let logger = Logger(subsystem: "com.yourpods", category: "TranscriptService")
    
    private var memoryCache: [String: Transcript] = [:]
    private let cacheDuration: TimeInterval = 24 * 3600
    
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
        var detectedType = type ?? ""
        if detectedType.isEmpty {
            if url.hasSuffix(".json") || content.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                detectedType = "application/json"
            } else if url.hasSuffix(".vtt") || content.contains("WEBVTT") {
                detectedType = "text/vtt"
            } else if url.hasSuffix(".txt") {
                detectedType = "text/plain"
            } else if url.hasSuffix(".html") || url.hasSuffix(".htm") {
                detectedType = "text/html"
            } else {
                detectedType = "application/x-subrip"
            }
        }
        
        switch detectedType {
        case "application/json": return parseJSON(content)
        case "text/vtt": return parseVTT(content)
        case "text/plain": return parsePlainText(content)
        case "text/html": return parseHTML(content)
        default: return parseSRT(content)
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
    
    /// Strips HTML tags and entities, preserving paragraph boundaries as blank
    /// lines, then parses as plain text.
    nonisolated func parseHTML(_ content: String) -> Transcript {
        var result = content
        // Decode common entities
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        
        // Replace block-level closing tags with double newlines to preserve segment boundaries
        if let blockRegex = try? NSRegularExpression(pattern: "</(?:p|div|li|h[1-6])>", options: .caseInsensitive) {
            result = blockRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n"
            )
        }
        
        // Replace <br> with single newline
        if let brRegex = try? NSRegularExpression(pattern: "<br\\s*/?>", options: .caseInsensitive) {
            result = brRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n"
            )
        }
        
        // Strip remaining HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            result = tagRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        
        let parsed = parsePlainText(result)
        // Preserve the HTML type marker
        return Transcript(items: parsed.items, type: "text/html")
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

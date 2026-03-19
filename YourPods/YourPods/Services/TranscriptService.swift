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

/// Fetches and parses transcripts in SRT, VTT, and Podcasting 2.0 JSON formats.
/// Port of transcript_service.dart.
actor TranscriptService {
    static let shared = TranscriptService()
    private let logger = Logger(subsystem: "com.yourpods", category: "TranscriptService")
    
    private var memoryCache: [String: Transcript] = [:]
    private let cacheDuration: TimeInterval = 24 * 3600
    
    func fetchTranscript(url: String, type: String? = nil) async -> Transcript? {
        // Memory cache
        if let cached = memoryCache[url] { return cached }
        
        // Disk cache
        let cacheFile = getCacheFile(for: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < cacheDuration,
           let content = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let transcript = parseContent(content, url: url, type: type)
            memoryCache[url] = transcript
            return transcript
        }
        
        // Network
        guard let requestUrl = URL(string: url) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: requestUrl)
            guard let content = String(data: data, encoding: .utf8) else { return nil }
            try? content.write(to: cacheFile, atomically: true, encoding: .utf8)
            let transcript = parseContent(content, url: url, type: type)
            memoryCache[url] = transcript
            return transcript
        } catch {
            logger.error("Failed to fetch transcript: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Parsing
    
    private func parseContent(_ content: String, url: String, type: String?) -> Transcript {
        var detectedType = type ?? ""
        if detectedType.isEmpty {
            if url.hasSuffix(".json") || content.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                detectedType = "application/json"
            } else if url.hasSuffix(".vtt") || content.contains("WEBVTT") {
                detectedType = "text/vtt"
            } else {
                detectedType = "application/x-subrip"
            }
        }
        
        switch detectedType {
        case "application/json": return parseJSON(content)
        case "text/vtt": return parseVTT(content)
        default: return parseSRT(content)
        }
    }
    
    private func parseJSON(_ content: String) -> Transcript {
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
    
    private func parseSRT(_ content: String) -> Transcript {
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
    
    private func parseVTT(_ content: String) -> Transcript {
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
    
    private func parseTimestamp(_ ts: String) -> TimeInterval {
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

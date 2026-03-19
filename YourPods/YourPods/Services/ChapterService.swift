import Foundation
import os
import CryptoKit

/// Fetches and caches Podcasting 2.0 chapters from external JSON URLs.
/// Port of chapter_service.dart.
actor ChapterService {
    static let shared = ChapterService()
    private let logger = Logger(subsystem: "com.yourpods", category: "ChapterService")
    
    private var memoryCache: [String: (chapters: [Chapter], fetchedAt: Date)] = [:]
    private let cacheDuration: TimeInterval = 24 * 3600  // 24 hours
    
    /// Fetch chapters from a Podcasting 2.0 chapters JSON URL.
    func fetchChapters(url: String) async -> [Chapter] {
        // 1. Memory cache
        if let cached = memoryCache[url], Date().timeIntervalSince(cached.fetchedAt) < cacheDuration {
            return cached.chapters
        }
        
        // 2. Disk cache
        let cacheFile = getCacheFile(for: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < cacheDuration,
           let data = try? Data(contentsOf: cacheFile) {
            let chapters = parseChaptersJSON(data)
            memoryCache[url] = (chapters, Date())
            return chapters
        }
        
        // 3. Network fetch
        guard let requestUrl = URL(string: url) else { return [] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: requestUrl)
            // Save to disk cache
            try? data.write(to: cacheFile)
            
            let chapters = parseChaptersJSON(data)
            memoryCache[url] = (chapters, Date())
            return chapters
        } catch {
            logger.error("Failed to fetch chapters from \(url): \(error.localizedDescription)")
            return []
        }
    }
    
    private func parseChaptersJSON(_ data: Data) -> [Chapter] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chaptersArray = json["chapters"] as? [[String: Any]] else {
                return []
            }
            
            return chaptersArray.compactMap { dict -> Chapter? in
                guard let startTime = dict["startTime"] as? Double else { return nil }
                return Chapter(
                    startTime: startTime,
                    title: (dict["title"] as? String) ?? "",
                    img: dict["img"] as? String,
                    url: dict["url"] as? String
                )
            }.sorted { $0.startTime < $1.startTime }
        } catch {
            logger.error("Error parsing chapters JSON: \(error.localizedDescription)")
            return []
        }
    }
    
    private func getCacheFile(for url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("chapters_\(hash).json")
    }
    
    
    // MARK: - Description-based Chapter Parsing
    
    /// Extract chapters from timestamp patterns embedded in an episode description.
    /// Supports formats like:
    ///   (00:00:00) Title
    ///   (05:48) Title
    ///   00:00 - Title
    ///   1:02:24 Title
    /// Returns an empty array if fewer than 2 timestamps are found (a single timestamp isn't useful as chapters).
    static func parseChaptersFromDescription(_ description: String) -> [Chapter] {
        // Strip HTML tags — convert block elements to newlines first, then remove remaining tags
        var cleaned = description
            .replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        
        // Match timestamps in various formats:
        // Group 1: timestamp (HH:MM:SS or MM:SS)
        // Group 2: title text (rest of line after separator)
        let pattern = #"(?:^|\n)\s*\(?(\d{1,2}:\d{2}:\d{2}|\d{1,2}:\d{2})\)?\s*[-–—]?\s*(.+?)(?:\n|$)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        
        let nsString = cleaned as NSString
        let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: nsString.length))
        
        let chapters: [Chapter] = matches.compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            
            let timestampStr = nsString.substring(with: match.range(at: 1))
            let title = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            
            // Skip URLs and non-chapter lines
            guard !title.hasPrefix("http"), !title.isEmpty else { return nil }
            
            let seconds = parseTimestamp(timestampStr)
            return Chapter(startTime: seconds, title: title, img: nil, url: nil)
        }
        
        // Need at least 2 timestamps to be useful as chapters
        return chapters.count >= 2 ? chapters : []
    }
    
    /// Convert "HH:MM:SS" or "MM:SS" to total seconds
    private static func parseTimestamp(_ str: String) -> Double {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
        case 2: return Double(parts[0] * 60 + parts[1])
        default: return 0
        }
    }
    
    func clearCache() {
        memoryCache.removeAll()
    }
}

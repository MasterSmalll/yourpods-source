import Foundation
import os

/// RSS feed parser and fetcher.
/// Uses XMLParser to parse RSS feeds with support for iTunes and Podcasting 2.0 namespaces.
/// Supports auth-required feeds via injected Basic auth headers.
actor RSSService {
    private let logger = Logger(subsystem: "com.yourpods", category: "RSSService")
    private let session: URLSession
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    /// Parse raw RSS feed data without network fetch. Useful for testing.
    static func parseFeedData(_ data: Data) throws -> (podcast: ParsedPodcast, episodes: [ParsedEpisode]) {
        let parser = RSSXMLParser(data: data)
        return try parser.parse()
    }
    
    /// Fetch and parse an RSS feed, returning podcast metadata and episodes.
    func fetchFeed(
        url feedUrl: String,
        authHeader: String? = nil
    ) async throws -> (podcast: ParsedPodcast, episodes: [ParsedEpisode]) {
        let sanitizedUrl = URLSanitizer.sanitize(feedUrl)
        guard let url = URL(string: sanitizedUrl) else {
            throw RSSError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await session.data(for: request)
        
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw RSSError.authRequired
                }
                throw RSSError.httpError(http.statusCode)
            }
        }
        
        let parser = RSSXMLParser(data: data)
        return try parser.parse()
    }
}

// MARK: - Parsed Models (intermediate, before SwiftData persistence)

struct ParsedPodcast {
    var title: String = ""
    var description: String?
    var logoUrl: String?
    var website: String?
    var author: String?
}

struct ParsedEpisode {
    var guid: String = ""
    var title: String = ""
    var description: String?
    var audioUrl: String?
    var pubDate: Date?
    var imageUrl: String?
    var durationSeconds: Int?
    var link: String?
    var chaptersUrl: String?
    var transcriptUrl: String?
}

// MARK: - XML Parser

/// Custom XMLParser delegate that handles RSS 2.0, iTunes, and Podcasting 2.0 namespaces.
private final class RSSXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    
    private var podcast = ParsedPodcast()
    private var episodes: [ParsedEpisode] = []
    
    private var currentEpisode: ParsedEpisode?
    private var currentText = ""
    private var isInChannel = false
    private var isInItem = false
    private var currentTranscriptType: String?  // track type for preference logic
    
    // Namespace URIs
    private let itunesNS = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    private let podcastNS = "https://podcastindex.org/namespace/1.0"
    
    init(data: Data) {
        self.data = data
    }
    
    func parse() throws -> (podcast: ParsedPodcast, episodes: [ParsedEpisode]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        
        guard parser.parse() else {
            throw RSSError.parseFailed(parser.parserError?.localizedDescription ?? "Unknown error")
        }
        
        return (podcast, episodes)
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        
        switch elementName {
        case "channel":
            isInChannel = true
            
        case "item":
            isInItem = true
            currentEpisode = ParsedEpisode()
            
        case "enclosure" where isInItem:
            // <enclosure url="..." type="audio/mpeg" />
            if let url = attributes["url"],
               let type = attributes["type"],
               type.hasPrefix("audio") {
                currentEpisode?.audioUrl = url
            }
            
        case "image" where isInItem && (namespaceURI == itunesNS || qualifiedName == "itunes:image"):
            // <itunes:image href="..." />
            if let href = attributes["href"] {
                currentEpisode?.imageUrl = href
            }
            
        case "image" where !isInItem && isInChannel && (namespaceURI == itunesNS || qualifiedName == "itunes:image"):
            // Channel-level <itunes:image href="..." />
            if let href = attributes["href"] {
                podcast.logoUrl = href
            }
            
        case "chapters" where isInItem && (namespaceURI == podcastNS || qualifiedName == "podcast:chapters"):
            // <podcast:chapters url="..." type="application/json+chapters" />
            if let url = attributes["url"] {
                currentEpisode?.chaptersUrl = url
            }
            
        case "transcript" where isInItem && (namespaceURI == podcastNS || qualifiedName == "podcast:transcript"):
            // <podcast:transcript url="..." type="text/srt" />
            // Prefer SRT > VTT > JSON when multiple transcript tags exist
            if let url = attributes["url"] {
                let type = attributes["type"] ?? ""
                let newPriority = transcriptPriority(type)
                let existingPriority = transcriptPriority(currentTranscriptType ?? "")
                if currentEpisode?.transcriptUrl == nil || newPriority > existingPriority {
                    currentEpisode?.transcriptUrl = url
                    currentTranscriptType = type
                }
            }
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if isInItem {
            switch elementName {
            case "title": currentEpisode?.title = text
            case "description", "summary": 
                if currentEpisode?.description == nil { currentEpisode?.description = text }
            case "encoded" where namespaceURI == "http://purl.org/rss/1.0/modules/content/" || qualifiedName == "content:encoded":
                // <content:encoded> — prefer over <description> since it usually has richer content
                currentEpisode?.description = text
            case "guid": currentEpisode?.guid = text
            case "link": currentEpisode?.link = text
            case "pubDate":
                currentEpisode?.pubDate = parseRSSDate(text)
            case "duration" where namespaceURI == itunesNS || qualifiedName == "itunes:duration":
                currentEpisode?.durationSeconds = parseDuration(text)
            case "item":
                if var episode = currentEpisode {
                    // Fallback: use audioUrl as guid if none provided
                    if episode.guid.isEmpty {
                        episode.guid = episode.audioUrl ?? UUID().uuidString
                    }
                    episodes.append(episode)
                }
                currentEpisode = nil
                currentTranscriptType = nil
                isInItem = false
            default: break
            }
        } else if isInChannel {
            switch elementName {
            case "title": podcast.title = text
            case "description":
                if podcast.description == nil { podcast.description = text }
            case "link": podcast.website = text
            case "author" where namespaceURI == itunesNS:
                podcast.author = text
            case "channel":
                isInChannel = false
            default: break
            }
        }
        
        currentText = ""
    }
    
    // MARK: - Helpers
    
    /// Returns a priority value for transcript formats: SRT > VTT > JSON > unknown
    private func transcriptPriority(_ type: String) -> Int {
        switch type {
        case "application/x-subrip", "application/srt": return 3
        case "text/vtt": return 2
        case "application/json": return 1
        default: return 0
        }
    }
    
    /// Parse RSS date strings (RFC 822 / RFC 2822)
    private func parseRSSDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Try multiple common RSS date formats
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        
        return ISO8601DateFormatter().date(from: string)
    }
    
    /// Parse iTunes duration strings: "HH:MM:SS", "MM:SS", or plain seconds
    private func parseDuration(_ text: String) -> Int? {
        // Plain seconds
        if let seconds = Int(text) { return seconds }
        
        // HH:MM:SS or MM:SS
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return nil
        }
    }
}

// MARK: - Errors

enum RSSError: LocalizedError {
    case invalidURL
    case authRequired
    case httpError(Int)
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid feed URL"
        case .authRequired: return "Feed requires authentication"
        case .httpError(let code): return "Feed request failed (\(code))"
        case .parseFailed(let msg): return "Failed to parse feed: \(msg)"
        }
    }
}

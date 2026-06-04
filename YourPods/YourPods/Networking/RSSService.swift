import Foundation
import os

private let rssLogger = Logger(subsystem: "com.yourpods", category: "RSSService")

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
        
        // Use a delegate that handles auth challenges and re-attaches
        // the Authorization header on redirects (URLSession strips it by default)
        let delegate = authHeader != nil ? FeedAuthDelegate(authHeader: authHeader!) : nil
        let (data, response) = try await session.data(for: request, delegate: delegate)
        
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

// MARK: - URLSession Delegate for Feed Auth

/// Handles HTTP authentication challenges and re-attaches the Authorization
/// header on redirects—URLSession strips it by default, which breaks many
/// password-protected feeds that redirect (e.g., HTTP→HTTPS).
private final class FeedAuthDelegate: NSObject, URLSessionTaskDelegate {
    private let authHeader: String
    
    init(authHeader: String) {
        self.authHeader = authHeader
    }
    
    // Re-attach the Authorization header when the server redirects
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirectedRequest = request
        redirectedRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        completionHandler(redirectedRequest)
    }
    
    // Respond to HTTP Basic/Digest auth challenges with our credentials
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle HTTP Basic/Digest — not server trust or other challenge types
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Parse username:password from the Basic auth header
        let base64 = authHeader.replacingOccurrences(of: "Basic ", with: "")
        guard let credData = Data(base64Encoded: base64),
              let credString = String(data: credData, encoding: .utf8) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        let parts = credString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        let credential = URLCredential(
            user: String(parts[0]),
            password: String(parts[1]),
            persistence: .forSession
        )
        completionHandler(.useCredential, credential)
    }
}

// MARK: - Parsed Models (intermediate, before SwiftData persistence)

struct ParsedPodcast: Sendable {
    var title: String = ""
    var description: String?
    var logoUrl: String?
    var website: String?
    var author: String?
    
    // RSS 2.0
    var language: String?
    var copyright: String?
    
    // iTunes 1.x
    var categories: [String] = []
    var subcategory: String?
    var explicit: Bool?
    var showType: String?
    var isComplete: Bool = false
    var newFeedUrl: String?
    
    // Podcasting 2.0
    var podcastGuid: String?
    var fundingUrl: String?
    var fundingLabel: String?
    var publisher: String?
    var supportsValue4Value: Bool = false
    var hasLiveItem: Bool = false
    var liveItemStatus: String?
    var liveItemStart: Date?
    var liveItemContentLink: String?
}

/// A single Podlove Simple Chapter parsed from inline `<psc:chapter>` XML.
struct InlineChapter: Sendable {
    let startTime: Double
    let title: String
    let href: String?
    let image: String?
}

struct ParsedEpisode: Sendable {
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
    
    // Podlove Simple Chapters (inline XML)
    var inlineChapters: [InlineChapter]?
    
    // iTunes 1.x / Podcasting 2.0
    var seasonNumber: Int?
    var seasonName: String?
    var episodeNumber: Double?
    var episodeDisplay: String?
    var episodeType: String?
    var explicit: Bool?
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
    private var isInLiveItem = false  // tracking podcast:liveItem context
    private var isInCategory = false  // tracking itunes:category nesting
    private var isInPSCChapters = false  // tracking psc:chapters context
    private var currentInlineChapters: [InlineChapter] = []
    
    /// Depth counter for skipping namespaced elements whose local names collide with
    /// core RSS 2.0 names (e.g. Acast's <podaccess:item> and <podaccess:channel>).
    /// When > 0, all element events are ignored until the skip block exits.
    private var skipDepth = 0
    
    // Namespace URIs
    private let itunesNS = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    private let podcastNS = "https://podcastindex.org/namespace/1.0"
    private let pscNS = "http://podlove.org/simple-chapters"
    
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
        
        // If we're inside a skipped namespaced block, just count depth so we know
        // when to exit. Don't process any element events inside the block.
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        
        // Detect elements whose local name matches a key RSS name but are in a
        // non-null namespace — these must be skipped to prevent content inside them
        // (like <itunes:title>) from polluting channel or episode state.
        // Example: Acast's <podaccess:item> wraps premium episodes and contains an
        // <itunes:title> that would otherwise overwrite the podcast channel title.
        let isNamespaced = !(namespaceURI == nil || namespaceURI!.isEmpty)
        let isNamespacedItemLike = isNamespaced && elementName == "item"
        if isNamespacedItemLike {
            skipDepth = 1
            return
        }
        
        switch elementName {
        case "channel":
            isInChannel = true
            
        case "item" where (namespaceURI == nil || namespaceURI!.isEmpty) && (qualifiedName == nil || qualifiedName == "item"):
            // Guard: Only treat core RSS 2.0 <item> as an episode entry point.
            // Namespaced elements like <podaccess:item> are already handled above
            // by the skipDepth mechanism before we even reach the switch.
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
            
        // MARK: iTunes 1.x tags
            
        case "category" where !isInItem && isInChannel && (namespaceURI == itunesNS || qualifiedName == "itunes:category"):
            // <itunes:category text="Technology">
            //   <itunes:category text="Podcasting" />
            // </itunes:category>
            if let text = attributes["text"] {
                if !isInCategory {
                    podcast.categories.append(text)
                    isInCategory = true
                } else {
                    podcast.subcategory = text
                }
            }
            
        // MARK: Podcasting 2.0 channel-level tags
            
        case "funding" where !isInItem && isInChannel && (namespaceURI == podcastNS || qualifiedName == "podcast:funding"):
            // <podcast:funding url="https://...">Support this show!</podcast:funding>
            if let url = attributes["url"] {
                podcast.fundingUrl = url
            }
            
        case "guid" where !isInItem && isInChannel && (namespaceURI == podcastNS || qualifiedName == "podcast:guid"):
            // <podcast:guid>... text content ...</podcast:guid>
            break  // text content handled in didEndElement
            
        case "value" where isInChannel && (namespaceURI == podcastNS || qualifiedName == "podcast:value"):
            // <podcast:value type="lightning" ...> — just flag presence
            podcast.supportsValue4Value = true
            
        case "liveItem" where isInChannel && (namespaceURI == podcastNS || qualifiedName == "podcast:liveItem"):
            // <podcast:liveItem status="live" start="..." end="...">
            podcast.hasLiveItem = true
            isInLiveItem = true
            podcast.liveItemStatus = attributes["status"]
            if let startStr = attributes["start"] {
                podcast.liveItemStart = parseISO8601(startStr)
            }
            
        case "contentLink" where isInLiveItem && (namespaceURI == podcastNS || qualifiedName == "podcast:contentLink"):
            // <podcast:contentLink href="https://...">Watch Live</podcast:contentLink>
            if let href = attributes["href"] {
                podcast.liveItemContentLink = href
            }
            
        // MARK: Podcasting 2.0 item-level tags
            
        case "season" where isInItem && (namespaceURI == podcastNS || qualifiedName == "podcast:season"):
            // <podcast:season name="Season Name">1</podcast:season>
            if let name = attributes["name"] {
                currentEpisode?.seasonName = name
            }
            // Number is text content, handled in didEndElement
            
        case "episode" where isInItem && (namespaceURI == podcastNS || qualifiedName == "podcast:episode"):
            // <podcast:episode display="S1E3">3</podcast:episode>
            if let display = attributes["display"] {
                currentEpisode?.episodeDisplay = display
            }
            // Number is text content, handled in didEndElement
            
        // MARK: Podlove Simple Chapters (inline XML)
            
        case "chapters" where isInItem && (namespaceURI == pscNS || qualifiedName == "psc:chapters"):
            // <psc:chapters> — begin collecting inline chapters
            isInPSCChapters = true
            currentInlineChapters = []
            
        case "chapter" where isInPSCChapters && (namespaceURI == pscNS || qualifiedName == "psc:chapter"):
            // <psc:chapter start="00:00:00.000" title="Intro" href="..." image="..." />
            if let startStr = attributes["start"], let title = attributes["title"] {
                // Guard: skip chapters with empty/unparseable timestamps instead of crashing
                guard let startTime = parsePodloveTimestamp(startStr) else {
                    rssLogger.warning("Skipping chapter '\(title)': unparseable start timestamp '\(startStr)'")
                    break
                }
                let chapter = InlineChapter(
                    startTime: startTime,
                    title: title,
                    href: attributes["href"],
                    image: attributes["image"]
                )
                currentInlineChapters.append(chapter)
            }
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        // If we're exiting a skipped namespaced block, decrement depth and return.
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        
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
                
            // iTunes 1.x item tags
            case "season" where namespaceURI == itunesNS || qualifiedName == "itunes:season":
                if let num = Int(text) { currentEpisode?.seasonNumber = num }
            case "episode" where namespaceURI == itunesNS || qualifiedName == "itunes:episode":
                if let num = Double(text) { currentEpisode?.episodeNumber = num }
            case "episodeType" where namespaceURI == itunesNS || qualifiedName == "itunes:episodeType":
                currentEpisode?.episodeType = text.lowercased()
            case "explicit" where namespaceURI == itunesNS || qualifiedName == "itunes:explicit":
                currentEpisode?.explicit = parseExplicit(text)
                
            // Podcasting 2.0 item tags (text content)
            case "season" where namespaceURI == podcastNS || qualifiedName == "podcast:season":
                if let num = Int(text) { currentEpisode?.seasonNumber = num }
            case "episode" where namespaceURI == podcastNS || qualifiedName == "podcast:episode":
                if let num = Double(text) { currentEpisode?.episodeNumber = num }
                
            // Podlove Simple Chapters end
            case "chapters" where namespaceURI == pscNS || qualifiedName == "psc:chapters":
                if !currentInlineChapters.isEmpty {
                    currentEpisode?.inlineChapters = currentInlineChapters
                }
                isInPSCChapters = false
                currentInlineChapters = []
                
            case "item" where (namespaceURI == nil || namespaceURI!.isEmpty) && (qualifiedName == nil || qualifiedName == "item"):
                // Mirror of the start-element guard: only close item-parsing mode for
                // core RSS 2.0 </item>. Namespaced closers like </podaccess:item> are ignored.
                if var episode = currentEpisode {
                    // Fallback: use audioUrl as guid if none provided
                    if episode.guid.isEmpty {
                        episode.guid = episode.audioUrl ?? UUID().uuidString
                    }
                    episodes.append(episode)
                }
                currentEpisode = nil
                currentTranscriptType = nil
                isInPSCChapters = false
                currentInlineChapters = []
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
            case "language": podcast.language = text
            case "copyright": podcast.copyright = text
                
            // iTunes 1.x channel tags
            case "explicit" where namespaceURI == itunesNS || qualifiedName == "itunes:explicit":
                podcast.explicit = parseExplicit(text)
            case "type" where namespaceURI == itunesNS || qualifiedName == "itunes:type":
                podcast.showType = text.lowercased()
            case "complete" where namespaceURI == itunesNS || qualifiedName == "itunes:complete":
                podcast.isComplete = text.lowercased() == "yes"
            case "new-feed-url" where namespaceURI == itunesNS || qualifiedName == "itunes:new-feed-url":
                podcast.newFeedUrl = text
            case "category" where namespaceURI == itunesNS || qualifiedName == "itunes:category":
                isInCategory = false
                
            // Podcasting 2.0 channel tags (text content)
            case "guid" where namespaceURI == podcastNS || qualifiedName == "podcast:guid":
                podcast.podcastGuid = text
            case "funding" where namespaceURI == podcastNS || qualifiedName == "podcast:funding":
                if !text.isEmpty { podcast.fundingLabel = text }
            case "publisher" where namespaceURI == podcastNS || qualifiedName == "podcast:publisher":
                podcast.publisher = text
            case "liveItem" where namespaceURI == podcastNS || qualifiedName == "podcast:liveItem":
                isInLiveItem = false
                
            case "channel":
                isInChannel = false
            default: break
            }
        }
        
        currentText = ""
    }
    
    // MARK: - Helpers
    
    /// Returns a priority value for transcript formats: SRT > VTT > JSON > plain/html > unknown
    private func transcriptPriority(_ type: String) -> Int {
        switch type {
        case "application/x-subrip", "application/srt": return 4
        case "text/vtt": return 3
        case "application/json": return 2
        case "text/plain", "text/html": return 1
        default: return 0
        }
    }
    
    /// Parse itunes:explicit values: "yes"/"true"/"explicit" → true, others → false
    private func parseExplicit(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        return lower == "yes" || lower == "true" || lower == "explicit"
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
    
    /// Parse ISO 8601 dates with optional fractional seconds.
    /// Handles dates like "2024-09-26T07:30:00.000-0600" where the default
    /// ISO8601DateFormatter fails because it doesn't expect milliseconds.
    private func parseISO8601(_ string: String) -> Date? {
        // Try with fractional seconds first (most common in podcast feeds)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        // Fall back to standard ISO 8601
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
    
    /// Parse Podlove NPT (Normal Play Time) timestamps: "HH:MM:SS.mmm", "HH:MM:SS", "MM:SS"
    /// Returns nil for empty or unparseable input instead of crashing.
    private func parsePodloveTimestamp(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Guard: empty or whitespace-only strings have no timestamp to parse
        guard !trimmed.isEmpty else {
            rssLogger.debug("parsePodloveTimestamp called with empty string")
            return nil
        }
        
        // Split off optional milliseconds
        let parts = trimmed.split(separator: ".")
        // Guard: split can return empty if input is just dots
        guard let firstPart = parts.first else {
            rssLogger.debug("parsePodloveTimestamp: no segments in '\(text)'")
            return nil
        }
        let timePart = String(firstPart)
        let millis = parts.count > 1 ? (Double("0." + parts[1]) ?? 0) : 0
        
        let segments = timePart.split(separator: ":").compactMap { Int($0) }
        switch segments.count {
        case 3: return Double(segments[0] * 3600 + segments[1] * 60 + segments[2]) + millis
        case 2: return Double(segments[0] * 60 + segments[1]) + millis
        case 1: return Double(segments[0]) + millis
        default: return millis > 0 ? millis : nil
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

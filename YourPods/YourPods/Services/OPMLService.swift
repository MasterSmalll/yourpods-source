import Foundation
import os

/// OPML import/export for podcast subscriptions.
struct OPMLService {
    private static let logger = Logger(subsystem: "com.yourpods", category: "OPML")
    
    /// Export subscriptions to an OPML XML string (legacy flat format).
    static func export(podcasts: [Podcast]) -> String {
        return export(podcasts: podcasts, groups: [], profileName: nil)
    }
    
    /// Export subscriptions with group nesting and yourpods: namespace attributes.
    static func export(podcasts: [Podcast], groups: [PodcastGroup], profileName: String? = nil) -> String {
        let title = escapeXML(profileName.map { "YourPods Subscriptions — \($0)" } ?? "YourPods Subscriptions")
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0" xmlns:yourpods="https://yourpods.app/opml">
          <head>
            <title>\(title)</title>
            <dateCreated>\(ISO8601DateFormatter().string(from: Date()))</dateCreated>
          </head>
          <body>
        
        """
        
        // Index podcasts by groupId for efficient lookup
        let byGroup = Dictionary(grouping: podcasts.filter { $0.groupId != nil }, by: { $0.groupId! })
        let ungrouped = podcasts.filter { $0.groupId == nil }
        
        // Emit grouped podcasts inside nested outlines
        for group in groups.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let groupPodcasts = byGroup[group.id] ?? []
            guard !groupPodcasts.isEmpty else { continue }
            
            let escapedName = escapeXML(group.name)
            xml += "    <outline text=\"\(escapedName)\" title=\"\(escapedName)\">\n"
            for podcast in groupPodcasts {
                xml += "      \(podcastOutlineElement(podcast))\n"
            }
            xml += "    </outline>\n"
        }
        
        // Emit ungrouped podcasts at top level
        for podcast in ungrouped {
            xml += "    \(podcastOutlineElement(podcast))\n"
        }
        
        xml += """
          </body>
        </opml>
        """
        
        return xml
    }
    
    /// Build an <outline> element for a single podcast, including yourpods: attributes.
    private static func podcastOutlineElement(_ podcast: Podcast) -> String {
        let escapedTitle = escapeXML(podcast.title)
        let url = escapeXML(podcast.url)
        var attrs = "type=\"rss\" text=\"\(escapedTitle)\" title=\"\(escapedTitle)\" xmlUrl=\"\(url)\""
        
        // Append yourpods: namespace attributes from Listening Profile
        if let settings = podcast.settings {
            if let speed = settings.playbackSpeed {
                attrs += " yourpods:playbackSpeed=\"\(speed)\""
            }
            if let skipIntro = settings.skipIntroSeconds {
                attrs += " yourpods:skipIntro=\"\(skipIntro)\""
            }
            if let skipOutro = settings.skipOutroSeconds {
                attrs += " yourpods:skipOutro=\"\(skipOutro)\""
            }
            if let aqm = settings.autoQueueMode {
                attrs += " yourpods:autoQueueMode=\"\(aqm.rawValue)\""
            }
            if let autoDown = settings.autoDownloadNewEpisodes {
                attrs += " yourpods:autoDownload=\"\(autoDown)\""
            }
            if let cleanup = settings.downloadCleanupPolicy {
                attrs += " yourpods:downloadCleanup=\"\(cleanup.rawValue)\""
            }
        }
        
        return "<outline \(attrs)/>"
    }
    
    /// Parse an OPML file and return a list of feed URLs (legacy, flat).
    static func parseURLs(from data: Data) -> [String] {
        let parser = OPMLParser(data: data)
        return parser.parse()
    }
    
    /// Parse OPML with group hierarchy and yourpods: namespace attributes.
    /// Returns groups, grouped URLs, ungrouped URLs, and per-podcast settings.
    static func parseWithGroups(from data: Data) -> OPMLImportResult {
        let parser = OPMLGroupParser(data: data)
        return parser.parse()
    }
    
    static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Result of parsing an enriched OPML file with group and settings data.
struct OPMLImportResult {
    /// Parsed podcast groups from nested outlines.
    let groups: [PodcastGroup]
    /// Map of group name → feed URLs within that group.
    let groupedUrls: [String: [String]]
    /// Feed URLs that are not inside any group.
    let ungroupedUrls: [String]
    /// Map of feed URL → parsed PodcastSettings from yourpods: attributes.
    let podcastSettings: [String: PodcastSettings]
}

// MARK: - Legacy Flat OPML Parser

private final class OPMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var urls: [String] = []
    
    init(data: Data) {
        self.data = data
    }
    
    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return urls
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "outline",
           let xmlUrl = attributes["xmlUrl"], !xmlUrl.isEmpty {
            urls.append(xmlUrl)
        }
    }
}

// MARK: - Group-Aware OPML Parser

private final class OPMLGroupParser: NSObject, XMLParserDelegate {
    private let data: Data
    
    // Parsed results
    private var groups: [PodcastGroup] = []
    private var groupedUrls: [String: [String]] = [:]
    private var ungroupedUrls: [String] = []
    private var podcastSettings: [String: PodcastSettings] = [:]
    
    // Parser state — tracks nested outline depth
    private var currentGroupName: String? = nil
    private var groupSortOrder = 0
    
    init(data: Data) {
        self.data = data
    }
    
    func parse() -> OPMLImportResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return OPMLImportResult(
            groups: groups,
            groupedUrls: groupedUrls,
            ungroupedUrls: ungroupedUrls,
            podcastSettings: podcastSettings
        )
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard elementName == "outline" else { return }
        
        let xmlUrl = attributes["xmlUrl"]
        let text = attributes["text"] ?? attributes["title"]
        
        if let xmlUrl, !xmlUrl.isEmpty {
            // This is a feed outline — could be grouped or ungrouped
            if let groupName = currentGroupName {
                groupedUrls[groupName, default: []].append(xmlUrl)
            } else {
                ungroupedUrls.append(xmlUrl)
            }
            
            // Parse yourpods: namespace attributes
            let settings = parseYourPodsAttributes(from: attributes)
            if settings.hasOverrides {
                podcastSettings[xmlUrl] = settings
            }
        } else if let text, !text.isEmpty {
            // This is a group/folder outline (no xmlUrl, has text)
            currentGroupName = text
            let group = PodcastGroup(name: text, sortOrder: groupSortOrder)
            groups.append(group)
            groupSortOrder += 1
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "outline" && currentGroupName != nil {
            // Check if we're closing a group outline (not a feed inside it)
            // If the parser is closing the group-level outline, reset currentGroupName
            // XMLParser calls didEnd for every </outline>, so we track depth implicitly:
            // when there are no more feed outlines to close, this must be the group closing.
            // However, since feeds are self-closing (<outline ... />), didEnd is only called
            // for the group's closing </outline>.
            currentGroupName = nil
        }
    }
    
    /// Parse yourpods: namespace attributes from an outline element.
    private func parseYourPodsAttributes(from attributes: [String: String]) -> PodcastSettings {
        var settings = PodcastSettings()
        
        if let speedStr = attributes["yourpods:playbackSpeed"], let speed = Double(speedStr) {
            settings.playbackSpeed = speed
        }
        if let introStr = attributes["yourpods:skipIntro"], let intro = Int(introStr) {
            settings.skipIntroSeconds = intro
        }
        if let outroStr = attributes["yourpods:skipOutro"], let outro = Int(outroStr) {
            settings.skipOutroSeconds = outro
        }
        if let aqmStr = attributes["yourpods:autoQueueMode"], let aqm = AutoQueueMode(rawValue: aqmStr) {
            settings.autoQueueMode = aqm
        }
        if let autoDownStr = attributes["yourpods:autoDownload"] {
            settings.autoDownloadNewEpisodes = autoDownStr == "true"
        }
        if let cleanupStr = attributes["yourpods:downloadCleanup"], let cleanup = DownloadCleanupPolicy(rawValue: cleanupStr) {
            settings.downloadCleanupPolicy = cleanup
        }
        
        return settings
    }
}

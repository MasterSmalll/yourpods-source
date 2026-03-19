import Foundation
import os

/// OPML import/export for podcast subscriptions. Port of opml_service.dart.
struct OPMLService {
    private static let logger = Logger(subsystem: "com.yourpods", category: "OPML")
    
    /// Export subscriptions to an OPML XML string.
    static func export(podcasts: [Podcast]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>YourPods Subscriptions</title>
            <dateCreated>\(ISO8601DateFormatter().string(from: Date()))</dateCreated>
          </head>
          <body>
        
        """
        
        for podcast in podcasts {
            let title = escapeXML(podcast.title)
            let url = escapeXML(podcast.url)
            xml += "    <outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(url)\"/>\n"
        }
        
        xml += """
          </body>
        </opml>
        """
        
        return xml
    }
    
    /// Parse an OPML file and return a list of feed URLs.
    static func parseURLs(from data: Data) -> [String] {
        let parser = OPMLParser(data: data)
        return parser.parse()
    }
    
    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - OPML Parser

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

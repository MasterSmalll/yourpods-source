import Foundation
import os

/// Podcast search result from an external search API.
struct PodcastSearchResult: Identifiable {
    let id = UUID()
    let title: String
    let feedUrl: String
    let artworkUrl: String?
    let author: String?
    let genre: String?
    let description: String?
}

/// Protocol for podcast search providers.
protocol PodcastSearchProvider {
    func search(_ query: String) async throws -> [PodcastSearchResult]
}

// MARK: - iTunes Search

struct ITunesSearchProvider: PodcastSearchProvider {
    private let logger = Logger(subsystem: "com.yourpods", category: "ITunesSearch")
    
    func search(_ query: String) async throws -> [PodcastSearchResult] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        
        return results.compactMap { item -> PodcastSearchResult? in
            guard let title = item["trackName"] as? String,
                  let feedUrl = item["feedUrl"] as? String else { return nil }
            return PodcastSearchResult(
                title: title,
                feedUrl: feedUrl,
                artworkUrl: item["artworkUrl600"] as? String ?? item["artworkUrl100"] as? String,
                author: item["artistName"] as? String,
                genre: (item["genres"] as? [String])?.joined(separator: ", "),
                description: item["description"] as? String
            )
        }
    }
}

// MARK: - PodcastIndex Search

struct PodcastIndexSearchProvider: PodcastSearchProvider {
    let apiKey: String
    let apiSecret: String
    private let logger = Logger(subsystem: "com.yourpods", category: "PodcastIndexSearch")
    
    func search(_ query: String) async throws -> [PodcastSearchResult] {
        guard var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/search/byterm") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "max", value: "25"),
        ]
        
        guard let url = components.url else { return [] }
        
        let epoch = String(Int(Date().timeIntervalSince1970))
        let authString = apiKey + apiSecret + epoch
        // Simple hash for API auth
        let hashData = Data(authString.utf8)
        let hashHex = hashData.map { String(format: "%02x", $0) }.joined()
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(hashHex, forHTTPHeaderField: "X-Auth-Date")
        request.setValue(epoch, forHTTPHeaderField: "Authorization")
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feeds = json["feeds"] as? [[String: Any]] else { return [] }
        
        return feeds.compactMap { feed -> PodcastSearchResult? in
            guard let title = feed["title"] as? String,
                  let feedUrl = feed["url"] as? String else { return nil }
            return PodcastSearchResult(
                title: title,
                feedUrl: feedUrl,
                artworkUrl: feed["artwork"] as? String ?? feed["image"] as? String,
                author: feed["author"] as? String,
                genre: (feed["categories"] as? [String: String])?.values.joined(separator: ", "),
                description: feed["description"] as? String
            )
        }
    }
}

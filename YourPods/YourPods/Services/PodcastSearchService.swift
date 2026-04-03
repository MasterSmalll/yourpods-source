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
    let websiteUrl: String?
}

/// Protocol for podcast search providers.
protocol PodcastSearchProvider {
    func search(_ query: String) async throws -> [PodcastSearchResult]
}

/// Result of resolving which search provider to use.
enum SearchProviderResult {
    case provider(PodcastSearchProvider)
    case missingCredentials(String)
}

/// Testable resolver for search provider selection.
enum SearchProviderResolver {
    /// Resolve the configured search provider into a ready-to-use provider or an error.
    static func resolve(
        provider: SearchProvider,
        apiKey: String?,
        apiSecret: String?
    ) -> SearchProviderResult {
        switch provider {
        case .itunes:
            return .provider(ITunesSearchProvider())
        case .podcastIndex:
            guard let key = apiKey, !key.isEmpty,
                  let secret = apiSecret, !secret.isEmpty else {
                return .missingCredentials("Podcast Index requires an API key and secret. Add them in Settings → Search Provider.")
            }
            return .provider(PodcastIndexSearchProvider(apiKey: key, apiSecret: secret))
        }
    }
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
                description: item["description"] as? String,
                websiteUrl: nil
            )
        }
    }
}

import CryptoKit

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
        
        // Podcast Index API auth: Authorization = sha1(apiKey + apiSecret + epoch)
        let epoch = String(Int(Date().timeIntervalSince1970))
        let authString = apiKey + apiSecret + epoch
        let hashDigest = Insecure.SHA1.hash(data: Data(authString.utf8))
        let hashHex = hashDigest.map { String(format: "%02x", $0) }.joined()
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(epoch, forHTTPHeaderField: "X-Auth-Date")
        request.setValue(hashHex, forHTTPHeaderField: "Authorization")
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check HTTP status for auth errors
        if let http = response as? HTTPURLResponse {
            logger.debug("PodcastIndex API response status: \(http.statusCode)")
            if http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "(non-UTF8)"
                logger.error("PodcastIndex API error (\(http.statusCode)): \(body)")
                throw NSError(domain: "PodcastIndex", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Podcast Index API error (\(http.statusCode)). Check your API key and secret in Settings."])
            }
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feeds = json["feeds"] as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? "(non-UTF8)"
            logger.error("PodcastIndex unexpected response: \(body)")
            return []
        }
        
        return feeds.compactMap { feed -> PodcastSearchResult? in
            guard let title = feed["title"] as? String,
                  let feedUrl = feed["url"] as? String else { return nil }
            return PodcastSearchResult(
                title: title,
                feedUrl: feedUrl,
                artworkUrl: feed["artwork"] as? String ?? feed["image"] as? String,
                author: feed["author"] as? String,
                genre: (feed["categories"] as? [String: String])?.values.joined(separator: ", "),
                description: feed["description"] as? String,
                websiteUrl: feed["link"] as? String
            )
        }
    }
}

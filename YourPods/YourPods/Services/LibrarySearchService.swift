import Foundation

// MARK: - Library Search Result

struct EpisodeSearchResult {
    let episode: Episode
    let matchType: EpisodeMatchType
    let snippet: String?
    
    enum EpisodeMatchType {
        case title
        case description
    }
}

// MARK: - Library Search Service

/// Pure search logic for finding episodes across the user's podcast library.
/// Stateless — all inputs are passed as parameters, making it fully testable.
enum LibrarySearchService {
    
    /// Minimum query length before search fires.
    static let minimumQueryLength = 3
    
    /// Search episodes across all subscriptions by title (and optionally description).
    ///
    /// - Parameters:
    ///   - query: The search string (must be ≥ `minimumQueryLength` characters).
    ///   - subscriptions: The user's current podcast subscriptions.
    ///   - includeDescriptions: When true, also searches `episodeDescription`.
    ///   - maxResults: Maximum number of results to return.
    /// - Returns: Ranked search results — title matches first, then description matches.
    static func searchEpisodes(
        query: String,
        subscriptions: [Podcast],
        includeDescriptions: Bool = false,
        maxResults: Int = 20
    ) -> [EpisodeSearchResult] {
        guard query.count >= minimumQueryLength else { return [] }
        
        var titleMatches: [EpisodeSearchResult] = []
        var descriptionMatches: [EpisodeSearchResult] = []
        
        // Track episodes that matched by title so we don't duplicate them as description matches
        var titleMatchGuids: Set<String> = []
        
        for podcast in subscriptions {
            let episodes = podcast.episodes
            
            for episode in episodes {
                // Skip stale episodes
                if episode.isStale { continue }
                
                // Title match
                if episode.title.localizedCaseInsensitiveContains(query) {
                    titleMatches.append(EpisodeSearchResult(
                        episode: episode,
                        matchType: .title,
                        snippet: nil
                    ))
                    titleMatchGuids.insert(episode.guid)
                    continue
                }
                
                // Description match (only if enabled and not already matched by title)
                if includeDescriptions,
                   !titleMatchGuids.contains(episode.guid),
                   let description = episode.episodeDescription,
                   description.localizedCaseInsensitiveContains(query) {
                    let snippet = extractSnippet(from: description, query: query)
                    descriptionMatches.append(EpisodeSearchResult(
                        episode: episode,
                        matchType: .description,
                        snippet: snippet
                    ))
                }
            }
        }
        
        // Sort each group by pubDate descending (newest first)
        let sortByDate: (EpisodeSearchResult, EpisodeSearchResult) -> Bool = {
            ($0.episode.pubDate ?? .distantPast) > ($1.episode.pubDate ?? .distantPast)
        }
        titleMatches.sort(by: sortByDate)
        descriptionMatches.sort(by: sortByDate)
        
        // Title matches first, then description matches
        let combined = titleMatches + descriptionMatches
        return Array(combined.prefix(maxResults))
    }
    
    /// Extracts a snippet of text around the first occurrence of `query` in `text`.
    /// Returns nil if no match is found. HTML is stripped before extraction.
    static func extractSnippet(from text: String, query: String, maxLength: Int = 120) -> String? {
        let stripped = text.strippingHTML()
        
        guard let range = stripped.range(of: query, options: .caseInsensitive) else {
            return nil
        }
        
        let matchStart = stripped.distance(from: stripped.startIndex, to: range.lowerBound)
        let halfWindow = maxLength / 2
        
        // Center the snippet around the match
        let snippetStartOffset = max(0, matchStart - halfWindow)
        let snippetStart = stripped.index(stripped.startIndex, offsetBy: snippetStartOffset)
        let snippetEnd = stripped.index(snippetStart, offsetBy: min(maxLength, stripped.distance(from: snippetStart, to: stripped.endIndex)))
        
        var snippet = String(stripped[snippetStart..<snippetEnd])
        
        // Add ellipsis if truncated
        if snippetStartOffset > 0 { snippet = "…" + snippet }
        if snippetEnd < stripped.endIndex { snippet = snippet + "…" }
        
        return snippet
    }
}

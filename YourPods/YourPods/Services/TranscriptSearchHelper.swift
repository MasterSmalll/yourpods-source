import Foundation

/// Pure search logic for finding matches within a transcript.
/// Extracted from TranscriptListSheet for testability.
enum TranscriptSearchHelper {
    
    /// Minimum query length before transcript search fires.
    static let minimumQueryLength = 2
    
    /// Find indices of transcript items that contain the query string.
    ///
    /// - Parameters:
    ///   - query: The search string (must be ≥ `minimumQueryLength` characters).
    ///   - transcript: The transcript to search within.
    /// - Returns: Array of indices into `transcript.items` that match, in order.
    static func findMatches(query: String, in transcript: Transcript) -> [Int] {
        guard query.count >= minimumQueryLength else { return [] }
        
        var indices: [Int] = []
        for (index, item) in transcript.items.enumerated() {
            if item.text.localizedCaseInsensitiveContains(query) {
                indices.append(index)
            }
        }
        return indices
    }
    
    /// Next match index, wrapping around to 0.
    static func nextMatchIndex(current: Int, totalMatches: Int) -> Int {
        guard totalMatches > 0 else { return 0 }
        return (current + 1) % totalMatches
    }
    
    /// Previous match index, wrapping around to last.
    static func previousMatchIndex(current: Int, totalMatches: Int) -> Int {
        guard totalMatches > 0 else { return 0 }
        return (current - 1 + totalMatches) % totalMatches
    }
}

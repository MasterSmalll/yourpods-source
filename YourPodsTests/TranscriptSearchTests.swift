import XCTest
@testable import YourPods

// MARK: - Transcript Search Tests

final class TranscriptSearchTests: XCTestCase {
    
    // MARK: - Helpers
    
    private func makeTranscript(_ items: [(text: String, start: TimeInterval)]) -> Transcript {
        let transcriptItems = items.map { TranscriptItem(text: $0.text, start: $0.start, duration: 30) }
        return Transcript(items: transcriptItems, type: "text/plain")
    }
    
    // MARK: - Match Finding
    
    func test_transcriptSearch_findsExactMatch() {
        let transcript = makeTranscript([
            ("Hello world", 0),
            ("Swift is great", 30),
            ("Goodbye world", 60)
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "Swift is great", in: transcript)
        
        XCTAssertEqual(indices.count, 1)
        XCTAssertEqual(indices.first, 1)
    }
    
    func test_transcriptSearch_caseInsensitive() {
        let transcript = makeTranscript([
            ("Hello world", 0),
            ("SWIFT IS GREAT", 30),
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "swift is great", in: transcript)
        
        XCTAssertEqual(indices.count, 1)
        XCTAssertEqual(indices.first, 1)
    }
    
    func test_transcriptSearch_returnsCorrectIndices() {
        let transcript = makeTranscript([
            ("Welcome to the show", 0),
            ("Today we discuss Swift", 30),
            ("Swift is evolving fast", 60),
            ("Thanks for listening", 90)
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "Swift", in: transcript)
        
        XCTAssertEqual(indices, [1, 2], "Should find Swift in items at index 1 and 2")
    }
    
    func test_transcriptSearch_noMatchReturnsEmpty() {
        let transcript = makeTranscript([
            ("Hello world", 0),
            ("Goodbye world", 30),
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "Kubernetes", in: transcript)
        
        XCTAssertEqual(indices, [])
    }
    
    func test_transcriptSearch_partialWordMatch() {
        let transcript = makeTranscript([
            ("Understanding concurrency", 0),
            ("Using async patterns", 30),
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "concur", in: transcript)
        
        XCTAssertEqual(indices.count, 1)
        XCTAssertEqual(indices.first, 0)
    }
    
    // MARK: - Navigation
    
    func test_transcriptSearch_cyclesCorrectly() {
        // Given 3 matches at indices [1, 3, 5]
        let matchIndices = [1, 3, 5]
        
        // currentMatchIndex wraps around
        XCTAssertEqual(TranscriptSearchHelper.nextMatchIndex(current: 0, totalMatches: matchIndices.count), 1)
        XCTAssertEqual(TranscriptSearchHelper.nextMatchIndex(current: 1, totalMatches: matchIndices.count), 2)
        XCTAssertEqual(TranscriptSearchHelper.nextMatchIndex(current: 2, totalMatches: matchIndices.count), 0, "Should wrap to 0")
        
        XCTAssertEqual(TranscriptSearchHelper.previousMatchIndex(current: 0, totalMatches: matchIndices.count), 2, "Should wrap to last")
        XCTAssertEqual(TranscriptSearchHelper.previousMatchIndex(current: 1, totalMatches: matchIndices.count), 0)
        XCTAssertEqual(TranscriptSearchHelper.previousMatchIndex(current: 2, totalMatches: matchIndices.count), 1)
    }
    
    // MARK: - Edge Cases
    
    func test_EDGE_transcriptSearch_singleCharQuery_noResults() {
        let transcript = makeTranscript([
            ("A short sentence", 0),
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "A", in: transcript)
        
        XCTAssertEqual(indices, [], "Single character query should return no results")
    }
    
    func test_EDGE_transcriptSearch_emptyTranscript_noResults() {
        let transcript = Transcript(items: [], type: "text/plain")
        
        let indices = TranscriptSearchHelper.findMatches(query: "anything", in: transcript)
        
        XCTAssertEqual(indices, [])
    }
    
    func test_EDGE_transcriptSearch_emptyQuery_noResults() {
        let transcript = makeTranscript([
            ("Hello world", 0),
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "", in: transcript)
        
        XCTAssertEqual(indices, [])
    }
    
    func test_EDGE_transcriptSearch_multipleMatchesInSameItem() {
        let transcript = makeTranscript([
            ("Swift and more Swift discussion", 0),
            ("No match here", 30),
        ])
        
        let indices = TranscriptSearchHelper.findMatches(query: "Swift", in: transcript)
        
        // Item appears once in results even if the query matches multiple times within it
        XCTAssertEqual(indices.count, 1)
        XCTAssertEqual(indices.first, 0)
    }
}

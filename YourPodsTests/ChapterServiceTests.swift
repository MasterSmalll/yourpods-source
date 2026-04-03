import XCTest
@testable import YourPods

final class ChapterServiceTests: XCTestCase {
    
    func test_fetchAllChapters_returnsDescriptionChapters_whenUrlIsNil() async {
        let service = ChapterService.shared
        
        let chapters = await service.fetchAllChapters(
            chaptersUrl: nil,
            description: "(00:00) Chapter 1\n(05:00) Chapter 2"
        )
        
        XCTAssertEqual(chapters.count, 2, "Should fallback to description parsing and find 2 chapters")
    }
    
    // MARK: - Bracket Timestamp Support
    
    func test_parseChaptersFromDescription_supportsBracketTimestamps() {
        // GIVEN: Episode description with [MM:SS] bracket format
        let text = "[00:00] Introduction\n[05:30] Main Topic\n[12:00] Wrap Up"
        
        // WHEN: Parsing chapters
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // THEN: All 3 chapters are found with clean titles (no bracket leakage)
        XCTAssertEqual(chapters.count, 3, "Should parse [MM:SS] bracket timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction",
                       "Title must not contain ] bracket prefix")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[1].title, "Main Topic")
        XCTAssertEqual(chapters[1].startTime, 330)  // 5:30
        XCTAssertEqual(chapters[2].title, "Wrap Up")
        XCTAssertEqual(chapters[2].startTime, 720)  // 12:00
        // Explicit check: no bracket contamination
        XCTAssertFalse(chapters[0].title.hasPrefix("]"),
                       "Closing bracket must not leak into chapter title")
    }
    
    func test_parseChaptersFromDescription_supportsMixedBracketAndParenTimestamps() {
        // GIVEN: Mix of bracket and paren formats
        let text = "[00:00] Intro\n(05:00) Middle\n[10:00] End"
        
        // WHEN: Parsing
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // THEN: All found
        XCTAssertEqual(chapters.count, 3, "Should handle mixed bracket and paren formats")
    }
    
    func test_parseChaptersFromDescription_supportsHHMMSSBrackets() {
        // GIVEN: Bracketed HH:MM:SS format
        let text = "[0:00:00] Start\n[1:02:30] Part Two\n[2:15:00] Finale"
        
        // WHEN: Parsing
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // THEN: Correct times
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[1].startTime, 3750)  // 1*3600 + 2*60 + 30
    }
    
    func test_fetchAllChapters_returnsEmpty_whenBothNil() async {
        let service = ChapterService.shared
        
        let chapters = await service.fetchAllChapters(chaptersUrl: nil, description: nil)
        
        XCTAssertTrue(chapters.isEmpty, "Should return empty when both URL and description are nil")
    }
}

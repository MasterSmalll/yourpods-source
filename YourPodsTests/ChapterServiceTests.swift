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
    
    func test_fetchAllChapters_returnsEmpty_whenBothNil() async {
        let service = ChapterService.shared
        
        let chapters = await service.fetchAllChapters(chaptersUrl: nil, description: nil)
        
        XCTAssertTrue(chapters.isEmpty, "Should return empty when both URL and description are nil")
    }
    
    // MARK: - Parenthesized Timestamps (existing format)
    
    func test_parseChaptersFromDescription_supportsParenTimestamps() {
        let text = "(00:00) Introduction\n(05:48) Main Topic\n(12:00) Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[1].title, "Main Topic")
        XCTAssertEqual(chapters[1].startTime, 348)  // 5*60 + 48
        XCTAssertEqual(chapters[2].title, "Wrap Up")
        XCTAssertEqual(chapters[2].startTime, 720)
    }
    
    func test_parseChaptersFromDescription_supportsBareTimestamps() {
        let text = "00:00 Introduction\n05:30 Main Topic\n12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Main Topic")
        XCTAssertEqual(chapters[1].startTime, 330)
    }
    
    func test_parseChaptersFromDescription_supportsDashSeparator() {
        let text = "00:00 - Introduction\n05:30 - Main Topic\n12:00 - Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Main Topic")
    }
    
    func test_parseChaptersFromDescription_supportsHHMMSS() {
        let text = "(0:00:00) Start\n(1:02:30) Part Two\n(2:15:00) Finale"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[1].startTime, 3750)  // 1*3600 + 2*60 + 30
        XCTAssertEqual(chapters[2].startTime, 8100)  // 2*3600 + 15*60
    }
    
    // MARK: - Square Bracket Timestamps (Tim Ferriss format)
    
    func test_parseChaptersFromDescription_supportsBracketTimestamps() {
        // GIVEN: Episode description with [MM:SS] bracket format (Tim Ferriss Show)
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
    
    // MARK: - Bullet / List Prefix Timestamps
    
    func test_parseChaptersFromDescription_supportsBulletPrefix() {
        // GIVEN: Bullet-prefixed timestamps (common in show notes)
        let text = "• 00:00 Introduction\n• 05:30 Main Topic\n• 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse bullet-prefixed timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Main Topic")
    }
    
    func test_parseChaptersFromDescription_supportsDashPrefixedTimestamps() {
        // GIVEN: Dash used as a list marker before the timestamp
        let text = "- 00:00 Introduction\n- 05:30 Main Topic\n- 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse dash-prefixed list timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_supportsAsteriskPrefix() {
        // GIVEN: Markdown-style asterisk list
        let text = "* 00:00 Introduction\n* 05:30 Main Topic\n* 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse asterisk-prefixed timestamps")
    }
    
    func test_parseChaptersFromDescription_supportsNumberedList() {
        // GIVEN: Numbered list before timestamps
        let text = "1. 00:00 Introduction\n2. 05:30 Main Topic\n3. 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse numbered list timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    // MARK: - Separator Variants
    
    func test_parseChaptersFromDescription_supportsColonSeparator() {
        // GIVEN: Colon between timestamp and title
        let text = "00:00: Introduction\n05:30: Main Topic\n12:00: Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse colon-separated timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_supportsEmDashSeparator() {
        // GIVEN: Em-dash separator
        let text = "00:00 — Introduction\n05:30 — Main Topic\n12:00 — Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse em-dash-separated timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_supportsPipeSeparator() {
        // GIVEN: Pipe separator
        let text = "00:00 | Introduction\n05:30 | Main Topic\n12:00 | Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse pipe-separated timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    // MARK: - Real-world Descriptions
    
    func test_parseChaptersFromDescription_timFerrissFormat() {
        // GIVEN: Real Tim Ferriss Show format with brackets and HH:MM:SS
        let text = """
        Please enjoy this conversation with Dr. Andrew Huberman.
        
        [00:00] Introduction
        [06:12] The Science of Sleep
        [18:45] Cold Exposure Protocols
        [35:20] Dopamine and Motivation
        [1:02:30] Morning Routine Optimization
        [1:25:00] Closing Thoughts
        """
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 6, "Should parse Tim Ferriss bracket format")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[4].title, "Morning Routine Optimization")
        XCTAssertEqual(chapters[4].startTime, 3750)  // 1*3600 + 2*60 + 30
        XCTAssertEqual(chapters[5].title, "Closing Thoughts")
        XCTAssertEqual(chapters[5].startTime, 5100)  // 1*3600 + 25*60
    }
    
    func test_parseChaptersFromDescription_lexFridmanFormat() {
        // GIVEN: Lex Fridman style — bare timestamps with dash separators
        let text = """
        0:00 - Introduction
        2:23 - What is consciousness?
        15:40 - The hard problem
        1:05:12 - AI and the future
        2:30:00 - Meaning of life
        """
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 5, "Should parse Lex Fridman format")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[3].title, "AI and the future")
        XCTAssertEqual(chapters[3].startTime, 3912)  // 1*3600 + 5*60 + 12
    }
    
    func test_parseChaptersFromDescription_htmlDescription() {
        // GIVEN: HTML-formatted description with timestamps
        let text = """
        <p>Show notes:</p>
        <p>[00:00] Introduction</p>
        <p>[05:30] Main Topic</p>
        <p>[12:00] Wrap Up</p>
        """
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse timestamps from HTML descriptions")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_bracketTimestampWithDash() {
        // GIVEN: Brackets with dash separator (hybrid format)
        let text = "[00:00] - Introduction\n[05:30] - Main Topic\n[12:00] - Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    // MARK: - Edge Cases
    
    func test_parseChaptersFromDescription_singleTimestamp_returnsEmpty() {
        // A single timestamp isn't useful as chapters
        let text = "[00:00] Introduction"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertTrue(chapters.isEmpty, "Single timestamp should return empty")
    }
    
    func test_parseChaptersFromDescription_noTimestamps_returnsEmpty() {
        let text = "This is a normal description without timestamps."
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertTrue(chapters.isEmpty)
    }
    
    func test_parseChaptersFromDescription_urlsNotTreatedAsChapters() {
        // URLs after timestamps should be filtered out
        let text = "00:00 Introduction\n05:00 http://example.com\n10:00 Conclusion"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // Should skip the URL line
        XCTAssertEqual(chapters.count, 2, "URLs should be filtered out")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Conclusion")
    }
    
    func test_parseChaptersFromDescription_combinedPrefixAndBrackets() {
        // GIVEN: Bullet + bracket combo
        let text = "• [00:00] Introduction\n• [05:30] Main Topic\n• [12:00] Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should handle bullet + bracket combination")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
}

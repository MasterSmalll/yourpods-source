import XCTest
@testable import YourPods

// MARK: - TranscriptService Parsing Tests

final class TranscriptServiceTests: XCTestCase {
    
    // MARK: - parsePlainText: [HH:MM:SS] Speaker format
    
    func test_parsePlainText_withTimestampedSpeakerFormat() {
        let content = """
        [00:00:00] Host: Welcome to the show.

        [00:00:01] Guest: Thanks for having me.

        [00:01:05] Host: Good point about that.
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.txt", type: "text/plain")
        
        XCTAssertEqual(transcript.items.count, 3, "Should parse 3 segments separated by blank lines")
        XCTAssertEqual(transcript.items[0].start, 0, "First item starts at 0:00:00")
        XCTAssertTrue(transcript.items[0].text.contains("Host:"), "Should preserve speaker label")
        XCTAssertTrue(transcript.items[0].text.contains("Welcome to the show"), "Should preserve text content")
        XCTAssertEqual(transcript.items[1].start, 1, "Second item starts at 0:00:01")
        XCTAssertEqual(transcript.items[2].start, 65, "Third item starts at 1:05")
        XCTAssertEqual(transcript.type, "text/plain")
    }
    
    // MARK: - parsePlainText: no timestamps → single item
    
    func test_parsePlainText_noTimestamps_singleItem() {
        let content = """
        This is just a plain text transcript of the episode without any timestamps.
        It has multiple lines but no time markers.
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.txt", type: "text/plain")
        
        XCTAssertEqual(transcript.items.count, 1, "Should produce a single item for plain text without timestamps")
        XCTAssertEqual(transcript.items[0].start, 0, "Single item starts at 0")
        XCTAssertTrue(transcript.items[0].text.contains("plain text transcript"), "Should contain the full text")
        XCTAssertEqual(transcript.type, "text/plain")
    }
    
    // MARK: - parseHTML: strips tags and parses timestamps
    
    func test_parseHTML_stripsTagsAndParsesTimestamps() {
        let content = """
        <p>[00:00:00] <b>Host:</b> Welcome to the show.</p>
        <p></p>
        <p>[00:01:30] <b>Guest:</b> Thanks for having me.</p>
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.html", type: "text/html")
        
        XCTAssertEqual(transcript.items.count, 2, "Should parse 2 segments from HTML")
        XCTAssertEqual(transcript.items[0].start, 0, "First segment at 0:00")
        XCTAssertTrue(transcript.items[0].text.contains("Host:"), "Should preserve speaker after stripping HTML")
        XCTAssertEqual(transcript.items[1].start, 90, "Second segment at 1:30")
        XCTAssertEqual(transcript.type, "text/html")
    }
    
    // MARK: - parseContent routing
    
    func test_parseContent_routesTextPlain() {
        let content = "[00:00:00] Speaker: Hello"
        let transcript = TranscriptService.parseContentSync(content, url: "test.txt", type: "text/plain")
        XCTAssertEqual(transcript.type, "text/plain")
    }
    
    func test_parseContent_routesTextHTML() {
        let content = "<p>[00:00:00] Speaker: Hello</p>"
        let transcript = TranscriptService.parseContentSync(content, url: "test.html", type: "text/html")
        XCTAssertEqual(transcript.type, "text/html")
    }
    
    func test_parseContent_routesJSON() {
        let content = """
        {"segments":[{"body":"Hello","startTime":0,"endTime":5}]}
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.json", type: "application/json")
        XCTAssertEqual(transcript.type, "application/json")
        XCTAssertEqual(transcript.items.count, 1)
    }
    
    func test_parseContent_routesVTT() {
        let content = """
        WEBVTT

        00:00:00.000 --> 00:00:05.000
        Hello world
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.vtt", type: "text/vtt")
        XCTAssertEqual(transcript.type, "text/vtt")
        XCTAssertEqual(transcript.items.count, 1)
    }
    
    func test_parseContent_routesSRT() {
        let content = """
        1
        00:00:00,000 --> 00:00:05,000
        Hello world
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.srt", type: "application/x-subrip")
        XCTAssertEqual(transcript.type, "application/srt")
        XCTAssertEqual(transcript.items.count, 1)
    }
    
    func test_parseContent_unknownType_fallsToSRT() {
        let content = """
        1
        00:00:00,000 --> 00:00:05,000
        Hello world
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.xyz", type: "application/octet-stream")
        // Unknown types fall through to SRT parser
        XCTAssertEqual(transcript.type, "application/srt")
    }
    
    // MARK: - parsePlainText: multi-line segments
    
    func test_parsePlainText_multiLineSegments() {
        let content = """
        [00:00:00] Host: First line of speech.
        And it continues on the next line.

        [00:00:30] Guest: Another segment.
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.txt", type: "text/plain")
        
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertTrue(transcript.items[0].text.contains("continues on the next line"), "Should include continuation lines in segment")
        XCTAssertEqual(transcript.items[1].start, 30)
    }
    
    // MARK: - parsePlainText: inline timestamps
    
    func test_parsePlainText_inlineTimestamps() {
        // The 3reate format sometimes has inline timestamps mid-sentence
        let content = """
        [00:00:00] Host: Welcome to the show.

        [00:00:01] Guest: Thanks for having me.

        [00:00:04] Host: [00:00:05] And here is a second sentence with an inline marker.
        """
        let transcript = TranscriptService.parseContentSync(content, url: "test.txt", type: "text/plain")
        
        XCTAssertEqual(transcript.items.count, 3, "Should produce 3 segments")
        // Third segment starts at the first timestamp on that segment
        XCTAssertEqual(transcript.items[2].start, 4)
    }
}

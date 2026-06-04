import XCTest
@testable import YourPods

/// Tests for HTML rendering utilities (String+HTML.swift).
/// Validates that `htmlAttributedString()` safely produces an `AttributedString`
/// and that `strippingHTML()` correctly removes tags and decodes entities.
final class HTMLRenderingTests: XCTestCase {
    
    // MARK: - strippingHTML
    
    func test_strippingHTML_removesTagsCorrectly() {
        let html = "<p>Hello <b>world</b></p>"
        let result = html.strippingHTML()
        XCTAssertEqual(result, "Hello world")
    }
    
    func test_strippingHTML_handlesEntities() {
        let html = "Tom &amp; Jerry &lt;3 &quot;cartoons&quot;"
        let result = html.strippingHTML()
        XCTAssertEqual(result, "Tom & Jerry <3 \"cartoons\"")
    }
    
    func test_strippingHTML_handlesBrTags() {
        let html = "Line 1<br/>Line 2<br>Line 3"
        let result = html.strippingHTML()
        XCTAssertTrue(result.contains("Line 1"))
        XCTAssertTrue(result.contains("Line 2"))
        XCTAssertTrue(result.contains("Line 3"))
    }
    
    func test_strippingHTML_handlesEmptyString() {
        let html = ""
        let result = html.strippingHTML()
        XCTAssertEqual(result, "")
    }
    
    // MARK: - htmlAttributedString
    
    @MainActor
    func test_htmlAttributedString_returnsValidResult_forSimpleHTML() {
        let html = "<p>Hello <b>world</b></p>"
        let result = html.htmlAttributedString()
        // Should produce a non-empty attributed string containing the text
        let plainText = String(result.characters)
        XCTAssertTrue(plainText.contains("Hello"), "Expected attributed string to contain 'Hello', got: \(plainText)")
        XCTAssertTrue(plainText.contains("world"), "Expected attributed string to contain 'world', got: \(plainText)")
    }
    
    @MainActor
    func test_htmlAttributedString_fallsBackToStripped_forEmptyString() {
        let html = ""
        let result = html.htmlAttributedString()
        // Empty input should return an empty or near-empty attributed string
        let plainText = String(result.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(plainText.isEmpty, "Expected empty result for empty input, got: '\(plainText)'")
    }
    
    // MARK: - ObjC exception safety
    
    @MainActor
    func test_htmlAttributedString_survivesObjCException() {
        // Feed intentionally malformed data that would cause WebKit to assert.
        // With the ObjC exception catcher, this should fall back to strippingHTML()
        // instead of crashing the process.
        //
        // Note: We can't easily trigger the exact snapshot-phase assertion from a test,
        // but we CAN verify the ObjCExceptionCatcher utility itself works.
        let caughtError = ObjCExceptionCatcher.catch {
            NSException(name: .genericException, reason: "test", userInfo: nil).raise()
        }
        XCTAssertNotNil(caughtError, "ObjCExceptionCatcher should convert raised NSExceptions into NSErrors")
        XCTAssertTrue(caughtError!.localizedDescription.contains("test"),
                       "Error should contain the exception reason")
    }
    
    func test_ObjCExceptionCatcher_returnsNil_whenNoException() {
        let caughtError = ObjCExceptionCatcher.catch {
            // No exception — this is fine
            _ = 1 + 1
        }
        XCTAssertNil(caughtError, "No exception means no error")
    }
}

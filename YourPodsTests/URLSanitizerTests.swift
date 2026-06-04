import XCTest
@testable import YourPods

// MARK: - URL Sanitizer Tests

final class URLSanitizerTests: XCTestCase {

    // MARK: - sanitize()

    func test_sanitize_bareDomain_defaultsToHTTPS() {
        let result = URLSanitizer.sanitize("cloud.example.com")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_bareDomainWithPath_defaultsToHTTPS() {
        let result = URLSanitizer.sanitize("cloud.example.com/nextcloud")
        XCTAssertEqual(result, "https://cloud.example.com/nextcloud")
    }

    func test_sanitize_explicitHTTPS_preserved() {
        let result = URLSanitizer.sanitize("https://cloud.example.com")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_explicitHTTP_preservedNotUpgraded() {
        // HTTP should NOT be force-upgraded — user may need it for self-hosted servers
        let result = URLSanitizer.sanitize("http://192.168.1.100:8080")
        XCTAssertEqual(result, "http://192.168.1.100:8080")
    }

    func test_sanitize_trailingSlash_stripped() {
        let result = URLSanitizer.sanitize("https://cloud.example.com/")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_whitespace_trimmed() {
        let result = URLSanitizer.sanitize("  https://cloud.example.com  ")
        XCTAssertEqual(result, "https://cloud.example.com")
    }

    func test_sanitize_httpCaseInsensitive() {
        let result = URLSanitizer.sanitize("HTTP://example.com")
        XCTAssertEqual(result, "HTTP://example.com",
                       "Should preserve original case, not double-prefix")
    }

    // MARK: - isInsecure()

    func test_isInsecure_httpURL_returnsTrue() {
        XCTAssertTrue(URLSanitizer.isInsecure("http://example.com"))
    }

    func test_isInsecure_httpsURL_returnsFalse() {
        XCTAssertFalse(URLSanitizer.isInsecure("https://example.com"))
    }

    func test_isInsecure_caseInsensitive() {
        XCTAssertTrue(URLSanitizer.isInsecure("HTTP://EXAMPLE.COM"))
    }

    func test_isInsecure_bareDomain_returnsFalse() {
        // A bare domain without scheme is not "http://"
        XCTAssertFalse(URLSanitizer.isInsecure("example.com"))
    }

    // MARK: - suggestedHTTPSURL()

    func test_suggestedHTTPSURL_convertsHTTPtoHTTPS() {
        let result = URLSanitizer.suggestedHTTPSURL("http://cloud.example.com")
        XCTAssertEqual(result, "https://cloud.example.com",
                       "Should replace http:// with https://")
    }

    func test_suggestedHTTPSURL_preservesPathAndPort() {
        let result = URLSanitizer.suggestedHTTPSURL("http://192.168.1.100:8080/nextcloud")
        XCTAssertEqual(result, "https://192.168.1.100:8080/nextcloud",
                       "Should preserve port and path when converting to HTTPS")
    }

    func test_suggestedHTTPSURL_caseInsensitive() {
        let result = URLSanitizer.suggestedHTTPSURL("HTTP://EXAMPLE.COM")
        XCTAssertEqual(result, "https://EXAMPLE.COM",
                       "Should handle uppercase HTTP scheme")
    }

    func test_suggestedHTTPSURL_returnsNil_forHTTPS() {
        let result = URLSanitizer.suggestedHTTPSURL("https://cloud.example.com")
        XCTAssertNil(result,
                     "Should return nil when URL is already HTTPS — no suggestion needed")
    }

    func test_suggestedHTTPSURL_returnsNil_forBareDomain() {
        let result = URLSanitizer.suggestedHTTPSURL("cloud.example.com")
        XCTAssertNil(result,
                     "Should return nil for bare domains — they default to HTTPS via sanitize()")
    }
}

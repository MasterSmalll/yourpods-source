import XCTest
@testable import YourPods

/// Tests for client-side email validation.
///
/// The app must reject obviously invalid emails before sending them to
/// Firebase, preventing confusing "badly formatted" errors from the server.
@MainActor
final class EmailValidationTests: XCTestCase {

    // MARK: - Valid emails should pass

    func test_validEmail_simple() {
        XCTAssertTrue(EmailValidator.isValid("user@example.com"))
    }

    func test_validEmail_withSubdomain() {
        XCTAssertTrue(EmailValidator.isValid("user@mail.example.com"))
    }

    func test_validEmail_withPlus() {
        XCTAssertTrue(EmailValidator.isValid("user+tag@example.com"))
    }

    func test_validEmail_withDots() {
        XCTAssertTrue(EmailValidator.isValid("first.last@example.com"))
    }

    func test_validEmail_withUnderscore() {
        XCTAssertTrue(EmailValidator.isValid("first_last@example.com"))
    }

    // MARK: - Invalid emails should fail

    func test_invalidEmail_empty() {
        XCTAssertFalse(EmailValidator.isValid(""))
    }

    func test_invalidEmail_noAtSign() {
        XCTAssertFalse(EmailValidator.isValid("userexample.com"))
    }

    func test_invalidEmail_noDomain() {
        XCTAssertFalse(EmailValidator.isValid("user@"))
    }

    func test_invalidEmail_noLocalPart() {
        XCTAssertFalse(EmailValidator.isValid("@example.com"))
    }

    func test_invalidEmail_noDot() {
        XCTAssertFalse(EmailValidator.isValid("user@example"))
    }

    func test_invalidEmail_trailingSpace() {
        // After trimming, this would be valid — but raw input should fail
        XCTAssertFalse(EmailValidator.isValid("user@example.com "))
    }

    func test_invalidEmail_leadingSpace() {
        XCTAssertFalse(EmailValidator.isValid(" user@example.com"))
    }

    func test_invalidEmail_internalSpace() {
        XCTAssertFalse(EmailValidator.isValid("user @example.com"))
    }

    func test_invalidEmail_multipleAtSigns() {
        XCTAssertFalse(EmailValidator.isValid("user@@example.com"))
    }

    func test_invalidEmail_dotImmediatelyAfterAt() {
        XCTAssertFalse(EmailValidator.isValid("user@.com"))
    }

    // MARK: - AuthProviderError mapping

    func test_invalidEmail_error_hasUserFriendlyMessage() {
        let error = AuthProviderError.invalidEmail
        XCTAssertEqual(
            error.errorDescription,
            "Please enter a valid email address.",
            "invalidEmail should have a clear, user-friendly message"
        )
    }
}

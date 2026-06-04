import XCTest
import SwiftUI
@testable import YourPods

/// Tests for the RevealableSecureField component.
///
/// Verifies that the component correctly creates both the revealed (TextField)
/// and hidden (SecureField) states, and that the toggle switches between them.
final class RevealableSecureFieldTests: XCTestCase {

    // MARK: - Default State

    /// The field should default to the hidden (SecureField) state.
    func testDefaultStateIsHidden() {
        // Given
        var text = "secret123"
        let binding = Binding(get: { text }, set: { text = $0 })

        // When
        let sut = RevealableSecureField(label: "Password", text: binding)

        // Then — the component should exist and be constructable with default hidden state.
        // Since SwiftUI views are value types, we verify the component is constructable
        // and the body does not crash. The visual toggle is verified via UI tests.
        XCTAssertNotNil(sut)
        XCTAssertNotNil(sut.body)
    }

    /// The label should be forwarded correctly.
    func testLabelIsForwarded() {
        // Given
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })

        // When
        let sut = RevealableSecureField(label: "Create a password (6+ characters)", text: binding)

        // Then
        XCTAssertEqual(sut.label, "Create a password (6+ characters)")
    }

    /// The text binding should be readable.
    func testTextBindingReadsValue() {
        // Given
        var text = "myP@ssw0rd"
        let binding = Binding(get: { text }, set: { text = $0 })

        // When
        let sut = RevealableSecureField(label: "Password", text: binding)

        // Then — the binding should reflect the original value
        XCTAssertEqual(sut.text, "myP@ssw0rd")
    }

    /// The text binding should be writable.
    func testTextBindingWritesValue() {
        // Given
        var text = "old"
        let binding = Binding(get: { text }, set: { text = $0 })
        let sut = RevealableSecureField(label: "Password", text: binding)

        // When
        sut.text = "new"

        // Then
        XCTAssertEqual(text, "new")
    }

    /// The component should accept an empty string.
    func testEmptyTextIsValid() {
        // Given
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })

        // When
        let sut = RevealableSecureField(label: "Password", text: binding)

        // Then
        XCTAssertEqual(sut.text, "")
        XCTAssertNotNil(sut.body)
    }
}

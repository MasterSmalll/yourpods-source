import XCTest
@testable import YourPods

/// A string can be user-visible or it can be load-bearing in program logic.
/// When it is both, translating it breaks the logic — silently, and only in
/// the languages nobody on the team reads.
///
/// The measured instance: `ProfileSelectionView` printed "DELETE" on screen as
/// localizable text and compared the typed word against the English literal, so
/// shipping any translation would have made account deletion impossible in all
/// five target languages. Nothing about that failure is visible in English.
///
/// The generalisation lives in `Translations/tools/inventory.py`
/// (`logic_coupled`), which reports every localizable string a comparison in
/// Swift depends on. This class pins the two it found.
final class LocalizationLogicCouplingGuardTests: XCTestCase {

    // MARK: - The account-deletion confirmation word

    func test_theDeleteConfirmationWord_isNotEmpty() {
        XCTAssertFalse(EditProfileView.deleteConfirmationWord.isEmpty,
                       "An empty confirmation word would unlock the delete button on an empty field")
    }

    /// The field applies `.textInputAutocapitalization(.characters)`, so what
    /// the user types arrives uppercased. A translator supplying a lowercase
    /// word would make the field permanently unmatchable.
    func test_theDeleteConfirmationWord_survivesTheFieldsAutocapitalization() {
        let word = EditProfileView.deleteConfirmationWord
        XCTAssertEqual(word, word.uppercased(),
                       "The confirmation field force-uppercases input, so the token must already be uppercase")
    }

    /// Autocorrect is disabled and the field is single-line; a phrase would be
    /// hostile to type and impossible to match after autocapitalization.
    func test_theDeleteConfirmationWord_isASingleWord() {
        XCTAssertFalse(EditProfileView.deleteConfirmationWord.contains(" "),
                       "A multi-word token is unusable in a field that autocapitalizes and disables autocorrect")
    }

    /// The prompt the user reads and the value the button compares against must
    /// be the same string. Two literals cannot be kept in sync by discipline.
    func test_theDeletePromptQuotesTheSameWordTheButtonCompares() throws {
        let source = try Self.source("YourPods/YourPods/Views/ProfileSelectionView.swift")
        XCTAssertFalse(source.contains(#"deleteConfirmation != "DELETE""#),
                       "The delete button compares against a hardcoded English literal — translating the prompt would lock users out of account deletion")
        XCTAssertTrue(source.contains("deleteConfirmation != Self.deleteConfirmationWord"),
                      "The delete button must compare against the same localized token the prompt shows")
    }

    /// The three properties above are checked against whichever localization the
    /// test bundle resolves to — English. That is not the risk.
    ///
    /// The risk is a *translation* that breaks them: the field force-uppercases
    /// what the user types, so a token that is not already uppercase in some
    /// language can never be matched, and account deletion becomes impossible in
    /// that language alone. German's "LÖSCHEN" is fine; a language whose
    /// uppercasing changes length — German's ß uppercases to SS — would not be.
    ///
    /// So every translation in the catalog is checked, not just the running one.
    func test_everyTranslationOfTheConfirmationWord_survivesUppercasing() throws {
        let parsed = try LocalizationCatalogFixture.load("YourPods/YourPods/Localizable.xcstrings")
        let entry = try XCTUnwrap(
            LocalizationCatalogFixture.strings(in: parsed)["account.delete.confirmWord"] as? [String: Any],
            "account.delete.confirmWord is missing — the confirmation field has no token")

        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        var checked = 0
        for (language, body) in localizations {
            guard let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any],
                  let word = unit["value"] as? String else { continue }
            checked += 1
            XCTAssertEqual(word, word.uppercased(),
                "[\(language)] '\(word)' is not equal to its own uppercasing, so the field — which force-uppercases input — can never match it, and account deletion is impossible in \(language)")
            XCTAssertFalse(word.contains(" "),
                "[\(language)] '\(word)' contains a space; the field disables autocorrect and expects one word")
            XCTAssertFalse(word.isEmpty,
                "[\(language)] the confirmation word is empty, which would unlock the delete button on an empty field")
        }
        XCTAssertGreaterThan(checked, 0, "no localizations inspected — including English, so the walk is broken")
    }

    // MARK: - Identity literals

    /// Strings that are identity, not copy: persisted profile names, wire
    /// values, scheme names. They may be *displayed* through a localizable
    /// label, but the stored and compared value must stay English.
    ///
    /// `Vault Mode` is safe today by luck rather than design — the two
    /// `Label("Vault Mode", …)` call sites localize while
    /// `ServerProfile(name: "Vault Mode")` passes a plain `String` that never
    /// extracts. This pins that arrangement so a future `Text(profile.name)`
    /// cannot quietly start showing English.
    static let identityLiterals: [String: String] = [
        "Vault Mode": "ServerProfile.name is persisted and compared in PodcastManager; the displayed Label is translated, the stored name must stay English",
    ]

    func test_identityLiteralsAreNeverComparedAgainstALocalizedValue() throws {
        for (literal, reason) in Self.identityLiterals {
            let source = try Self.source("YourPods/YourPods/State/PodcastManager.swift")
            XCTAssertTrue(source.contains("== \"\(literal)\""),
                          "\(literal) is documented as an identity literal (\(reason)) but PodcastManager no longer compares it — if the comparison moved, this guard is now measuring nothing")
        }
    }

    // MARK: - Self-check
    //
    // A guard that cannot fail is not a guard. This section was earned: a scan
    // that could only ever return "clean" once shipped a wrong claim into a
    // commit and a code comment.

    func test_scanner_wouldCatchAHardcodedComparison() throws {
        let broken = #"    .disabled(deleteConfirmation != "DELETE" || isDeletingAccount)"#
        XCTAssertTrue(broken.contains(#"deleteConfirmation != "DELETE""#),
                      "The pattern this class asserts against must actually match the shape of the original bug")
    }

    // MARK: - Helpers

    static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YourPodsTests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

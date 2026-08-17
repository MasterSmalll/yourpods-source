import CryptoKit
import Foundation
import XCTest

/// A translation is only correct with respect to the English it was made from.
///
/// Edit the English copy and Xcode leaves every translation in place and marks
/// nothing. The German still renders; it is simply now a translation of a
/// sentence the app no longer says. Nothing about that is visible in English,
/// and nothing about it is visible in review either — which is why it needs a
/// machine to notice.
///
/// `Translations/english-hashes.json` records, per translated key, a digest of
/// the English it was translated from. This fails when the two disagree.
///
/// Written by `Translations/tools/english_hashes.py --write`, which means "these
/// translations have been re-checked against this English". Running it purely to
/// silence this test is the one way to make the file worse than useless.
final class LocalizationStalenessGuardTests: XCTestCase {

    // MARK: - Invariant: no translation outlives the English it was made from

    func test_noTranslationWasMadeFromDifferentEnglish() throws {
        let recorded = try Self.recordedHashes()
        var drifted: [String] = []
        var untracked: [String] = []
        var translated = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            let known = recorded[catalog.path] as? [String: Any] ?? [:]

            for (key, value) in LocalizationCatalogFixture.strings(in: parsed) {
                let entry = value as? [String: Any] ?? [:]
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                guard localizations.keys.contains(where: { $0 != "en" }) else { continue }
                guard let english = Self.englishRendering(of: entry) else { continue }
                translated += 1

                guard let row = known[key] as? [String: Any],
                      let expected = row["english"] as? String else {
                    untracked.append("\(catalog.path): \(key.debugDescription)")
                    continue
                }
                if expected != Self.digest(english) {
                    drifted.append("\(catalog.path): \(key.debugDescription)")
                }
            }
        }

        XCTAssertTrue(drifted.isEmpty, """
        The English moved out from under these translations:

          \(drifted.sorted().joined(separator: "\n  "))

        Re-read each translation against the new English, fix what no longer
        matches, then run:
            python3 Translations/tools/english_hashes.py --write
        """)

        XCTAssertTrue(untracked.isEmpty, """
        These keys have translations with no recorded English:

          \(untracked.sorted().joined(separator: "\n  "))

        Run `python3 Translations/tools/english_hashes.py --write` after the
        translations have been reviewed — not before.
        """)

        // With no translations yet this test proves nothing about the tree, so
        // say so out loud rather than let a vacuous pass look like coverage.
        if translated == 0 {
            XCTAssertTrue(recorded.isEmpty,
                          "no translations exist, so english-hashes.json should be empty — it records \(recorded.count) catalogs")
        }
    }

    /// Every language the project ships must be present for a key once that key
    /// is translated at all. A key translated into three of five languages is
    /// three-fifths shipped and looks complete in the catalog editor.
    func test_aTranslatedKeyIsTranslatedIntoEveryLanguage() throws {
        var partial: [String] = []
        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            for (key, value) in LocalizationCatalogFixture.strings(in: parsed) {
                let entry = value as? [String: Any] ?? [:]
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                let present = Set(localizations.keys).intersection(Self.shippingLanguages)
                guard !present.isEmpty else { continue }
                let missing = Self.shippingLanguages.subtracting(present)
                if !missing.isEmpty {
                    partial.append("\(catalog.path): \(key.debugDescription) missing \(missing.sorted())")
                }
            }
        }
        XCTAssertTrue(partial.isEmpty, """
        Partially translated keys — these render English in the languages they
        are missing, with nothing on screen to indicate it:

          \(partial.sorted().prefix(40).joined(separator: "\n  "))
        """)
    }

    static let shippingLanguages: Set<String> = ["de", "es", "fr", "it", "nl"]

    // MARK: - Rendering and digest
    //
    // Must agree byte for byte with `english_of` and `digest` in
    // Translations/tools/english_hashes.py, or every key reads as drifted.

    static func englishRendering(of entry: [String: Any]) -> String? {
        guard let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
        else { return nil }

        let substitutions = english["substitutions"] as? [String: Any]
        if let unit = english["stringUnit"] as? [String: Any], substitutions == nil {
            return unit["value"] as? String
        }

        var parts: [String] = []
        if let unit = english["stringUnit"] as? [String: Any] {
            parts.append("template=" + String(describing: unit["value"] ?? "None"))
        }
        for (kind, cases) in (english["variations"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            for (name, body) in (cases as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any]
                parts.append("\(kind).\(name)=" + String(describing: unit?["value"] ?? "None"))
            }
        }
        for (name, body) in (substitutions ?? [:]).sorted(by: { $0.key < $1.key }) {
            let variations = (body as? [String: Any])?["variations"] as? [String: Any] ?? [:]
            for (kind, cases) in variations.sorted(by: { $0.key < $1.key }) {
                for (caseName, inner) in (cases as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let unit = (inner as? [String: Any])?["stringUnit"] as? [String: Any]
                    parts.append("sub.\(name).\(kind).\(caseName)=" + String(describing: unit?["value"] ?? "None"))
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    static func recordedHashes() throws -> [String: Any] {
        let url = LocalizationCatalogFixture.repositoryRoot
            .appendingPathComponent("Translations/english-hashes.json")
        let data = try XCTUnwrap(try? Data(contentsOf: url),
            "Translations/english-hashes.json is missing — the staleness gate cannot run")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - Self-checks
    //
    // With zero translations in the tree this guard cannot fail on real data,
    // so the proof that it works has to live here.

    func test_digest_matchesThePythonWriter() {
        // sha256("Done")[:16], computed independently:
        //   python3 -c "import hashlib;print(hashlib.sha256(b'Done').hexdigest()[:16])"
        XCTAssertEqual(Self.digest("Done"), "11a6767d5674c7e4")
        XCTAssertEqual(Self.digest(""), "e3b0c44298fc1c14")
    }

    func test_rendering_readsAPlainStringUnit() {
        let entry: [String: Any] = ["localizations": ["en": ["stringUnit": ["state": "translated", "value": "Next Chapter"]]]]
        XCTAssertEqual(Self.englishRendering(of: entry), "Next Chapter")
    }

    func test_rendering_coversEveryPluralCase() {
        let entry: [String: Any] = ["localizations": ["en": ["variations": ["plural": [
            "one": ["stringUnit": ["state": "translated", "value": "%lld episode"]],
            "other": ["stringUnit": ["state": "translated", "value": "%lld episodes"]],
        ]]]]]
        XCTAssertEqual(Self.englishRendering(of: entry),
                       "plural.one=%lld episode plural.other=%lld episodes")
    }

    func test_rendering_changesWhenOnlyTheSingularChanges() {
        func entry(_ one: String) -> [String: Any] {
            ["localizations": ["en": ["variations": ["plural": [
                "one": ["stringUnit": ["state": "translated", "value": one]],
                "other": ["stringUnit": ["state": "translated", "value": "%lld episodes"]],
            ]]]]]
        }
        let before = try? XCTUnwrap(Self.englishRendering(of: entry("%lld episode")))
        let after = try? XCTUnwrap(Self.englishRendering(of: entry("%lld instalment")))
        XCTAssertNotEqual(before, after,
                          "editing only the singular must still count as drift — it is the case a reviewer skims past")
    }

    func test_rendering_isNilWhenThereIsNoEnglish() {
        XCTAssertNil(Self.englishRendering(of: [:]))
        XCTAssertNil(Self.englishRendering(of: ["localizations": ["de": ["stringUnit": ["value": "Fertig"]]]]))
    }
}

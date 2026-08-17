import XCTest

/// A count needs plural rules in every language, including the source one.
///
/// `"%lld episodes"` renders "1 episodes" in English, so the bug is visible
/// before a single translation exists. Spanish and Italian break their plurals
/// differently from English, French puts zero in the singular, and Arabic — if
/// it is ever added — has six categories. None of that can be expressed by a
/// `count == 1 ? "" : "s"` ternary in Swift.
final class LocalizationPluralGuardTests: XCTestCase {

    /// Counts that govern nothing grammatical, each with a reason. Parenthesised
    /// badges, values after a colon, unit abbreviations and "N of M" positions.
    static let countsWithoutAgreement: [String: String] = [
        "%lld of %lld": "a position, not a quantity — 'of' agrees with nothing",
        "Match %lld of %lld": "search-result position",
        "Processing podcast %lld of %lld…": "progress position",
        "Chapters (%lld)": "parenthesised badge after a fixed heading",
        "Hide Older Episodes (%lld)": "parenthesised badge inside a button label",
        "Mark All as Played (%lld)": "parenthesised badge inside a button label",
        "Show Hidden (%lld)": "parenthesised badge inside a button label",
        "Up Next (%lld)": "parenthesised badge after a fixed heading",
        "Podcasts to Sync: %lld": "a value after a colon, like a spec-sheet row",
        "Sync Interval: %llds": "a value after a colon",
        "Skip Intro: %llds": "a value after a colon",
        "Skip Outro: %llds": "a value after a colon",
        "%lld min": "unit abbreviation; 'min' does not inflect",
        "%lld min this week": "unit abbreviation",
        "%lld total": "'total' is invariant in every target language",
        "%lld ep · %@": "unit abbreviation for 'episodes' in a dense row",
        "Controls AirPods double/triple-tap and lock screen previous/next. Skip durations use your Playback settings above (%llds back, %llds forward).":
            "two unit abbreviations, neither governing a noun",
        "format.duration.hoursMinutes": "unit abbreviations",
        "format.duration.minutes": "unit abbreviation",
        "format.duration.seconds": "unit abbreviation",
        "format.seconds.short": "unit abbreviation",
        "settings.skip.customWithValue": "unit abbreviation inside parentheses",
        "format.progress.left": "percentage; the unit does not inflect",
        "format.progress.listened": "percentage; the unit does not inflect",
        "a11y.activity.percent": "'percent' is invariant in every target language",
        "notes.sync.partialFailure": "past participles used adverbially; invariant",
    ]

    // MARK: - Invariant: every counted string has plural rules

    /// Detection reads the English **value**, not the key.
    ///
    /// A symbolic key hides its count in the `defaultValue`:
    /// `siri.queue.episodeCount` carries no `%lld` in its name but renders
    /// "You have %lld episodes in your queue." Keying on the name alone would
    /// have skipped every symbolic counted string in the catalog — which is
    /// most of the counted strings here.
    func test_everyCountedKey_hasPluralRules() throws {
        var missing: [String] = []
        var inspected = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            for (key, value) in LocalizationCatalogFixture.strings(in: parsed) {
                let entry = value as? [String: Any] ?? [:]
                let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]

                // Already pluralised, in either representation.
                if english?["variations"] != nil || english?["substitutions"] != nil { continue }

                let unit = english?["stringUnit"] as? [String: Any]
                let rendered = (unit?["value"] as? String) ?? key
                guard Self.hasNumericSpecifier(rendered),
                      Self.countsWithoutAgreement[key] == nil else { continue }

                inspected += 1
                missing.append("\(catalog.path): \(key.debugDescription) → \(rendered.debugDescription)")
            }
        }

        XCTAssertTrue(missing.isEmpty, """
        \(inspected) counted strings have no plural rules:

          \(missing.sorted().joined(separator: "\n  "))

        Add `variations.plural` with a hand-written singular, or — when two
        counts each govern their own noun — `substitutions`. If the count
        governs nothing (a badge, a unit, a position), add it to
        countsWithoutAgreement with a reason.
        """)
    }

    /// The exemption list must describe strings that exist. A typo'd or
    /// renamed key would silently excuse nothing while looking deliberate.
    func test_everyExemptedCount_stillExists() throws {
        var present: Set<String> = []
        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            present.formUnion(LocalizationCatalogFixture.strings(in: parsed).keys)
        }
        let stale = Set(Self.countsWithoutAgreement.keys).subtracting(present)
        XCTAssertTrue(stale.isEmpty,
                      "countsWithoutAgreement excuses keys that no longer exist: \(stale.sorted())")
    }

    // MARK: - Invariant: no Swift source hand-rolls a plural

    /// Scans source, not catalogs, because three of the five instances found
    /// built spoken Siri dialog as plain `String` and never reached a
    /// catalog at all. A catalog-only guard reported them clean.
    func test_noSourceHandRollsAPlural() throws {
        let root = LocalizationCatalogFixture.repositoryRoot
        var findings: [String] = []
        var scanned = 0

        for target in ["YourPods", "YourPodsWatch", "YourPodsWidgets", "YourPodsComplication"] {
            let base = root.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard !url.path.contains("/YourPodsTests/"),
                      let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.range(of: Self.handRolledPlural, options: .regularExpression) != nil {
                    findings.append("\(url.lastPathComponent):\(offset + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 100, "only \(scanned) Swift files scanned — the walk is broken")
        XCTAssertTrue(findings.isEmpty, """
        Hand-rolled plural — English grammar encoded where no translator can reach it:

          \(findings.sorted().joined(separator: "\n  "))

        Use String(localized:defaultValue:comment:) and put the plural rules in
        the catalog.
        """)
    }

    // MARK: - Scanners

    static let handRolledPlural = #"[=!><]=? *1 *\? *"s?" *: *"s?""#

    static func hasNumericSpecifier(_ value: String) -> Bool {
        value.range(of: #"%(\d+\$)?(lld|d|u|zd)"#, options: .regularExpression) != nil
    }

    // MARK: - Scanner self-checks
    //
    // A scanner that cannot report a hit is not a scanner.

    func test_countScanner_selfChecks() {
        XCTAssertTrue(Self.hasNumericSpecifier("%lld episodes"))
        XCTAssertTrue(Self.hasNumericSpecifier("Recurred %lld times"))
        XCTAssertTrue(Self.hasNumericSpecifier("Daily listening chart, %1$lld days"))
        XCTAssertFalse(Self.hasNumericSpecifier("Play %@"), "a string argument is not a count")
        XCTAssertFalse(Self.hasNumericSpecifier("Done"))
    }

    func test_handRolledPluralScanner_selfChecks() {
        let originals = [
            #"Text("\(count) podcast\(count == 1 ? "" : "s")")"#,
            #"Text("\(podcasts.count) podcast\(podcasts.count == 1 ? "" : "s") selected")"#,
            #": "You have \(snaps.count) episode\(snaps.count == 1 ? "" : "s") in your queue.""#,
        ]
        for original in originals {
            XCTAssertNotNil(original.range(of: Self.handRolledPlural, options: .regularExpression),
                            "the scanner must match the shape it was written to catch: \(original)")
        }
        XCTAssertNil(#"let isSingle = count == 1"#.range(of: Self.handRolledPlural, options: .regularExpression),
                     "a plain comparison against 1 is not a hand-rolled plural")
    }
}

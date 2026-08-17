import XCTest

/// Guards the nine String Catalogs against three failure modes.
///
/// `xcstringstool` validates none of them: a catalog with a bogus `state`, a
/// German string that drops an argument, and a key made entirely of `%@`
/// all compile with exit 0 and ship.
///
/// 1. **Degenerate keys** — a key with no words is one translation shared by
///    every unrelated call site that produced it, handed to a translator with
///    nothing to translate. An embarrassment, and unfixable after the fact:
///    once `"%@, %@"` has five owners you cannot give it a comment.
/// 2. **Format-specifier parity** — the only guard here preventing a *crash*
///    rather than an embarrassment. `String(format:)` reads its arguments
///    positionally off the stack; a translation that drops a `%@`, changes
///    `%lld` to `%@`, or reorders without `%1$@` markers crashes in exactly
///    one locale — the one nobody on the team runs.
/// 3. **Catalog schema** — the shapes Xcode writes and the tooling assumes.
///
/// The parity invariant is vacuous today: no non-English localization exists
/// yet. It is written now because the first translation batch is the moment
/// it starts mattering, and nobody writes a guard in the middle of a
/// 900-string translation review. `test_parityScanner_selfChecks` proves the
/// comparison fires, and `test_everyCatalog_resolvesAndIsPopulated` proves
/// the walk that feeds it is live.
///
/// This file embeds degenerate keys and malformed catalogs as fixtures. That
/// is safe because the scan reads `.xcstrings` files, never Swift sources, and
/// because `YourPodsTests` is not a localized target — no literal in here is
/// ever extracted. Both facts are asserted below rather than assumed.
final class LocalizationCatalogGuardTests: XCTestCase {

    // MARK: - Catalogs
    //
    // Every catalog in the repo, with a key-count floor. A floor is the only
    // thing standing between "this catalog is clean" and "this path stopped
    // resolving three months ago" — both report zero violations.

    private static let catalogs: [(path: String, floor: Int)] = [
        ("YourPods/YourPods/Localizable.xcstrings", 800),
        ("YourPods/YourPods/InfoPlist.xcstrings", 3),
        ("YourPods/YourPods/AppShortcuts.xcstrings", 10),
        ("YourPodsWatch/Localizable.xcstrings", 55),
        ("YourPodsWatch/InfoPlist.xcstrings", 2),
        ("YourPodsWidgets/Localizable.xcstrings", 18),
        ("YourPodsWidgets/InfoPlist.xcstrings", 2),
        // Four, not the six measured in Phase A: "▶ %@" and "⏸ %@" were the
        // complication's whole set of degenerate keys and are now verbatim.
        ("YourPodsComplication/Localizable.xcstrings", 3),
        ("YourPodsComplication/InfoPlist.xcstrings", 2),
    ]

    /// Legal `state` values for a `stringUnit` or `stringSet`.
    private static let legalStates: Set<String> = ["new", "needs_review", "translated", "stale"]

    /// Legal `extractionState` values for a catalog entry.
    private static let legalExtractionStates: Set<String> =
        ["manual", "extracted_with_value", "migrated", "stale"]

    /// Legal plural categories (CLDR).
    private static let legalPluralCases: Set<String> = ["zero", "one", "two", "few", "many", "other"]


    private func repoRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)   // …/YourPodsTests/ThisFile.swift
        root.deleteLastPathComponent()               // …/YourPodsTests
        root.deleteLastPathComponent()               // repo root
        return root
    }

    private func load(_ relative: String) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent(relative)
        let data = try XCTUnwrap(try? Data(contentsOf: url),
            "cannot read \(relative) — the catalog moved or was deleted; update `catalogs`")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(relative) is not a JSON object")
        return json
    }

    private func strings(in catalog: [String: Any]) -> [String: [String: Any]] {
        (catalog["strings"] as? [String: [String: Any]]) ?? [:]
    }

    // MARK: - Scanner: degenerate keys
    //
    // Statics so the real scan and the self-checks share one decision
    // function. A test that re-derives its own copy of "what counts" drifts
    // from the scanner and keeps passing while the scanner rots.

    /// Every format specifier in a string: `%@`, `%lld`, `%1$@`, `%.1f`, …
    ///
    /// `%%` is an escaped literal percent, not a specifier, and must not be
    /// collected — `"%lld%% listened"` takes one argument, not two.
    static func specifiers(in format: String) -> [String] {
        var out: [String] = []
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { i += 1; continue }
            var j = i + 1
            if j < chars.count, chars[j] == "%" { i = j + 2; continue }   // %% literal

            // `%#@name@` is a substitution *reference*, not a format
            // specifier — the plural forms behind it carry the real
            // specifiers, and the schema guard validates those separately.
            // Read as a specifier it looks like a bare `%@`, which makes a
            // template such as "Showing newest %1$lld — %#@older@ hidden"
            // appear to mix positional and unmarked arguments. That is how
            // the English template itself reads, so this fired on five
            // correct translations and would have fired on English too.
            if j + 1 < chars.count, chars[j] == "#", chars[j + 1] == "@" {
                var k = j + 2
                while k < chars.count, chars[k] != "@" { k += 1 }
                i = k < chars.count ? k + 1 : chars.count
                continue
            }

            var token = "%"
            // Positional index, flags, width, precision — anything before the
            // length modifier or conversion character.
            while j < chars.count, !"@dioxXufFeEgGcsSpaAl".contains(chars[j]) {
                token.append(chars[j]); j += 1
            }
            while j < chars.count, chars[j] == "l" { token.append(chars[j]); j += 1 }
            if j < chars.count { token.append(chars[j]); j += 1 }
            out.append(token)
            i = j
        }
        return out
    }

    /// A specifier's conversion type, with index/flags/width stripped:
    /// `%1$@` → `@`, `%lld` → `lld`, `%.1f` → `f`.
    static func conversionType(of specifier: String) -> String {
        var s = Substring(specifier.dropFirst())                 // drop '%'
        if let dollar = s.firstIndex(of: "$") { s = s[s.index(after: dollar)...] }
        s = s.drop(while: { "-+ #0123456789.*'".contains($0) })  // flags, width, precision
        return String(s)
    }

    /// A specifier's argument index: 2 for `%2$@`, nil for `%@`.
    static func positionalIndex(of specifier: String) -> Int? {
        guard let dollar = specifier.firstIndex(of: "$") else { return nil }
        return Int(specifier[specifier.index(after: specifier.startIndex)..<dollar])
    }

    /// True when a key carries no translatable word — only format specifiers,
    /// punctuation, symbols and whitespace.
    ///
    /// `"%@, %@"`, `"(%lld)"`, `"—"`, `"✓"`, `"%.1f×"` are all degenerate.
    /// `"%@ of %@"` is not: `of` is a word, and a translator can act on it.
    /// Keys that are a bare number or a single word (`"15"`, `"OK"`) are
    /// *poor* but not degenerate — they carry content — and are handled by
    /// `extractionState: manual`, not here.
    ///
    /// The empty key is degenerate and is **never** exempted. An earlier
    /// version of this guard skipped it, on the strength of a scan that
    /// concluded no source emitted it. That scan was wrong — it tested
    /// `"" in entries` against a list of dictionaries, so it could only ever
    /// return false. The two real sources were `.accessibilityValue({ … }())`
    /// closures whose `guard else { return "" }` Xcode records as a
    /// localizable string. Both are fixed. If an empty key returns, it means
    /// another one appeared, and this test is how we find out.
    static func isDegenerate(key: String) -> Bool {
        guard !key.isEmpty else { return true }
        var rest = key
        for specifier in specifiers(in: key) {
            if let r = rest.range(of: specifier) { rest.removeSubrange(r) }
        }
        rest = rest.replacingOccurrences(of: "%%", with: "")
        return !rest.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: - Scanner: specifier parity

    /// Reasons `translated` cannot safely stand in for `english`.
    ///
    /// Returns human-readable failures rather than a Bool so the real scan and
    /// the self-checks agree on *why*, not just whether.
    ///
    /// An unmarked translation is not a defect by itself. Swift string
    /// interpolation always emits `%@ %@` — it has no syntax that produces
    /// `%1$@ %2$@` — so demanding positional markers in English would be an
    /// invariant no source file could satisfy. What matters is narrower:
    /// unmarked arguments are consumed in written order, so an unmarked
    /// translation must keep English's *sequence* of types. A translator who
    /// needs a different order writes the markers, and then every index must
    /// name an argument English actually supplies, of the type it supplies.
    static func parityFailures(english: String, translated: String) -> [String] {
        var out: [String] = []
        let base = specifiers(in: english)
        let mine = specifiers(in: translated)
        let baseTypes = base.map(conversionType(of:))
        let mineTypes = mine.map(conversionType(of:))

        guard mineTypes.sorted() == baseTypes.sorted() else {
            // Once the sets differ, every ordering check below is noise.
            return ["specifier set is \(mineTypes.sorted()) but English is \(baseTypes.sorted())"]
        }

        let indices = mine.map(positionalIndex(of:))
        let marked = indices.compactMap { $0 }.count

        if marked > 0, marked < mine.count {
            return ["mixes positional (%1$@) and non-positional (%@) specifiers — String(format:) is undefined for that"]
        }

        guard marked > 0 else {
            if mineTypes != baseTypes {
                out.append("reorders arguments as \(mineTypes) where English supplies \(baseTypes), with no positional markers — the format reads the wrong argument off the stack. Use %1$@ / %2$@.")
            }
            return out
        }

        for (specifier, index) in zip(mine, indices) {
            guard let index else { continue }
            guard index >= 1, index <= base.count else {
                out.append("\(specifier) refers to argument \(index) but English supplies \(base.count)")
                continue
            }
            let expected = baseTypes[index - 1]
            if conversionType(of: specifier) != expected {
                out.append("\(specifier) is argument \(index), which English types as %\(expected)")
            }
        }
        return out
    }

    // MARK: - Scanner: schema

    /// Structural failures in one parsed catalog.
    static func schemaFailures(in catalog: [String: Any], name: String) -> [String] {
        var out: [String] = []

        guard let source = catalog["sourceLanguage"] as? String else {
            return ["\(name): missing sourceLanguage"]
        }
        if source != "en" { out.append("\(name): sourceLanguage is '\(source)', expected 'en'") }
        if catalog["version"] == nil { out.append("\(name): missing version") }
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            out.append("\(name): missing or malformed 'strings'")
            return out
        }

        for (key, entry) in strings {
            let label = "\(name) '\(key)'"

            if let extraction = entry["extractionState"] as? String,
               !legalExtractionStates.contains(extraction) {
                out.append("\(label): illegal extractionState '\(extraction)'")
            }

            guard let localizations = entry["localizations"] as? [String: [String: Any]] else {
                if entry["localizations"] != nil { out.append("\(label): malformed 'localizations'") }
                continue   // an entry with no localizations is normal — extracted, untranslated
            }

            for (language, localization) in localizations {
                let where_ = "\(label) [\(language)]"
                let forms = ["stringUnit", "stringSet", "variations"].filter { localization[$0] != nil }
                if forms.count != 1 {
                    out.append("\(where_): expected exactly one of stringUnit/stringSet/variations, found \(forms.sorted())")
                }

                if let unit = localization["stringUnit"] as? [String: Any] {
                    out += stringUnitFailures(unit, where_: where_)
                }
                if let set = localization["stringSet"] as? [String: Any] {
                    if let state = set["state"] as? String, !legalStates.contains(state) {
                        out.append("\(where_): illegal stringSet state '\(state)'")
                    }
                    if (set["values"] as? [String])?.isEmpty ?? true {
                        out.append("\(where_): stringSet has no values")
                    }
                }
                if let variations = localization["variations"] as? [String: Any] {
                    out += variationFailures(variations, where_: where_)
                }
                if let substitutions = localization["substitutions"] as? [String: Any] {
                    out += substitutionFailures(substitutions,
                                                template: (localization["stringUnit"] as? [String: Any])?["value"] as? String,
                                                where_: where_)
                }
            }
        }
        return out
    }

    private static func stringUnitFailures(_ unit: [String: Any], where_: String) -> [String] {
        var out: [String] = []
        if let state = unit["state"] as? String {
            if !legalStates.contains(state) { out.append("\(where_): illegal state '\(state)'") }
        } else {
            out.append("\(where_): stringUnit has no state")
        }
        if unit["value"] as? String == nil { out.append("\(where_): stringUnit has no value") }
        return out
    }

    /// Validates the `substitutions` form, used when one string carries two
    /// counts that each govern their own noun — "Showing the newest 3
    /// episodes. 1 older episode is hidden." A single `variations.plural`
    /// cannot express that, because only one of the two counts could drive it.
    ///
    /// The shape is easy to get subtly wrong and fails at the user rather than
    /// at build time: a name declared in `substitutions` but absent from the
    /// template renders nothing, and a `%#@name@` with no matching entry
    /// renders literally as "%#@name@".
    private static func substitutionFailures(_ substitutions: [String: Any],
                                             template: String?,
                                             where_: String) -> [String] {
        var out: [String] = []
        guard let template else {
            return ["\(where_): has substitutions but no stringUnit to substitute into"]
        }

        for (name, body) in substitutions {
            guard let body = body as? [String: Any] else {
                out.append("\(where_) substitution '\(name)': malformed")
                continue
            }
            if body["argNum"] as? Int == nil {
                out.append("\(where_) substitution '\(name)': missing or non-integer argNum")
            }
            if (body["formatSpecifier"] as? String)?.isEmpty ?? true {
                out.append("\(where_) substitution '\(name)': missing formatSpecifier")
            }
            if let variations = body["variations"] as? [String: Any] {
                out += variationFailures(variations, where_: "\(where_) substitution '\(name)'")
            } else {
                out.append("\(where_) substitution '\(name)': missing variations")
            }
            if !template.contains("%#@\(name)@") {
                out.append("\(where_) substitution '\(name)': declared but never referenced as %#@\(name)@ in the template")
            }
        }

        // The reverse direction: a reference with nothing behind it renders raw.
        var scanner = Substring(template)
        while let open = scanner.range(of: "%#@") {
            let rest = scanner[open.upperBound...]
            guard let close = rest.firstIndex(of: "@") else {
                out.append("\(where_): unterminated %#@ reference in the template")
                break
            }
            let name = String(rest[rest.startIndex..<close])
            if substitutions[name] == nil {
                out.append("\(where_): template references %#@\(name)@ but no such substitution is defined")
            }
            scanner = rest[rest.index(after: close)...]
        }
        return out
    }

    private static func variationFailures(_ variations: [String: Any], where_: String) -> [String] {
        var out: [String] = []
        for (kind, body) in variations {
            guard kind == "plural" || kind == "device" else {
                out.append("\(where_): unknown variation kind '\(kind)'")
                continue
            }
            guard let cases = body as? [String: [String: Any]], !cases.isEmpty else {
                out.append("\(where_): variation '\(kind)' has no cases")
                continue
            }
            if kind == "plural" {
                let illegal = Set(cases.keys).subtracting(legalPluralCases)
                if !illegal.isEmpty {
                    out.append("\(where_): illegal plural categories \(illegal.sorted())")
                }
                // Without `other`, a language whose rules select a category
                // this entry does not define renders the raw key.
                if cases["other"] == nil {
                    out.append("\(where_): plural variation has no 'other' case")
                }
            }
            for (category, wrapper) in cases {
                guard let unit = wrapper["stringUnit"] as? [String: Any] else {
                    out.append("\(where_) \(kind).\(category): missing stringUnit")
                    continue
                }
                out += stringUnitFailures(unit, where_: "\(where_) \(kind).\(category)")
            }
        }
        return out
    }

    // MARK: - Invariant: every catalog resolves and is populated

    /// Trap: a catalog path that stops resolving reports zero violations for
    /// every invariant below. Nine silent passes look exactly like nine real
    /// ones.
    func test_everyCatalog_resolvesAndIsPopulated() throws {
        for catalog in Self.catalogs {
            let parsed = try load(catalog.path)
            let count = strings(in: parsed).count
            XCTAssertGreaterThanOrEqual(count, catalog.floor,
                "\(catalog.path) holds \(count) keys, below its floor of \(catalog.floor) — the catalog moved, was truncated, or the walk is broken")
        }
    }

    // MARK: - Invariant: no degenerate keys

    func test_noCatalogContainsADegenerateKey() throws {
        var findings: [String] = []
        var inspected = 0

        for catalog in Self.catalogs {
            let parsed = try load(catalog.path)
            for key in strings(in: parsed).keys.sorted() {
                inspected += 1
                if Self.isDegenerate(key: key) {
                    findings.append("\(catalog.path): \(key.debugDescription)")
                }
            }
        }

        XCTAssertGreaterThan(inspected, 900, "the scan inspected \(inspected) keys — implausibly few")
        XCTAssertTrue(findings.isEmpty, """
        Degenerate catalog key — no word for a translator to translate:

          \(findings.joined(separator: "\n  "))

        A key like "%@, %@" is derived from the source literal, so every
        unrelated call site that happens to write two interpolations joined by
        a comma shares one catalog entry, one comment, and one translation.

        Fix at the call site, not in the catalog:
          - Runtime content (episode title, transcript text, a count) →
            Text(verbatim:) or Text(value, format: .number). It was never
            translatable and should not be in the catalog at all.
          - A real sentence → String(localized: "namespace.thing",
            defaultValue: "…", comment: "…") so the key names the thing and
            the comment says what each argument is.
        """)
    }

    // MARK: - Invariant: every key carries translator context

    /// A key with no comment is a key the translator has to guess at.
    ///
    /// "Done" dismisses a sheet in one place and finishes reordering in
    /// another, and German wants a different word for each. "Watch" is a verb
    /// here and a wristwatch three screens away. None of that is recoverable
    /// from the English string alone, which is all a translator sees.
    ///
    /// Comments live in the catalog, not at the call site: a catalog-authored
    /// comment was measured to survive a build untouched, so 900 of these were
    /// written without changing a line of Swift.
    func test_everyKeyCarriesATranslatorComment() throws {
        var uncommented: [String] = []
        var inspected = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            for (key, value) in LocalizationCatalogFixture.strings(in: parsed) {
                inspected += 1
                let entry = value as? [String: Any] ?? [:]
                let comment = (entry["comment"] as? String) ?? ""
                if comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    uncommented.append("\(catalog.path): \(key.debugDescription)")
                }
            }
        }

        XCTAssertGreaterThan(inspected, 900,
            "only \(inspected) keys inspected — the walk is broken, not the catalogs commented")
        XCTAssertTrue(uncommented.isEmpty, """
        \(uncommented.count) keys have no translator comment:

          \(uncommented.sorted().prefix(40).joined(separator: "\n  "))

        Say what the string does, where it appears, and what each argument is.
        Write it in the catalog — the call site does not need to change.
        """)
    }

    // MARK: - Invariant: no concept is spelled two ways

    /// Pairs that really are two strings, each with a reason.
    ///
    /// Apple's HIG puts a question mark on a destructive alert title and an
    /// ellipsis on anything that opens further UI, so those pairs differ by
    /// design. The App Intents titles differ from their spoken-phrase
    /// counterparts and belong to Phase C's Siri surface, not here.
    static let allowedCaseVariants: [String: String] = [
        "delete all downloads": "button label vs. the alert title that confirms it, which HIG ends with '?'",
        "delete download": "button label vs. confirmation alert title",
        "delete profile": "button label vs. confirmation alert title",
        "share": "menu verb vs. 'Share…', where HIG's ellipsis means a sheet follows",
        "move to group": "static label vs. 'Move to Group…', which opens a picker",
        "new group": "static label vs. 'New Group…', which opens a text field",
        "skip forward 30 seconds": "VoiceOver label vs. the App Intent description, a sentence ending in a period",
        "username": "field label vs. 'username', the greyed sample value inside the field",
        "password": "field label vs. 'password', the greyed sample value inside the field — the same split as username",
        "check for new episodes": "App Intent title vs. spoken shortcut phrase — Phase C",
        "pause playback": "App Intent title vs. spoken shortcut phrase — Phase C",
        "play my queue": "App Intent title vs. spoken shortcut phrase — Phase C",
        "resume playback": "App Intent title vs. spoken shortcut phrase — Phase C",
        "skip backward": "App Intent title vs. spoken shortcut phrase — Phase C",
        "skip forward": "App Intent title vs. spoken shortcut phrase — Phase C",
        "stop playback": "App Intent title vs. spoken shortcut phrase — Phase C",
    ]

    /// Two keys differing only by capitalization or trailing punctuation are
    /// one concept that will be translated twice and drift apart.
    ///
    /// The measured shape was almost always a visible Title Case label beside
    /// its own `.accessibilityLabel` in sentence case — "Sleep Timer" and
    /// "Sleep timer" on the same control. VoiceOver reads them identically, so
    /// the second entry bought nothing and cost a translation.
    func test_noCatalogContainsCaseVariantDuplicates() throws {
        var findings: [String] = []
        var inspected = 0

        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            var groups: [String: [String]] = [:]
            for key in LocalizationCatalogFixture.strings(in: parsed).keys {
                inspected += 1
                let normalized = key.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".…?!"))
                groups[normalized, default: []].append(key)
            }
            for (normalized, keys) in groups
            where keys.count > 1 && Self.allowedCaseVariants[normalized] == nil {
                findings.append("\(catalog.path): \(keys.sorted().map(\.debugDescription).joined(separator: " | "))")
            }
        }

        XCTAssertGreaterThan(inspected, 900, "the scan inspected \(inspected) keys — implausibly few")
        XCTAssertTrue(findings.isEmpty, """
        The same concept is spelled two ways, so it will be translated twice:

          \(findings.sorted().joined(separator: "\n  "))

        Pick one spelling at the call sites. If the two really are different
        strings, add the normalized form to allowedCaseVariants with a reason.
        """)
    }

    // MARK: - Invariant: no key is only a number

    /// Sample values and product names, not copy — a user types over them or
    /// reads them as an example, so a translation would mislead. They stay
    /// catalog keys because the platform wants a `Text` in these positions.
    static let nonCopyKeys: Set<String> = [
        "https://gpodder.net",
        "https://cloud.example.com",
        "you@example.com",
        "yourpods-ios",
        "WebDAV",
        "P3",
        "YourPods",
    ]

    /// `isDegenerate` counts a digit as content, on purpose: `"%@, %@"` is a
    /// different hazard from `"15"`. This is the second one.
    ///
    /// Ten picker rows shipped as the catalog keys `1`, `3`, `5`, `9`, `10`,
    /// `15`, `21`, `25`, `27`, `36`. Asking five translators what `15` means
    /// in German wastes their time in the good case and invents a
    /// mistranslated number in the bad one. A count belongs in
    /// `Text(n.formatted())`, which also renders the digits in the user's
    /// locale rather than freezing Western ones into a literal.
    func test_noCatalogContainsANumberOnlyKey() throws {
        var findings: [String] = []
        var inspected = 0

        for catalog in Self.catalogs {
            let parsed = try load(catalog.path)
            for key in strings(in: parsed).keys.sorted() where !Self.nonCopyKeys.contains(key) {
                inspected += 1
                var rest = key
                for specifier in Self.specifiers(in: key) {
                    if let range = rest.range(of: specifier) { rest.removeSubrange(range) }
                }
                if !rest.isEmpty, !rest.contains(where: { $0.isLetter }), rest.contains(where: { $0.isNumber }) {
                    findings.append("\(catalog.path): \(key.debugDescription)")
                }
            }
        }

        XCTAssertGreaterThan(inspected, 900, "the scan inspected \(inspected) keys — implausibly few")
        XCTAssertTrue(findings.isEmpty, """
        Catalog key that is only a number:

          \(findings.joined(separator: "\n  "))

        Nothing here is translatable. Render it with Text(n.formatted()) so it
        never enters the catalog and picks up the reader's digit conventions.
        """)
    }

    func test_numberOnlyScanner_selfChecks() {
        func isNumberOnly(_ key: String) -> Bool {
            var rest = key
            for specifier in Self.specifiers(in: key) {
                if let range = rest.range(of: specifier) { rest.removeSubrange(range) }
            }
            return !rest.isEmpty && !rest.contains(where: { $0.isLetter }) && rest.contains(where: { $0.isNumber })
        }
        XCTAssertTrue(isNumberOnly("15"), "a bare count is not copy")
        XCTAssertTrue(isNumberOnly("36"), "a bare count is not copy")
        XCTAssertFalse(isNumberOnly("15 minutes"), "a count with a unit is copy")
        XCTAssertFalse(isNumberOnly("Done"), "ordinary copy is not a number")
        XCTAssertFalse(isNumberOnly("%lld episodes"), "the specifier is stripped, the word remains")
        XCTAssertFalse(isNumberOnly("%@, %@"), "that is the degenerate hazard, guarded separately")
    }

    // MARK: - Invariant: translations match English's format specifiers

    func test_everyTranslation_matchesEnglishSpecifiers() throws {
        var findings: [String] = []
        var keysVisited = 0
        var comparisons = 0

        for catalog in Self.catalogs {
            let parsed = try load(catalog.path)
            for (key, entry) in strings(in: parsed) {
                keysVisited += 1
                guard let localizations = entry["localizations"] as? [String: [String: Any]] else { continue }

                // English is the source of truth — but it is not always a
                // `stringUnit`. A key whose English is plural `variations`
                // carries its specifiers inside the plural cases, and reading
                // only `stringUnit` fell back to the key name, which for a
                // symbolic key like `library.group.podcastCount` contains no
                // specifiers at all. Every counted symbolic key then looked
                // like a translation that had invented a `%lld`.
                //
                // So English is decomposed with the same helper as the
                // translations, and compared label to label.
                var englishByLabel: [String: String] = [:]
                if let englishLocalization = localizations["en"] {
                    for (label, value) in Self.translatedValues(in: englishLocalization) {
                        englishByLabel[label] = value
                    }
                }
                let englishFallback = englishByLabel[""] ?? key

                for (language, localization) in localizations where language != "en" {
                    for (label, value) in Self.translatedValues(in: localization) {
                        comparisons += 1
                        // Same label where English has one — a `plural.one`
                        // against English's `plural.one`. Otherwise the
                        // top-level English, since a language may supply
                        // plural cases English does not have.
                        let english = englishByLabel[label] ?? englishFallback
                        for reason in Self.parityFailures(english: english, translated: value) {
                            findings.append("\(catalog.path) [\(language)]\(label) '\(key)': \(reason)")
                        }
                    }
                }
            }
        }

        XCTAssertGreaterThan(keysVisited, 900,
            "the parity walk visited \(keysVisited) keys — it is not reaching the catalogs")
        XCTAssertTrue(findings.isEmpty, """
        Translation does not match English's format arguments:

          \(findings.joined(separator: "\n  "))

        String(format:) reads arguments positionally off the stack. A dropped
        or retyped specifier crashes in that language and no other — including
        on a reviewer's English device. Reordering is legal only when every
        specifier is positional (%1$@, %2$@).
        """)

        // Asserted, not printed. This was "recorded rather than asserted"
        // while no translation existed and the count was legitimately 0. Five
        // languages have landed, so a zero here now means the comparison
        // stopped running — the exact shape of failure this file exists to
        // refuse, and one that would otherwise read as a clean pass.
        XCTAssertGreaterThan(comparisons, 4_000,
            "only \(comparisons) specifier comparisons across \(keysVisited) keys — with five languages in the catalogs this should be in the thousands, so the walk is no longer reaching the translations")
    }

    /// Every non-English value in one localization, flattened across
    /// `stringUnit`, `stringSet` and plural/device `variations`.
    static func translatedValues(in localization: [String: Any]) -> [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
            out.append(("", value))
        }
        if let values = (localization["stringSet"] as? [String: Any])?["values"] as? [String] {
            for (i, value) in values.enumerated() { out.append((" stringSet[\(i)]", value)) }
        }
        if let variations = localization["variations"] as? [String: [String: [String: Any]]] {
            for (kind, cases) in variations {
                for (category, wrapper) in cases {
                    if let value = (wrapper["stringUnit"] as? [String: Any])?["value"] as? String {
                        out.append((" \(kind).\(category)", value))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Invariant: catalog schema

    func test_everyCatalog_hasAWellFormedSchema() throws {
        var findings: [String] = []
        for catalog in Self.catalogs {
            findings += Self.schemaFailures(in: try load(catalog.path),
                                            name: catalog.path)
        }
        XCTAssertTrue(findings.isEmpty, """
        Malformed String Catalog:

          \(findings.joined(separator: "\n  "))

        xcstringstool accepts all of these and ships them. A bogus state is
        invisible until a translator's tool refuses the file; a plural
        variation missing its 'other' case renders the raw key in whichever
        language selects it.
        """)
    }

    // MARK: - Invariant: a shared key means the same thing in every catalog

    /// One key, several catalogs, one meaning.
    ///
    /// `DurationFormatting.swift` and `EpisodeAccessibility.swift` are compiled
    /// into the app, the watch app and the widget extension, so their keys
    /// extract into three separate catalogs — and `-exportLocalizations`
    /// writes each independently. A plural variation hand-authored in one
    /// comes back as a flat `stringUnit` in the others.
    ///
    /// Measured on this branch: `a11y.duration.hours` carried `one`/`other`
    /// in the app and a bare `%lld hours` on the watch and in every widget, so
    /// a one-hour episode was spoken as "1 hour" in the app and "1 hours"
    /// everywhere else. Nothing failed; the plural rule was simply absent in
    /// two of three bundles.
    ///
    /// `InfoPlist.xcstrings` is excluded from the value check: `CFBundleName`
    /// and `CFBundleDisplayName` are *supposed* to differ per bundle.
    func test_sharedKeys_haveTheSameShapeInEveryCatalog() throws {
        var occurrences: [String: [(catalog: String, hasPlural: Bool, english: String)]] = [:]

        for catalog in Self.catalogs where !catalog.path.hasSuffix("InfoPlist.xcstrings") {
            for (key, entry) in strings(in: try load(catalog.path)) {
                let english = (entry["localizations"] as? [String: [String: Any]])?["en"]
                let hasPlural = ((english?["variations"] as? [String: Any])?["plural"]) != nil
                let value = (english?["stringUnit"] as? [String: Any])?["value"] as? String ?? key
                occurrences[key, default: []].append((catalog.path, hasPlural, value))
            }
        }

        let shared = occurrences.filter { $0.value.count > 1 }
        XCTAssertGreaterThan(shared.count, 20,
            "only \(shared.count) keys were found in more than one catalog — the shared-source targets are not being scanned")

        var findings: [String] = []
        for (key, sites) in shared.sorted(by: { $0.key < $1.key }) {
            let withPlural = sites.filter(\.hasPlural).map(\.catalog).sorted()
            let without = sites.filter { !$0.hasPlural }.map(\.catalog).sorted()
            if !withPlural.isEmpty, !without.isEmpty {
                findings.append("'\(key)': plural variations in \(withPlural) but not in \(without)")
            }
            let values = Set(sites.filter { !$0.hasPlural }.map(\.english))
            if values.count > 1 {
                findings.append("'\(key)': different English in different catalogs — \(values.sorted())")
            }
        }

        XCTAssertTrue(findings.isEmpty, """
        A key means two different things depending on which bundle reads it:

          \(findings.joined(separator: "\n  "))

        Shared source compiled into several targets extracts into each
        target's catalog separately, and -exportLocalizations writes a flat
        stringUnit every time. Hand-authored plural variations must be added
        to every catalog that carries the key, or the watch and the widgets
        say "1 hours" while the app says "1 hour".
        """)
    }

    // MARK: - Invariant: App Shortcut phrases carry ${applicationName}

    /// Every App Shortcut phrase must contain the app-name token or the
    /// shortcut does not register — Siri has nothing to disambiguate it by.
    ///
    /// The token renders as `${applicationName}` in the catalog, **not** the
    /// `\(.applicationName)` written in Swift. A guard checking for the Swift
    /// spelling passes on an empty match set forever.
    func test_everyAppShortcutPhrase_containsApplicationNameToken() throws {
        let path = "YourPods/YourPods/AppShortcuts.xcstrings"
        let parsed = try load(path)
        var findings: [String] = []
        var phrases = 0

        for (key, entry) in strings(in: parsed) {
            guard let localizations = entry["localizations"] as? [String: [String: Any]] else {
                findings.append("'\(key)': no localizations — the phrase set is empty")
                continue
            }
            for (language, localization) in localizations {
                var values = Self.translatedValues(in: localization).map(\.value)
                if language == "en",
                   let english = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
                    values.append(english)
                }
                for value in values {
                    phrases += 1
                    if !value.contains("${applicationName}") {
                        findings.append("'\(key)' [\(language)]: \(value.debugDescription) has no ${applicationName}")
                    }
                }
            }
        }

        XCTAssertGreaterThanOrEqual(phrases, 20, "only \(phrases) App Shortcut phrases were checked")
        XCTAssertTrue(findings.isEmpty, """
        App Shortcut phrase without ${applicationName}:

          \(findings.joined(separator: "\n  "))

        A phrase missing the token does not register with Siri at all.
        """)
    }

    // MARK: - Self-checks
    //
    // A guard whose scanner cannot fire is not evidence. Each of these drives
    // the same static the real scan uses.

    func test_specifierScanner_selfChecks() {
        let cases: [(String, [String], String)] = [
            ("%@", ["%@"], "bare object specifier"),
            ("%@ of %@", ["%@", "%@"], "two objects"),
            ("%lld", ["%lld"], "long long"),
            ("%1$@ then %2$@", ["%1$@", "%2$@"], "positional markers are part of the token"),
            ("%.1f×", ["%.1f"], "precision is part of the token"),
            ("%lld%% listened", ["%lld"], "%% is a literal percent, not a specifier"),
            ("100%% done", [], "escaped percent alone yields no specifiers"),
            ("no arguments here", [], "plain prose"),
            ("%lld%% · %@ / %@", ["%lld", "%@", "%@"], "mixed, with an escaped percent"),
        ]
        for (input, expected, why) in cases {
            XCTAssertEqual(Self.specifiers(in: input), expected,
                           "specifiers(in: \(input.debugDescription)) — \(why)")
        }

        // Substitution references. These fired on five correct translations
        // before the scanner learned to skip them, because `%#@older@` read as
        // a bare `%@` and made the string look like it mixed positional and
        // unmarked arguments — which the English template does too.
        XCTAssertEqual(Self.specifiers(in: "Showing newest %1$lld — %#@older@ hidden"), ["%1$lld"],
                       "a %#@name@ reference is not a format specifier")
        XCTAssertEqual(Self.specifiers(in: "%#@a@ and %#@b@"), [],
                       "a template of nothing but substitution references supplies no specifiers")
        XCTAssertEqual(Self.specifiers(in: "%#@a@ of %lld"), ["%lld"],
                       "the real specifiers around a reference are still found")
        XCTAssertEqual(Self.specifiers(in: "%#@unterminated"), [],
                       "an unterminated reference must not run off the end or emit a token")

        XCTAssertEqual(Self.conversionType(of: "%1$@"), "@")
        XCTAssertEqual(Self.conversionType(of: "%lld"), "lld")
        XCTAssertEqual(Self.conversionType(of: "%.1f"), "f")
        XCTAssertEqual(Self.conversionType(of: "%@"), "@")
        XCTAssertEqual(Self.positionalIndex(of: "%2$@"), 2)
        XCTAssertNil(Self.positionalIndex(of: "%@"))
    }

    func test_degenerateScanner_selfChecks() {
        let cases: [(String, Bool, String)] = [
            ("%@, %@", true, "two arguments and a comma carry no meaning"),
            ("%@: %@, %@", true, "punctuation only"),
            ("(%lld)", true, "a count in parentheses"),
            ("-%@", true, "a minus and an argument"),
            ("—", true, "an em dash placeholder was never translatable"),
            ("✓", true, "a checkmark glyph"),
            ("·", true, "a separator"),
            ("%.1f×", true, "a speed readout is a number and a symbol"),
            ("▶ %@", true, "a glyph and runtime content"),
            ("%lld%% · %@ / %@", true, "specifiers, a percent and a slash"),
            ("%@ of %@", false, "'of' is a word a translator can act on"),
            ("%lld episodes", false, "carries a noun"),
            ("100%% done", false, "carries a word"),
            ("15", false, "a bare number carries content — manual extraction, not degenerate"),
            ("OK", false, "a word, however short"),
            ("a11y.duration.hours", false, "a namespaced key"),
            ("", true, "an empty key"),
        ]
        for (key, expected, why) in cases {
            XCTAssertEqual(Self.isDegenerate(key: key), expected,
                           "isDegenerate(\(key.debugDescription)) — \(why)")
        }
    }

    func test_parityScanner_selfChecks() {
        let cases: [(english: String, translated: String, fails: Bool, why: String)] = [
            ("%@ of %@", "%@ von %@", false, "same specifiers, same order — the ordinary case"),
            ("%@ of %@", "%@ von", true, "an argument was dropped — reads past the stack"),
            ("%lld items", "%@ Artikel", true, "long long retyped as object"),
            ("100%% done", "100%% fertig", false, "no specifiers at all"),
            ("%1$@ of %2$@", "%2$@ von %1$@", false, "reordering is legal when positional"),
            ("%@ of %@", "%2$@ von %1$@", false, "a translation may add markers English does not have"),
            ("%@ of %@", "%2$@ von %@", true, "mixing marked and unmarked is undefined"),
            ("%@ episodes", "%@ Folgen", false, "single argument, no markers needed"),
            ("%@ · %@", "%@ · %@", false, "two unmarked arguments in English order are fine"),
            ("%lld of %@", "%@ von %lld", true, "unmarked reorder swaps an Int and an object — the crash"),
            ("%@ of %@", "%3$@ von %1$@", true, "argument 3 does not exist"),
            ("%lld of %@", "%1$@ von %2$lld", true, "marker 1 is typed %lld in English, not %@"),
        ]
        for c in cases {
            let failures = Self.parityFailures(english: c.english, translated: c.translated)
            XCTAssertEqual(!failures.isEmpty, c.fails,
                "parity(\(c.english.debugDescription) → \(c.translated.debugDescription)) — \(c.why)\n  got: \(failures)")
        }
    }

    func test_schemaScanner_selfChecks() {
        func catalog(_ strings: [String: Any]) -> [String: Any] {
            ["sourceLanguage": "en", "version": "1.0", "strings": strings]
        }
        func unit(_ value: String, _ state: String = "translated") -> [String: Any] {
            ["stringUnit": ["state": state, "value": value]]
        }

        XCTAssertTrue(Self.schemaFailures(in: catalog(["Play": ["localizations": ["en": unit("Play")]]]),
                                          name: "t").isEmpty,
                      "a well-formed entry must produce no findings")

        XCTAssertTrue(Self.schemaFailures(in: catalog(["Play": [:]]), name: "t").isEmpty,
                      "an extracted-but-unlocalized entry is normal, not a finding")

        let badState = Self.schemaFailures(in: catalog(["Play": ["localizations": ["en": unit("Play", "almost")]]]), name: "t")
        XCTAssertTrue(badState.contains { $0.contains("illegal state 'almost'") },
                      "an illegal state must be reported, got \(badState)")

        let badExtraction = Self.schemaFailures(
            in: catalog(["Play": ["extractionState": "invented", "localizations": ["en": unit("Play")]]]), name: "t")
        XCTAssertTrue(badExtraction.contains { $0.contains("illegal extractionState") },
                      "an illegal extractionState must be reported, got \(badExtraction)")

        // Substitutions — the two-count form. Each failure below renders at the
        // user rather than at build time, so each needs its own proof.
        func substitution(_ argNum: Int) -> [String: Any] {
            ["argNum": argNum, "formatSpecifier": "lld",
             "variations": ["plural": ["one": unit("%arg episode"), "other": unit("%arg episodes")]]]
        }
        let goodSubstitution: [String: Any] = ["localizations": ["en": [
            "substitutions": ["newest": substitution(1)],
            "stringUnit": ["state": "translated", "value": "Showing %#@newest@."],
        ]]]
        XCTAssertTrue(Self.schemaFailures(in: catalog(["n": goodSubstitution]), name: "t").isEmpty,
                      "a well-formed substitution must produce no findings")

        let unreferenced: [String: Any] = ["localizations": ["en": [
            "substitutions": ["newest": substitution(1)],
            "stringUnit": ["state": "translated", "value": "Showing nothing."],
        ]]]
        XCTAssertTrue(Self.schemaFailures(in: catalog(["n": unreferenced]), name: "t")
                        .contains { $0.contains("never referenced") },
                      "a substitution the template never uses must be reported")

        let dangling: [String: Any] = ["localizations": ["en": [
            "substitutions": ["newest": substitution(1)],
            "stringUnit": ["state": "translated", "value": "Showing %#@newest@ and %#@older@."],
        ]]]
        XCTAssertTrue(Self.schemaFailures(in: catalog(["n": dangling]), name: "t")
                        .contains { $0.contains("no such substitution") },
                      "a %#@name@ with nothing behind it renders literally and must be reported")

        var noArgNum = substitution(1)
        noArgNum.removeValue(forKey: "argNum")
        let missingArg: [String: Any] = ["localizations": ["en": [
            "substitutions": ["newest": noArgNum],
            "stringUnit": ["state": "translated", "value": "Showing %#@newest@."],
        ]]]
        XCTAssertTrue(Self.schemaFailures(in: catalog(["n": missingArg]), name: "t")
                        .contains { $0.contains("argNum") },
                      "a substitution with no argNum must be reported")

        let noOther = Self.schemaFailures(in: catalog(["n": ["localizations": ["en":
            ["variations": ["plural": ["one": unit("1 episode")]]]]]]), name: "t")
        XCTAssertTrue(noOther.contains { $0.contains("no 'other' case") },
                      "a plural variation without 'other' must be reported, got \(noOther)")

        let badPlural = Self.schemaFailures(in: catalog(["n": ["localizations": ["en":
            ["variations": ["plural": ["other": unit("x"), "several": unit("y")]]]]]]), name: "t")
        XCTAssertTrue(badPlural.contains { $0.contains("illegal plural categories") },
                      "an invented plural category must be reported, got \(badPlural)")

        let bothForms = Self.schemaFailures(in: catalog(["n": ["localizations": ["en":
            ["stringUnit": ["state": "new", "value": "x"],
             "variations": ["plural": ["other": unit("y")]]]]]]), name: "t")
        XCTAssertTrue(bothForms.contains { $0.contains("expected exactly one of") },
                      "a localization carrying two forms must be reported, got \(bothForms)")

        let wrongSource = Self.schemaFailures(in: ["sourceLanguage": "de", "version": "1.0", "strings": [:]], name: "t")
        XCTAssertTrue(wrongSource.contains { $0.contains("sourceLanguage is 'de'") },
                      "a non-English source language must be reported, got \(wrongSource)")
    }

    /// The fixtures above are only safe because this target is not localized.
    /// If `SWIFT_EMIT_LOC_STRINGS` is ever enabled on `YourPodsTests`, every
    /// degenerate key in this file lands in a catalog and the guard starts
    /// reporting itself.
    /// Named for what it measures, which is narrower than it first appears.
    ///
    /// The test target *does* emit localized strings — `GlassEnvironmentSafetyTests`
    /// builds `Text("Hi")`, and a `.stringsdata` for it exists in DerivedData.
    /// What keeps that out of the shipped catalogs is that
    /// `Translations/tools/sync_catalogs.py` reads only the four app targets,
    /// not that extraction is off. This asserts the project spec never opts the
    /// test target into catalog generation, which would put the degenerate-key
    /// and malformed-catalog fixtures in this file into a real catalog and make
    /// the guards report themselves.
    func test_projectSpecNeverOptsTheTestTargetIntoCatalogGeneration() throws {
        let url = repoRoot().appendingPathComponent("project.yml")
        let spec = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8), "project.yml is unreadable")
        let target = try XCTUnwrap(spec.range(of: "\n  YourPodsTests:"),
            "YourPodsTests target not found in project.yml — the anchor moved")
        let nextTarget = spec.range(of: "\n  YourPods", range: target.upperBound..<spec.endIndex)?.lowerBound
            ?? spec.endIndex
        let section = spec[target.upperBound..<nextTarget]
        XCTAssertFalse(section.contains("SWIFT_EMIT_LOC_STRINGS"), """
        YourPodsTests now emits localized strings. The degenerate-key and
        malformed-catalog fixtures in this file will be extracted into a
        catalog and the guards will report themselves. Move the fixtures out
        of Swift literals, or exclude the test target from extraction.
        """)
    }
}

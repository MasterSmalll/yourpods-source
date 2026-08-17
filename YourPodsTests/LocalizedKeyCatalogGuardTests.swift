import XCTest

/// Every `String(localized:)` key the app asks for must exist in its target's
/// string catalog.
///
/// `LocalizationAccessibilityGuardTests` proves the *call site* is extractable —
/// that the argument is a literal, or a helper whose body goes through
/// `String(localized:)`. It stops there. Nothing then checks that the key those
/// calls name was ever written into `Localizable.xcstrings`.
///
/// That gap is silent by construction. `String(localized: "some.key",
/// defaultValue: "Use the server's position")` with no catalog entry compiles,
/// runs, and reads correctly aloud — in English. The five translated locales
/// fall back to `defaultValue`, so the bug is invisible to anyone testing in
/// English and invisible to the accessibility guard, which sees a well-formed
/// call. It surfaces only as a German VoiceOver user hearing English.
///
/// Measured when this guard was written: **18 keys** on the sync conflict
/// sheet — every VoiceOver label and hint the sheet has — were absent from the
/// catalog and had been shipping untranslated for several releases.
///
/// Each target compiles its own catalog, so a key must be in *its* target's
/// file: `YourPodsWatch/PlayerView.swift` resolves against
/// `YourPodsWatch/Localizable.xcstrings`, not the app's.
final class LocalizedKeyCatalogGuardTests: XCTestCase {

    /// Source root → the catalog that root's target compiles.
    private static let targets: [(root: String, catalog: String)] = [
        ("YourPodsWidgets",      "YourPodsWidgets/Localizable.xcstrings"),
        ("YourPodsWatch",        "YourPodsWatch/Localizable.xcstrings"),
        ("YourPodsComplication", "YourPodsComplication/Localizable.xcstrings"),
        // Last: the app root is the fallback for anything not under the others.
        ("YourPods/YourPods",    "YourPods/YourPods/Localizable.xcstrings"),
    ]

    /// The locales the app ships. A key present but untranslated is the same
    /// defect wearing a catalog entry, so presence alone is not the bar.
    private static let shippedLocales = ["de", "es", "fr", "it", "nl"]

    private func repoRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        root.deleteLastPathComponent()   // …/YourPodsTests
        root.deleteLastPathComponent()   // repo root
        return root
    }

    // MARK: - Scanner

    struct KeyUse: Equatable { let key: String; let file: String; let line: Int }

    /// Literal keys only. An interpolated key is a separate defect with its own
    /// test below — it has no fixed spelling to look up.
    /// The class excludes the backslash deliberately: it makes the match stop
    /// dead at an interpolation rather than backtracking to some later quote,
    /// so an interpolated key yields no literal at all.
    private static let literalKey = try! NSRegularExpression(
        pattern: #"String\(\s*localized:\s*"([^"\\]*)""#)

    /// A key built at runtime: `String(localized: "More Info for \(name)")`.
    private static let interpolatedKey = try! NSRegularExpression(
        pattern: #"String\(\s*localized:\s*"[^"]*\\\("#)

    func keyUses(in contents: String, path: String) -> [KeyUse] {
        var out: [KeyUse] = []
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for match in Self.literalKey.matches(in: line, range: range) {
                guard let r = Range(match.range(at: 1), in: line) else { continue }
                let key = String(line[r])
                guard !key.isEmpty else { continue }
                out.append(KeyUse(key: key, file: path, line: index + 1))
            }
        }
        return out
    }

    private func catalogFor(_ relativePath: String) -> String {
        for target in Self.targets where relativePath.hasPrefix(target.root + "/") {
            return target.catalog
        }
        return Self.targets.last!.catalog
    }

    private func catalog(_ relative: String) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent(relative)
        let data = try XCTUnwrap(try? Data(contentsOf: url), "missing catalog: \(relative)")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any], "\(relative) has no strings table")
    }

    /// Walks every shipped Swift file, paired with the catalog its target uses.
    private func eachSourceFile(_ body: (String, String) throws -> Void) rethrows {
        let root = repoRoot()
        for target in Self.targets {
            let url = root.appendingPathComponent(target.root)
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                // Roots nest: YourPods/YourPods is walked last and must not
                // re-claim files already attributed to a more specific target.
                guard catalogFor(relative) == target.catalog else { continue }
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
                try body(relative, contents)
            }
        }
    }

    // MARK: - The invariant

    func test_everyLocalizedKey_existsInItsTargetCatalog() throws {
        var catalogs: [String: [String: Any]] = [:]
        var missing: [(KeyUse, String)] = []
        var scanned = 0

        try eachSourceFile { relative, contents in
            let catalogPath = catalogFor(relative)
            if catalogs[catalogPath] == nil { catalogs[catalogPath] = try catalog(catalogPath) }
            let table = catalogs[catalogPath]!
            for use in keyUses(in: contents, path: relative) {
                scanned += 1
                if table[use.key] == nil { missing.append((use, catalogPath)) }
            }
        }

        XCTAssertGreaterThan(scanned, 100, "only \(scanned) localized keys found — the walk is broken")
        XCTAssertTrue(missing.isEmpty, """
        These keys are asked for in code but are not in the catalog, so every
        non-English locale silently falls back to the English defaultValue:

          \(missing.map { "\($0.0.file):\($0.0.line)  \($0.0.key)  →  \($0.1)" }
                   .sorted().joined(separator: "\n  "))

        Add each one to the catalog with its translations.
        """)
    }

    /// Presence is not enough — an entry with no translations is the same bug.
    func test_everyLocalizedKey_isTranslatedInEveryShippedLocale() throws {
        var catalogs: [String: [String: Any]] = [:]
        var untranslated: [String] = []

        try eachSourceFile { relative, contents in
            let catalogPath = catalogFor(relative)
            if catalogs[catalogPath] == nil { catalogs[catalogPath] = try catalog(catalogPath) }
            guard let table = catalogs[catalogPath] else { return }
            for use in keyUses(in: contents, path: relative) {
                guard let entry = table[use.key] as? [String: Any] else { continue }  // absence: other test
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                let absent = Self.shippedLocales.filter { localizations[$0] == nil }
                if !absent.isEmpty {
                    untranslated.append("\(use.file):\(use.line)  \(use.key)  missing: \(absent.joined(separator: ", "))")
                }
            }
        }

        XCTAssertTrue(untranslated.isEmpty, """
        These keys are in the catalog but not translated into every shipped locale:

          \(untranslated.sorted().joined(separator: "\n  "))
        """)
    }

    /// A key assembled at runtime can never be looked up, so it can never be
    /// translated. `OnboardingView` had one of these next to a correct call.
    func test_noLocalizedKey_isBuiltByInterpolation() throws {
        var offenders: [String] = []
        try eachSourceFile { relative, contents in
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if Self.interpolatedKey.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(relative):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
        A localized key is being built by interpolation. The key is then
        whatever the values happen to spell, so it matches no catalog entry and
        is never translated. Use a fixed key and put the values in defaultValue:

          \(offenders.sorted().joined(separator: "\n  "))
        """)
    }

    // MARK: - Scanner self-checks
    //
    // The scanner is the whole test. If it silently matches nothing, both
    // invariants above pass while enforcing nothing.

    func test_scanner_findsALiteralKey() {
        let uses = keyUses(in: #"x(String(localized: "a.b.c", defaultValue: "Hi"))"#, path: "F.swift")
        XCTAssertEqual(uses, [KeyUse(key: "a.b.c", file: "F.swift", line: 1)])
    }

    func test_scanner_findsKeysAcrossLines() {
        let source = """
        let a = String(localized: "one")
        let b = String(localized: "two")
        """
        XCTAssertEqual(keyUses(in: source, path: "F.swift").map(\.key), ["one", "two"])
        XCTAssertEqual(keyUses(in: source, path: "F.swift").map(\.line), [1, 2])
    }

    /// The literal scanner must not report an interpolated key as a literal one
    /// — it would look up a spelling that never occurs and report it missing,
    /// pointing at the wrong defect.
    func test_scanner_ignoresAnInterpolatedKey() {
        XCTAssertTrue(keyUses(in: #"String(localized: "More Info for \(title)")"#, path: "F.swift").isEmpty)
    }

    func test_scanner_toleratesWhitespaceAfterTheParen() {
        XCTAssertEqual(keyUses(in: #"String( localized:  "spaced.key")"#, path: "F.swift").map(\.key),
                       ["spaced.key"])
    }

    /// Nested source roots: a watch file must resolve to the watch catalog even
    /// though the app root is also a prefix candidate.
    func test_catalogRouting_prefersTheMostSpecificTarget() {
        XCTAssertEqual(catalogFor("YourPodsWatch/PlayerView.swift"),
                       "YourPodsWatch/Localizable.xcstrings")
        XCTAssertEqual(catalogFor("YourPods/YourPods/Views/SyncConflictSheet.swift"),
                       "YourPods/YourPods/Localizable.xcstrings")
        XCTAssertEqual(catalogFor("YourPodsComplication/Views/Foo.swift"),
                       "YourPodsComplication/Localizable.xcstrings")
    }
}

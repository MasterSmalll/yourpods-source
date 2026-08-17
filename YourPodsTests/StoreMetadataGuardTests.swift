import XCTest

/// Guards the App Store listing text.
///
/// Two systems localize this app and they do not share a vocabulary. The
/// binary ships ISO codes — `de`, `es`, `fr`, `it`, `nl` — while App Store
/// Connect wants `de-DE`, `es-ES`, `fr-FR`, bare `it`, and `nl-NL`. Nothing in
/// a build connects them, so it is entirely possible to ship a fully German app
/// whose German listing is in English, and no test, log line or reviewer would
/// mention it.
///
/// The character limits are the other half. App Store Connect rejects an upload
/// that exceeds them — after the release is cut and the build is uploaded —
/// and German runs about 30% longer than English, so a comfortable 24-character
/// English subtitle lands around 31 in German.
final class StoreMetadataGuardTests: XCTestCase {

    /// App Store Connect locale ← the binary localization it must accompany.
    ///
    /// `it` has no region. That asymmetry is App Store Connect's, not a typo.
    static let localeMapping: [String: String] = [
        "en-US": "en",
        "de-DE": "de",
        "es-ES": "es",
        "fr-FR": "fr",
        "it": "it",
        "nl-NL": "nl",
    ]

    /// Field → maximum characters, per App Store Connect.
    static let limits: [String: Int] = [
        "name": 30,
        "subtitle": 30,
        "keywords": 100,
        "promotional_text": 170,
        "description": 4000,
        "release_notes": 4000,
    ]

    static var metadataRoot: URL {
        LocalizationCatalogFixture.repositoryRoot.appendingPathComponent("fastlane/metadata")
    }

    // MARK: - Invariant: the two locale sets stay in lockstep

    /// Every language the binary ships must have a listing directory.
    ///
    /// The failure this prevents is silent in both directions: a German app
    /// with an English listing looks fine in Xcode and fine in App Store
    /// Connect, and is only visible to a German user deciding whether to
    /// download it.
    func test_everyShippingLanguageHasAListingDirectory() throws {
        let catalogLanguages = try Self.languagesInCatalogs()
        XCTAssertFalse(catalogLanguages.isEmpty, "no localizations found — the catalog walk is broken")

        var missing: [String] = []
        for language in catalogLanguages.sorted() {
            let expected = Self.localeMapping.first { $0.value == language }?.key
            guard let expected else {
                missing.append("\(language): ships in the binary but has no App Store Connect locale mapped")
                continue
            }
            // A locale recorded as not-yet-authored is allowed to have no
            // directory at all. Git cannot store an empty directory, so
            // "the folder is there and empty" is not a state a checkout can
            // be in — absent is the only honest representation.
            if Self.listingsNotYetAuthored.contains(expected) { continue }
            var isDirectory: ObjCBool = false
            let path = Self.metadataRoot.appendingPathComponent(expected).path
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                missing.append("\(language): no fastlane/metadata/\(expected)/ directory")
            }
        }
        XCTAssertTrue(missing.isEmpty, """
        The binary ships languages the App Store listing does not cover:

          \(missing.joined(separator: "\n  "))

        A German app with an English listing is invisible to everyone except
        the German user deciding whether to download it.
        """)
    }

    /// And nothing in the other direction either — a listing locale with no
    /// binary behind it advertises an app that will open in English.
    func test_noListingLocaleLacksABinaryLocalization() throws {
        let catalogLanguages = try Self.languagesInCatalogs()
        var orphans: [String] = []
        for locale in try Self.listingLocales() {
            guard let language = Self.localeMapping[locale] else {
                orphans.append("\(locale): not in localeMapping")
                continue
            }
            if language != "en", !catalogLanguages.contains(language) {
                orphans.append("\(locale): listed on the App Store but the app has no \(language) localization")
            }
        }
        XCTAssertTrue(orphans.isEmpty, orphans.joined(separator: "\n  "))
    }

    // MARK: - Invariant: nothing exceeds App Store Connect's limits

    func test_noFieldExceedsItsCharacterLimit() throws {
        var overruns: [String] = []
        var checked = 0

        for locale in try Self.listingLocales() {
            for (field, limit) in Self.limits {
                let url = Self.metadataRoot
                    .appendingPathComponent(locale)
                    .appendingPathComponent("\(field).txt")
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > limit {
                    overruns.append("\(locale)/\(field).txt: \(text.count) characters, limit \(limit)")
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "no metadata files were read — the layout moved")
        XCTAssertTrue(overruns.isEmpty, """
        App Store Connect will reject the upload, after the release is cut:

          \(overruns.joined(separator: "\n  "))
        """)
    }

    /// Keywords are one comma-separated field, and a space after a comma is
    /// spent from the same 100 characters as a keyword.
    func test_keywordsWasteNoCharactersOnWhitespace() throws {
        var wasteful: [String] = []
        for locale in try Self.listingLocales() {
            let url = Self.metadataRoot.appendingPathComponent(locale).appendingPathComponent("keywords.txt")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains(", ") {
                wasteful.append("\(locale): a space after a comma costs a character that could be a keyword")
            }
        }
        XCTAssertTrue(wasteful.isEmpty, wasteful.joined(separator: "\n  "))
    }

    // MARK: - Invariant: a listing is complete or unstarted, never half-done

    /// Locales whose listing text has not been written yet.
    ///
    /// **This is a release blocker, recorded rather than hidden.** Every test
    /// above passes with these five directories completely empty, because each
    /// one iterates the files that *exist*. The failure this class was written
    /// to prevent — "a fully German app whose German listing is in English" —
    /// is the state the repository is in right now, and nothing was red.
    ///
    /// A guard that cannot fail is not evidence. So the invariant is not
    /// "listings exist" (unenforceable until the copy is written) but "a
    /// listing is all six fields or none of them". Half-done is the state that
    /// actually ships damage: a German `name.txt` beside an English
    /// `description.txt` uploads without complaint and looks deliberate.
    ///
    /// Empty this set before shipping. Removing a locale from it turns on full
    /// field-completeness checking for that locale immediately.
    ///
    /// It is empty: all six listings are written. Adding a locale back here is
    /// how you start a sixth translation, not how you excuse a failing check.
    static let listingsNotYetAuthored: Set<String> = []

    func test_everyStartedListingCarriesEveryField() throws {
        var incomplete: [String] = []
        var authored: [String] = []

        for locale in try Self.listingLocales() {
            let directory = Self.metadataRoot.appendingPathComponent(locale)
            let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".txt") }
                .map { String($0.dropLast(4)) })

            if present.isEmpty {
                XCTAssertTrue(Self.listingsNotYetAuthored.contains(locale),
                              "\(locale) has no listing text and is not recorded in listingsNotYetAuthored")
                continue
            }
            authored.append(locale)

            let missing = Set(Self.limits.keys).subtracting(present)
            if !missing.isEmpty {
                incomplete.append("\(locale): missing \(missing.sorted().joined(separator: ", "))")
            }
        }

        XCTAssertFalse(authored.isEmpty, "no listing was read at all — the layout moved")
        XCTAssertTrue(incomplete.isEmpty, """
        A half-written store listing uploads without complaint and looks
        deliberate — a translated name above an English description:

          \(incomplete.joined(separator: "\n  "))

        Write the remaining fields, or delete the partial ones and add the
        locale back to listingsNotYetAuthored.
        """)
    }

    /// The unauthored set must name locales that are real and genuinely have no
    /// copy — otherwise it excuses nothing while looking deliberate.
    ///
    /// It is checked against `localeMapping`, **not** against the directories on
    /// disk. An earlier version required the directory to exist and be empty,
    /// which no clean checkout can satisfy: git does not track empty
    /// directories, so the five placeholder folders lived only in the worktree
    /// that created them and the guard was red for everyone else.
    func test_theUnauthoredListingSetIsHonest() throws {
        let unknown = Self.listingsNotYetAuthored.subtracting(Set(Self.localeMapping.keys))
        XCTAssertTrue(unknown.isEmpty,
                      "listingsNotYetAuthored names locales that are not App Store Connect locales: \(unknown.sorted())")

        var actuallyAuthored: [String] = []
        for locale in Self.listingsNotYetAuthored {
            let directory = Self.metadataRoot.appendingPathComponent(locale)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".txt") }
            if !files.isEmpty { actuallyAuthored.append(locale) }
        }
        XCTAssertTrue(actuallyAuthored.isEmpty, """
        These locales have listing text but are still recorded as unauthored,
        so their fields are not being checked: \(actuallyAuthored.sorted())

        Remove them from listingsNotYetAuthored.
        """)
    }

    /// A file that exists but is empty reads as "translated" to every tool and
    /// ships a blank listing field.
    func test_noListingFileIsPresentButEmpty() throws {
        var blanks: [String] = []
        for locale in try Self.listingLocales() {
            let directory = Self.metadataRoot.appendingPathComponent(locale)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where file.hasSuffix(".txt") {
                let url = directory.appendingPathComponent(file)
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blanks.append("\(locale)/\(file) exists but is empty")
                }
            }
        }
        XCTAssertTrue(blanks.isEmpty, blanks.joined(separator: "\n  "))
    }

    // MARK: - Invariant: translation changed the prose and nothing else

    /// Every URL in the English listing appears byte-identical in every locale.
    ///
    /// A translator working on prose has no reason to stop at a URL, and
    /// `asc.is/support/` → `asc.is/soporte/` is a plausible, well-meaning edit
    /// that reads correctly and 404s. The support link is the only channel a
    /// confused Spanish user has, so breaking it breaks the one path back.
    func test_everyLocaleCarriesTheEnglishURLsUnchanged() throws {
        let englishURLs = try Self.urls(inListing: "en-US")
        XCTAssertFalse(englishURLs.isEmpty, "no URLs found in the English listing — the scan is broken")

        var damaged: [String] = []
        for locale in try Self.listingLocales() where locale != "en-US" {
            if Self.listingsNotYetAuthored.contains(locale) { continue }
            let localized = try Self.urls(inListing: locale)
            for url in englishURLs.subtracting(localized).sorted() {
                damaged.append("\(locale): \(url) is in the English listing but not this one")
            }
            for url in localized.subtracting(englishURLs).sorted() {
                damaged.append("\(locale): invented a URL that is not in the English listing: \(url)")
            }
        }
        XCTAssertTrue(damaged.isEmpty, """
        A URL changed in translation. It will still read correctly to the
        person it is aimed at, and still 404:

          \(damaged.joined(separator: "\n  "))
        """)
    }

    /// The app name is deliberately not localized: it is the brand, identical in
    /// every market.
    func test_theAppNameIsIdenticalInEveryLocale() throws {
        let english = try Self.field("name", inListing: "en-US")
        XCTAssertFalse(english.isEmpty, "en-US/name.txt is empty")

        var divergent: [String] = []
        for locale in try Self.listingLocales() where locale != "en-US" {
            guard let name = try? Self.field("name", inListing: locale), !name.isEmpty else { continue }
            if name != english {
                divergent.append("\(locale): \"\(name)\" — en-US is \"\(english)\"")
            }
        }
        XCTAssertTrue(divergent.isEmpty, """
        The app name is not localized on purpose, and changing it in one market
        is a branding decision, not a translation:

          \(divergent.joined(separator: "\n  "))
        """)
    }

    /// A locale whose keywords are the English keywords was never translated.
    ///
    /// Keywords are the field a translation pass most plausibly skips: they are
    /// not sentences, several are already English loanwords, and copying them
    /// produces a file that passes every length and completeness check above
    /// while forfeiting search in that market entirely.
    func test_translatedKeywordsAreNotJustTheEnglishOnes() throws {
        let english = try Self.field("keywords", inListing: "en-US")

        var copied: [String] = []
        for locale in try Self.listingLocales() where locale != "en-US" {
            guard let keywords = try? Self.field("keywords", inListing: locale), !keywords.isEmpty else { continue }
            if keywords == english {
                copied.append(locale)
            }
        }
        XCTAssertTrue(copied.isEmpty, """
        These locales ship the English keywords verbatim, which passes every
        other check here and forfeits App Store search in that market:
        \(copied.sorted())
        """)
    }

    // MARK: - Helpers

    static func field(_ name: String, inListing locale: String) throws -> String {
        let url = metadataRoot.appendingPathComponent(locale).appendingPathComponent("\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every URL in every field of a listing.
    static func urls(inListing locale: String) throws -> Set<String> {
        let directory = metadataRoot.appendingPathComponent(locale)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".txt") }

        // A URL ends at whitespace or at a bracket/quote wrapping it. Trailing
        // sentence punctuation is prose, not part of the address.
        let terminators: Set<Character> = [" ", "\t", "\n", "\r", "\"", "'", "<", ">", "(", ")", "[", "]", "«", "»", "„", "“", "”"]

        var found: Set<String> = []
        for file in files {
            let text = (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)) ?? ""
            var scanner = Substring(text)
            while let range = scanner.range(of: "http", options: [.caseInsensitive]) {
                let token = scanner[range.lowerBound...].prefix { !terminators.contains($0) }
                let cleaned = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if cleaned.count > "http".count { found.insert(cleaned) }
                scanner = scanner[range.upperBound...]
            }
        }
        return found
    }

    static func listingLocales() throws -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: metadataRoot.path)) ?? []
        return contents.filter { name in
            var isDirectory: ObjCBool = false
            let path = metadataRoot.appendingPathComponent(name).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return isDirectory.boolValue
        }.sorted()
    }

    /// Every non-English language present in the catalogs.
    static func languagesInCatalogs() throws -> Set<String> {
        var found: Set<String> = []
        for catalog in LocalizationCatalogFixture.catalogs {
            let parsed = try LocalizationCatalogFixture.load(catalog.path)
            for (_, value) in LocalizationCatalogFixture.strings(in: parsed) {
                let entry = value as? [String: Any] ?? [:]
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                found.formUnion(localizations.keys.filter { $0 != "en" })
            }
        }
        return found
    }
}

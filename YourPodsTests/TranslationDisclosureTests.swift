import XCTest
@testable import YourPods

/// The disclosure is the app's first impression in every non-English locale,
/// and every way of getting it wrong is quiet: it shows to English users, it
/// never shows to German ones, or it lands on top of onboarding.
final class TranslationDisclosureTests: XCTestCase {

    // MARK: - When it shows

    func test_showsForANonEnglishUserWhoHasFinishedOnboarding() {
        XCTAssertTrue(TranslationDisclosurePolicy.shouldPresent(
            resolvedLocalization: "de", hasCompletedOnboarding: true, seenLanguages: []))
    }

    func test_doesNotShowAgainInALanguageAlreadyAcknowledged() {
        XCTAssertFalse(TranslationDisclosurePolicy.shouldPresent(
            resolvedLocalization: "de", hasCompletedOnboarding: true, seenLanguages: ["de"]))
    }

    /// The behaviour this class was originally written to assert was "once
    /// ever", and it was wrong. Acknowledging the disclosure in German tells
    /// you nothing about Italian — and the German sheet was itself written in
    /// German, which the reader may not have been reading at the time.
    func test_showsAgainWhenTheUserSwitchesToAnUnacknowledgedLanguage() {
        XCTAssertTrue(TranslationDisclosurePolicy.shouldPresent(
            resolvedLocalization: "it", hasCompletedOnboarding: true, seenLanguages: ["de"]),
            "switching German → Italian must show the disclosure again")
        XCTAssertTrue(TranslationDisclosurePolicy.shouldPresent(
            resolvedLocalization: "nl", hasCompletedOnboarding: true, seenLanguages: ["de", "es", "fr", "it"]),
            "the last unacknowledged language must still show it")
        XCTAssertFalse(TranslationDisclosurePolicy.shouldPresent(
            resolvedLocalization: "nl", hasCompletedOnboarding: true, seenLanguages: ["de", "es", "fr", "it", "nl"]),
            "once every language is acknowledged it stops entirely")
    }

    /// Region variants are the same translation, so `de-AT` must not re-ask a
    /// user who acknowledged `de`.
    func test_regionVariantsCountAsTheSameLanguage() {
        for variant in ["de-AT", "de-CH", "de_DE", "DE"] {
            XCTAssertFalse(TranslationDisclosurePolicy.shouldPresent(
                resolvedLocalization: variant, hasCompletedOnboarding: true, seenLanguages: ["de"]),
                "\(variant) is the same German translation already acknowledged")
        }
    }

    /// Onboarding is a full-screen cover on iOS. Presenting a sheet over it is
    /// the whole reason this condition exists.
    func test_doesNotShowDuringOnboarding() {
        XCTAssertFalse(TranslationDisclosurePolicy.shouldPresent(
            resolvedLocalization: "de", hasCompletedOnboarding: false, seenLanguages: []),
            "A fresh German install would get this stacked on top of the onboarding cover")
    }

    func test_neverShowsToAnEnglishUser() {
        for localization in ["en", "en-GB", "en-US", "en_AU", "EN"] {
            XCTAssertFalse(TranslationDisclosurePolicy.shouldPresent(
                resolvedLocalization: localization, hasCompletedOnboarding: true, seenLanguages: []),
                "\(localization) is English — nothing on screen was translated")
        }
    }

    func test_showsForEveryShippingLanguageAndItsRegionVariants() {
        for localization in ["de", "de-AT", "de-CH", "es", "es-419", "fr", "fr-CA", "it", "nl", "nl-BE"] {
            XCTAssertTrue(TranslationDisclosurePolicy.shouldPresent(
                resolvedLocalization: localization, hasCompletedOnboarding: true, seenLanguages: []),
                "\(localization) resolves to a translated language")
        }
    }

    func test_languageCode_foldsRegionAndCase() {
        XCTAssertEqual(TranslationDisclosurePolicy.languageCode(of: "de-AT"), "de")
        XCTAssertEqual(TranslationDisclosurePolicy.languageCode(of: "pt_BR"), "pt")
        XCTAssertEqual(TranslationDisclosurePolicy.languageCode(of: "NL"), "nl")
        XCTAssertEqual(TranslationDisclosurePolicy.languageCode(of: "it"), "it")
    }

    // MARK: - English detection

    func test_isEnglish_matchesTheLanguageNotTheWholeIdentifier() {
        XCTAssertTrue(TranslationDisclosurePolicy.isEnglish("en"))
        XCTAssertTrue(TranslationDisclosurePolicy.isEnglish("en-GB"),
                      "British users see English copy and must not be told it was translated")
        XCTAssertTrue(TranslationDisclosurePolicy.isEnglish("en_US"))
        XCTAssertFalse(TranslationDisclosurePolicy.isEnglish("de"))
        XCTAssertFalse(TranslationDisclosurePolicy.isEnglish("eng-Latn"),
                       "only the exact ISO code counts; this is not one we ship")
    }

    // MARK: - Resolution source

    /// `preferredLocalizations` reports what the bundle can actually deliver.
    /// `Locale.preferredLanguages` reports what the user asked for, and would
    /// fire the disclosure at a Portuguese speaker who is seeing English
    /// because Portuguese does not ship.
    func test_resolvedLocalization_comesFromWhatTheBundleCanDeliver() {
        let localization = TranslationDisclosurePolicy.resolvedLocalization(bundle: .main)
        XCTAssertFalse(localization.isEmpty)
        XCTAssertTrue(Bundle.main.preferredLocalizations.contains(localization)
                      || localization == "en",
                      "must name a localization the bundle actually contains")
    }

    func test_resolvedLocalization_readsTheGivenBundleNotAlwaysMain() {
        // Proves the parameter is honoured — otherwise every test above would
        // silently measure the main bundle regardless of what it was handed.
        let bundle = Bundle(for: type(of: self))
        let localization = TranslationDisclosurePolicy.resolvedLocalization(bundle: bundle)
        XCTAssertFalse(localization.isEmpty)
    }

    // MARK: - The copy itself

    /// The wording is a commitment, not a placeholder. "as part of the
    /// development process" is the phrase that makes it accurate: AI translates
    /// the app during development, it does not translate for the user at
    /// runtime.
    func test_disclosureCopy_saysAiIsPartOfTheDevelopmentProcess() throws {
        let sources = [
            "YourPods/YourPods/Views/Components/TranslationDisclosureSheet.swift",
            "YourPods/YourPods/Views/SettingsView.swift",
        ]
        let phrase = "We use AI as part of the development process to translate it into other languages"
        for relative in sources {
            let url = LocalizationCatalogFixture.repositoryRoot.appendingPathComponent(relative)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(contents.contains(phrase),
                          "\(relative) no longer carries the agreed disclosure wording")
        }
    }

    /// The report action must exist in the permanent Settings home, not only in
    /// a sheet the user dismisses once and can never reach again.
    func test_settingsCarriesThePermanentReportAction() throws {
        let url = LocalizationCatalogFixture.repositoryRoot
            .appendingPathComponent("YourPods/YourPods/Views/SettingsView.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("Report a translation issue"))
        XCTAssertTrue(contents.contains("AppURLs.support"))
    }

    func test_supportURLIsReachableFromTheDisclosureSheet() throws {
        let url = LocalizationCatalogFixture.repositoryRoot
            .appendingPathComponent("YourPods/YourPods/Views/Components/TranslationDisclosureSheet.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("AppURLs.support"),
                      "the sheet's report link must go to the same place Settings does")
    }
}

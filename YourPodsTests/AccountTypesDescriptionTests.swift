import XCTest
@testable import YourPods

/// Tests that in-app account type descriptions match the public website copy
/// from https://yourpods.app/account-types/ and that the URL constant is correct.
///
/// Copy fields are LocalizedStringResource (English-as-key); `.key` is the
/// English source string these copy assertions target, locale-independent.
final class AccountTypesDescriptionTests: XCTestCase {

    // MARK: - Account Types URL

    func testAccountTypesURLIsCorrect() {
        let url = AppURLs.accountTypes
        XCTAssertEqual(url.absoluteString, "https://yourpods.app/account-types/")
    }

    func testAccountTypesURLIsValid() {
        let url = AppURLs.accountTypes
        XCTAssertNotNil(url.host)
        XCTAssertEqual(url.host, "yourpods.app")
        XCTAssertEqual(url.scheme, "https")
    }

    // MARK: - Website-aligned descriptions

    func testVaultModeDescription() {
        let desc = AccountTypeDescriptions.vault
        // Friendly language: save on this phone, no internet account needed
        XCTAssertTrue(desc.subtitle.key.contains("this phone only"), "Vault subtitle should mention 'this phone only'")
        XCTAssertTrue(desc.subtitle.key.contains("Start listening now"), "Vault subtitle should mention 'Start listening now'")
    }

    func testSelfHostedDescription() {
        let desc = AccountTypeDescriptions.selfHosted
        // Friendly language: private gPodder-compatible server
        XCTAssertTrue(desc.subtitle.key.contains("gPodder-compatible server"), "Self-hosted subtitle should mention gPodder-compatible server")
    }

    func testThirdPartyGPodderDescription() {
        let desc = AccountTypeDescriptions.thirdPartyGPodder
        // Friendly language: community-run public service
        XCTAssertTrue(desc.subtitle.key.contains("community-run"), "gpodder.net subtitle should mention 'community-run'")
    }

    func testYourPodsFreeDescription() {
        let desc = AccountTypeDescriptions.yourPodsFree
        // Friendly language: free account, sync podcasts across devices
        XCTAssertTrue(desc.subtitle.key.contains("free account"), "YourPods Free Sync subtitle should mention 'free account'")
        // Free-tier descriptions must NOT mention settings sync — it is Pro-only
        XCTAssertFalse(desc.subtitle.key.contains("settings"), "YourPods Free Sync subtitle must NOT mention settings sync (Pro-only feature)")
    }

    func testEveryModeIsFreeTagline() {
        let tagline = AccountTypeDescriptions.tagline
        // Reworded once RevenueCat added paid options — no longer "All options are free."
        XCTAssertEqual(tagline.key, "You may have multiple account types. Choose where to save your podcast data.")
    }

    func testSwitchAnytimeMessage() {
        let message = AccountTypeDescriptions.switchAnytime
        XCTAssertTrue(message.key.contains("switch"), "Switch anytime message should mention switching")
        XCTAssertTrue(message.key.contains("without losing"), "Switch anytime message should mention no data loss")
    }

    // MARK: - Repod removal

    func testNoRepodReferencesInDescriptions() {
        let allSubtitles = [
            AccountTypeDescriptions.vault.subtitle,
            AccountTypeDescriptions.selfHosted.subtitle,
            AccountTypeDescriptions.thirdPartyGPodder.subtitle,
            AccountTypeDescriptions.yourPodsFree.subtitle
        ]
        for subtitle in allSubtitles {
            XCTAssertFalse(subtitle.key.contains("Repod"), "Account descriptions must not reference Repod")
        }

        let allFeatures = AccountTypeDescriptions.selfHosted.features
        for feature in allFeatures {
            XCTAssertFalse(feature.key.contains("Repod"), "Self-hosted features must not reference Repod")
        }
    }

    func testSelfHostedMentionsNextcloud() {
        let desc = AccountTypeDescriptions.selfHosted
        XCTAssertTrue(desc.subtitle.key.contains("Nextcloud"), "Self-hosted subtitle should mention Nextcloud")
    }
}

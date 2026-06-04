import XCTest
@testable import YourPods

/// Tests that in-app account type descriptions match the public website copy
/// from https://yourpods.app/account-types/ and that the URL constant is correct.
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
        XCTAssertTrue(desc.subtitle.contains("this phone only"), "Vault subtitle should mention 'this phone only'")
        XCTAssertTrue(desc.subtitle.contains("Start listening now"), "Vault subtitle should mention 'Start listening now'")
    }
    
    func testSelfHostedDescription() {
        let desc = AccountTypeDescriptions.selfHosted
        // Friendly language: private gPodder-compatible server
        XCTAssertTrue(desc.subtitle.contains("gPodder-compatible server"), "Self-hosted subtitle should mention gPodder-compatible server")
    }
    
    func testThirdPartyGPodderDescription() {
        let desc = AccountTypeDescriptions.thirdPartyGPodder
        // Friendly language: community-run public service
        XCTAssertTrue(desc.subtitle.contains("community-run"), "gpodder.net subtitle should mention 'community-run'")
    }
    
    func testYourPodsSyncDescription() {
        let desc = AccountTypeDescriptions.yourPodsSync
        // Friendly language: free account, save podcasts online
        XCTAssertTrue(desc.subtitle.contains("free account"), "YourPods Sync subtitle should mention 'free account'")
        // Per GEMINI.md: do NOT mention settings sync in Sync-tier descriptions
        XCTAssertFalse(desc.subtitle.contains("settings"), "YourPods Sync subtitle must NOT mention settings sync (Pro-only feature)")
    }
    
    func testEveryModeIsFreeTagline() {
        let tagline = AccountTypeDescriptions.tagline
        XCTAssertEqual(tagline, "All options are free. Choose where to save your podcast data.")
    }
    
    func testSwitchAnytimeMessage() {
        let message = AccountTypeDescriptions.switchAnytime
        XCTAssertTrue(message.contains("switch"), "Switch anytime message should mention switching")
        XCTAssertTrue(message.contains("without losing"), "Switch anytime message should mention no data loss")
    }
    
    // MARK: - Repod removal
    
    func testNoRepodReferencesInDescriptions() {
        let allSubtitles = [
            AccountTypeDescriptions.vault.subtitle,
            AccountTypeDescriptions.selfHosted.subtitle,
            AccountTypeDescriptions.thirdPartyGPodder.subtitle,
            AccountTypeDescriptions.yourPodsSync.subtitle
        ]
        for subtitle in allSubtitles {
            XCTAssertFalse(subtitle.contains("Repod"), "Account descriptions must not reference Repod")
        }
        
        let allFeatures = AccountTypeDescriptions.selfHosted.features
        for feature in allFeatures {
            XCTAssertFalse(feature.contains("Repod"), "Self-hosted features must not reference Repod")
        }
    }
    
    func testSelfHostedMentionsNextcloud() {
        let desc = AccountTypeDescriptions.selfHosted
        XCTAssertTrue(desc.subtitle.contains("Nextcloud"), "Self-hosted subtitle should mention Nextcloud")
    }
}

import XCTest
@testable import YourPods

final class AccountTypeDescriptionsTests: XCTestCase {

    // Copy fields are LocalizedStringResource (English-as-key); `.key` is the
    // English source string these copy assertions target, locale-independent.

    func testFreeDescriptionExists() {
        XCTAssertEqual(AccountTypeDescriptions.yourPodsFree.title.key, "YourPods Free Sync")
        XCTAssertFalse(AccountTypeDescriptions.yourPodsFree.features.isEmpty)
    }

    func testProDescriptionExists() {
        XCTAssertEqual(AccountTypeDescriptions.yourPodsPro.title.key, "YourPods Pro")
        XCTAssertFalse(AccountTypeDescriptions.yourPodsPro.features.isEmpty)
    }

    /// Copy must never hardcode a price. App Store prices differ by storefront and
    /// currency, and they change; the only correct source is the localized price
    /// StoreKit hands back through `SubscriptionManager.localizedPrice`. A literal
    /// "$30/year" in shipped copy is wrong for most of the world the moment it ships.
    func testProCopyDoesNotHardcodeAPrice() {
        let copy = [
            AccountTypeDescriptions.yourPodsPro.subtitle.key,
            AccountTypeDescriptions.yourPodsProShort.key,
        ] + AccountTypeDescriptions.yourPodsPro.features.map(\.key)

        for text in copy {
            for symbol in ["$", "€", "£", "¥"] {
                XCTAssertFalse(
                    text.contains(symbol),
                    "Pro copy must not hardcode a price — show SubscriptionManager.localizedPrice instead. Found \(symbol) in: \(text)"
                )
            }
        }
    }

    func testFreeShortDescriptionExists() {
        XCTAssertFalse(AccountTypeDescriptions.yourPodsFreeShort.key.isEmpty)
    }

    func testProShortDescriptionExists() {
        XCTAssertFalse(AccountTypeDescriptions.yourPodsProShort.key.isEmpty)
    }
}

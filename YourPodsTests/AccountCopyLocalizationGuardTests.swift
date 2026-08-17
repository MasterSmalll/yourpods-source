import XCTest
@testable import YourPods

/// Guards that the account-type card copy and its short captions go through the
/// string catalog (LocalizedStringResource, English-as-key) rather than the
/// non-localizing `Text(String)` path this change fixed.
///
/// Two layers of protection:
///   1. Compile-time — reading `.key` only compiles while the fields are
///      `LocalizedStringResource`. Revert one to `String` and this test stops
///      building, which is louder than a silent English-only shipment.
///   2. Runtime — every key must exist in the catalog and be translated into
///      all five languages, so copy that never reached the catalog (the exact
///      failure mode here: a `String` field extracted nothing) fails the gate.
final class AccountCopyLocalizationGuardTests: XCTestCase {

    private static let languages = ["de", "es", "fr", "it", "nl"]

    private func catalogStrings() throws -> [String: Any] {
        let url = LocalizationCatalogFixture.repositoryRoot
            .appendingPathComponent("YourPods/YourPods/Localizable.xcstrings")
        let data = try XCTUnwrap(try? Data(contentsOf: url),
            "Localizable.xcstrings not found at \(url.path)")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    func test_everyAccountCopyStringIsLocalizedAndTranslated() throws {
        let strings = try catalogStrings()

        // `.key` here is a compile-time assertion the fields are LocalizedStringResource.
        var keys: Set<String> = []
        let cards = [
            AccountTypeDescriptions.vault,
            AccountTypeDescriptions.selfHosted,
            AccountTypeDescriptions.thirdPartyGPodder,
            AccountTypeDescriptions.yourPodsFree,
            AccountTypeDescriptions.yourPodsPro,
        ]
        for card in cards {
            keys.insert(card.title.key)
            keys.insert(card.subtitle.key)
            for feature in card.features { keys.insert(feature.key) }
        }
        keys.insert(AccountTypeDescriptions.tagline.key)
        keys.insert(AccountTypeDescriptions.switchAnytime.key)
        for short in [
            AccountTypeDescriptions.vaultShort,
            AccountTypeDescriptions.selfHostedShort,
            AccountTypeDescriptions.thirdPartyGPodderShort,
            AccountTypeDescriptions.yourPodsFreeShort,
            AccountTypeDescriptions.yourPodsProShort,
        ] { keys.insert(short.key) }

        // 37 distinct keys: shared feature bullets (e.g. "Sync subscriptions &
        // listen positions") dedupe across cards. Guard against an empty set.
        XCTAssertGreaterThan(keys.count, 30, "Sanity: expected the full account-copy set")

        for key in keys.sorted() {
            guard let entry = strings[key] as? [String: Any] else {
                XCTFail("Account copy '\(key)' is not in the string catalog — it is bypassing localization")
                continue
            }
            let localizations = (entry["localizations"] as? [String: Any]) ?? [:]
            for language in Self.languages {
                XCTAssertNotNil(localizations[language],
                    "Account copy '\(key)' has no \(language) translation")
            }
        }
    }
}

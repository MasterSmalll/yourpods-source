import XCTest
@testable import YourPods

/// Verifies the Settings Account section header adapts to the active profile
/// type and Pro status, and that the Pro nudge is hidden for Pro users.
///
/// Table-driven: each case defines (profileType, isPro) → expected (title, icon).
final class SettingsProUXTests: XCTestCase {

    // MARK: - Account Header

    /// Table-driven: (profileType, isPro) → expected header title and SF Symbol.
    func test_accountSectionHeader_matchesProfileType() {
        // `title` is a LocalizedStringResource; compare its `.key` (the English
        // source string, which is also the catalog key) rather than the resolved
        // value, so the assertion is locale- and bundle-independent.
        let cases: [(profile: ProfileType?, isPro: Bool, titleKey: String, icon: String)] = [
            // Pro user with a yourpodsPro profile
            (.yourpodsPro, true,  "YourPods Pro",       "star.circle.fill"),
            // Free user with a yourpodsPro profile
            (.yourpodsPro, false, "YourPods Free Sync", "arrow.triangle.2.circlepath.circle"),
            // gPodder user
            (.gpodder,     false, "gPodder Sync",       "server.rack"),
            // gpodder.net user
            (.gpodderNet,  false, "gPodder Sync",       "server.rack"),
            // Vault / no profile
            (nil,          false, "Account",            "person.circle"),
        ]

        for (i, c) in cases.enumerated() {
            let result = SettingsAccountHeader.resolve(profileType: c.profile, isPro: c.isPro)
            XCTAssertEqual(result.title.key, c.titleKey,
                           "Case \(i): expected title '\(c.titleKey)' for profileType=\(String(describing: c.profile)), isPro=\(c.isPro)")
            XCTAssertEqual(result.icon, c.icon,
                           "Case \(i): expected icon '\(c.icon)' for profileType=\(String(describing: c.profile)), isPro=\(c.isPro)")
        }
    }

    // MARK: - Pro Upgrade Row Visibility (free users, until dismissed)

    /// Table-driven: (isPro, dismissed) → whether the Settings Pro row shows.
    /// A free user sees it until they tap "Don't show this again" in the paywall;
    /// Pro users never see it (the header tier badge covers them) regardless of
    /// the dismiss flag.
    func test_proUpgradeRow_visibility() {
        let cases: [(isPro: Bool, dismissed: Bool, shows: Bool)] = [
            (false, false, true),   // free, not dismissed → show
            (false, true,  false),  // free, dismissed → hidden
            (true,  false, false),  // Pro → never shown
            (true,  true,  false),  // Pro + dismissed → still hidden
        ]
        for (i, c) in cases.enumerated() {
            XCTAssertEqual(
                SettingsAccountHeader.shouldShowProNudge(isPro: c.isPro, dismissed: c.dismissed),
                c.shows,
                "Case \(i): isPro=\(c.isPro) dismissed=\(c.dismissed) → expected shows=\(c.shows)"
            )
        }
    }

    /// The dismiss choice must survive relaunch (backed by UserDefaults).
    func test_proNudgeDismissed_persistsAcrossInstances() {
        let suiteName = "test.proNudge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.proNudgeDismissed, "must default to not-dismissed (row visible)")

        settings.proNudgeDismissed = true
        XCTAssertTrue(SettingsManager(defaults: defaults).proNudgeDismissed,
                      "dismiss flag must persist to a fresh SettingsManager over the same defaults")
    }
}

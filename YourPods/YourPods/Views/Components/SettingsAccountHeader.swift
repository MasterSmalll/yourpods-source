import Foundation

/// Pure-logic helper for the Settings Account section header.
/// Keeps the decision logic testable without SwiftUI dependencies.
enum SettingsAccountHeader {

    struct Resolved {
        let title: LocalizedStringResource
        let icon: String
    }

    /// Determine the Account section header based on the active profile type and Pro status.
    static func resolve(profileType: ProfileType?, isPro: Bool) -> Resolved {
        switch profileType {
        case .yourpodsPro where isPro:
            return Resolved(title: "YourPods Pro", icon: "star.circle.fill")
        case .yourpodsPro:
            return Resolved(title: "YourPods Free Sync", icon: "arrow.triangle.2.circlepath.circle")
        case .gpodder, .gpodderNet:
            return Resolved(title: "gPodder Sync", icon: "server.rack")
        case nil:
            return Resolved(title: "Account", icon: "person.circle")
        }
    }

    /// Whether the Pro upgrade row should be shown in Settings.
    /// Shown to non-Pro users who haven't dismissed it. Pro users get the tier
    /// badge in the account section header instead; users who tapped "Don't show
    /// this again" in the paywall opted out (`dismissed`).
    static func shouldShowProNudge(isPro: Bool, dismissed: Bool) -> Bool {
        !isPro && !dismissed
    }
}

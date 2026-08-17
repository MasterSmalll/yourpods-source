import Foundation

// MARK: - App URLs

/// Centralized URL constants for external links used throughout the app.
/// Keeps URLs in one place so they're easy to update and test.
enum AppURLs {
    /// Account types comparison page on yourpods.app
    static let accountTypes = URL(string: "https://yourpods.app/account-types/")!

    /// Terms of Service
    static let termsOfService = URL(string: "https://yourpods.app/terms/")!

    /// Privacy Policy
    static let privacyPolicy = URL(string: "https://yourpods.app/privacy/")!

    /// Support, including where to report a bad translation.
    ///
    /// The only `asc.is` link in the app — the rest of `AppURLs` is on
    /// `yourpods.app`. Deliberate: this is the publisher's support channel, and
    /// it has to work for Vault-mode users, who have no account at all and so
    /// cannot be reached by anything that needs a signed-in request.
    static let support = URL(string: "https://asc.is/support")!
}

// MARK: - Account Type Descriptions

/// Centralized account type description strings aligned with the public
/// website copy at https://yourpods.app/account-types/
///
/// Used by OnboardingView, AboutSyncView, and ProfileSelectionView to ensure
/// consistent messaging across the app.
///
/// Copy fields are `LocalizedStringResource` (English-as-key) so they render
/// through the string catalog. Rendering them with `Text(_:)` localizes; where
/// a plain `String` is needed (e.g. composing a VoiceOver label), resolve with
/// `String(localized:)`. The `icon` is an SF Symbol name and is never localized.
struct AccountTypeDescription {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let icon: String
    let features: [LocalizedStringResource]
}

enum AccountTypeDescriptions {

    // MARK: - Vault Mode

    static let vault = AccountTypeDescription(
        title: "Vault Mode — Device Only",
        subtitle: "Save everything on this phone only. No internet account needed. Start listening now.",
        icon: "lock.iphone",
        features: [
            "Everything on-device",
            "No account required",
            "Full playback features",
            "Convert to any sync mode anytime"
        ]
    )

    // MARK: - Self-Hosted / Nextcloud

    static let selfHosted = AccountTypeDescription(
        title: "Nextcloud / Self-Hosted",
        subtitle: "Sync your library using your own Nextcloud or gPodder-compatible server.",
        icon: "server.rack",
        features: [
            "Sync subscriptions & listen positions",
            "Your own server — you control the data",
            "Supports Sign in with Nextcloud or app passwords",
            "Full playback features"
        ]
    )

    // MARK: - Third-Party gPodder

    static let thirdPartyGPodder = AccountTypeDescription(
        title: "gpodder.net",
        subtitle: "Save your progress using the community-run public gpodder.net service. (Note: Their privacy rules will apply).",
        icon: "globe",
        features: [
            "Sync subscriptions & listen positions",
            "No server setup required",
            "Works with any gPodder-compatible app",
            "Third-party privacy policy applies"
        ]
    )

    // MARK: - YourPods Free Sync

    static let yourPodsFree = AccountTypeDescription(
        title: "YourPods Free Sync",
        subtitle: "Create a free account to sync subscriptions and listen positions across devices — hosted by YourPods.",
        icon: "cloud",
        features: [
            "Sync subscriptions & listen positions",
            "Free — just an email and password",
            "No analytics, no tracking, no ad identifiers",
            "Upgrade to Pro anytime"
        ]
    )

    // MARK: - YourPods Pro

    static let yourPodsPro = AccountTypeDescription(
        title: "YourPods Pro",
        subtitle: "Support indie development and get the full cloud experience.",
        icon: "star.circle.fill",
        features: [
            "Support indie development",
            "Everything in Free, plus:",
            "Web player — stream in any browser, PWA on any compatible device",
            "Queue sync across all devices",
            "Listening stats & annotations",
            "Sync notes across devices",
            "gPodder bridge & media proxy"
        ]
    )

    // MARK: - Deprecated (use yourPodsFree / yourPodsPro)

    @available(*, deprecated, renamed: "yourPodsFree")
    static let yourPodsSync = yourPodsFree

    // MARK: - Shared Copy

    /// The main tagline from the website: https://yourpods.app/account-types/
    static let tagline: LocalizedStringResource = "You may have multiple account types. Choose where to save your podcast data."

    /// Switching modes message
    static let switchAnytime: LocalizedStringResource = "You can switch between any mode at any time without losing your local data — subscriptions, downloads, and queue are always preserved."

    // MARK: - Short Descriptions (for ProfileSelectionView)

    static let vaultShort: LocalizedStringResource = "Everything stays on-device. Maximum privacy, zero setup."

    static let selfHostedShort: LocalizedStringResource = "Your data, your server, your rules."

    static let thirdPartyGPodderShort: LocalizedStringResource = "Community-run gPodder sync — no server setup required."

    static let yourPodsFreeShort: LocalizedStringResource = "Free cloud sync across all your Apple devices."

    static let yourPodsProShort: LocalizedStringResource = "Full cloud experience — web player, stats & more."

    @available(*, deprecated, renamed: "yourPodsFreeShort")
    static let yourPodsSyncShort = yourPodsFreeShort
}

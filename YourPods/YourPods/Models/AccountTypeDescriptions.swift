import Foundation

// MARK: - App URLs

/// Centralized URL constants for external links used throughout the app.
/// Keeps URLs in one place so they're easy to update and test.
enum AppURLs {
    /// Account types comparison page on yourpods.app
    static let accountTypes = URL(string: "https://yourpods.app/account-types/")!
    
    /// Terms of Service
    static let termsOfService = URL(string: "https://asecretcompany.com/yourpods-terms-of-service/")!
    
    /// Privacy Policy
    static let privacyPolicy = URL(string: "https://asecretcompany.com/yourpods-privacy-policy/")!
}

// MARK: - Account Type Descriptions

/// Centralized account type description strings aligned with the public
/// website copy at https://yourpods.app/account-types/
///
/// Used by OnboardingView, AboutSyncView, and ProfileSelectionView to ensure
/// consistent messaging across the app.
struct AccountTypeDescription {
    let title: String
    let subtitle: String
    let icon: String
    let features: [String]
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
        subtitle: "Connect to a private gPodder-compatible server (like Nextcloud) to save your podcasts and listening progress.",
        icon: "server.rack",
        features: [
            "Sync subscriptions & listen positions",
            "Your own server — you control the data",
            "Works with any gPodder-compatible server",
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
    
    // MARK: - YourPods Sync
    
    static let yourPodsSync = AccountTypeDescription(
        title: "YourPods Sync Account",
        subtitle: "Create a free account with us to save your podcasts and listening progress online.",
        icon: "star.circle",
        features: [
            "Sync subscriptions & listen positions",
            "Free — just an email and password",
            "No analytics, no tracking, no ad identifiers",
            "Enhanced sync powered by yourpods.app"
        ]
    )
    
    // MARK: - Shared Copy
    
    /// The main tagline from the website: https://yourpods.app/account-types/
    static let tagline = "All options are free. Choose where to save your podcast data."
    
    /// Switching modes message
    static let switchAnytime = "You can switch between any mode at any time without losing your local data — subscriptions, downloads, and queue are always preserved."
    
    // MARK: - Short Descriptions (for ProfileSelectionView)
    
    static let vaultShort = "Everything stays on-device. Maximum privacy, zero setup."
    
    static let selfHostedShort = "Your data, your server, your rules."
    
    static let thirdPartyGPodderShort = "Community-run gPodder sync — no server setup required."
    
    static let yourPodsSyncShort = "Free sync across all your Apple devices."
}

import Foundation

/// Decides whether to tell the user this app's translations are AI-made.
///
/// A pure decision so it can be tested without a simulator in five languages.
enum TranslationDisclosurePolicy {

    /// The localization the app actually resolved to — already region-folded
    /// (`de-AT` → `de`) and already fallback-aware.
    ///
    /// `Bundle.main.preferredLocalizations`, not `Locale.preferredLanguages`.
    /// The latter reports what the *user* wants rather than what the app can
    /// deliver, so a Portuguese speaker seeing the app in English — because
    /// Portuguese does not ship — would be told about translations that are not
    /// on screen.
    static func resolvedLocalization(bundle: Bundle = .main) -> String {
        bundle.preferredLocalizations.first ?? "en"
    }

    /// Three conditions, all required.
    ///
    /// Gating on onboarding is not cosmetic: without it a German user on a
    /// fresh install gets this sheet stacked on top of the onboarding flow,
    /// which is a full-screen cover.
    ///
    /// **Once per language, not once ever.** This shipped as once-ever on the
    /// argument that the disclosure describes how the app is built rather than
    /// which language is on screen. In use that reads as a bug: someone who
    /// acknowledged it in German and then switches to Italian has never been
    /// told that *Italian* is machine-translated, and the sheet they saw was
    /// itself in a language they may not have been reading at the time.
    /// `seenLanguages` is the set of language codes already acknowledged.
    static func shouldPresent(resolvedLocalization: String,
                              hasCompletedOnboarding: Bool,
                              seenLanguages: Set<String>) -> Bool {
        guard hasCompletedOnboarding else { return false }
        guard !isEnglish(resolvedLocalization) else { return false }
        return !seenLanguages.contains(languageCode(of: resolvedLocalization))
    }

    /// The bare language of a localization identifier: `de-AT` → `de`.
    ///
    /// Region variants fold, so a user moving between `de-AT` and `de-CH` is
    /// not told twice about the same German translation.
    static func languageCode(of localization: String) -> String {
        localization
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { $0.lowercased() } ?? localization.lowercased()
    }

    /// `en`, `en-GB` and `en_US` are all English. Matching the whole string
    /// would fire the disclosure at British users.
    static func isEnglish(_ localization: String) -> Bool {
        languageCode(of: localization) == "en"
    }
}

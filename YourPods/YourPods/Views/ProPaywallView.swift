import SwiftUI

/// Custom paywall for YourPods Pro subscription.
///
/// Reused across onboarding (after account creation), Settings upgrade,
/// and contextual nudge targets. Communicates that Pro is optional and
/// supports indie development.
struct ProPaywallView: View {
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(\.dismiss) private var dismiss

    /// Called when the user explicitly chooses "Continue with Free".
    var onSkip: (() -> Void)?

    /// Called when the user chooses "Don't show this again". Provided only where
    /// the paywall is a *dismissible nudge* (the Settings Pro row); `nil` in
    /// onboarding, where hiding the upgrade path permanently is not offered.
    var onDoNotAskAgain: (() -> Void)?

    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isRestoring = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.purple)
                        .accessibilityHidden(true)

                    Text("YourPods Pro")
                        .font(.largeTitle.bold())

                    Text("Your free account is ready.\nPro unlocks extra features and supports continued development.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 32)

                // Feature comparison
                featureComparison

                // Purchase button
                Button {
                    Task { await purchase() }
                } label: {
                    HStack {
                        VStack(spacing: 2) {
                            // Its own key, not the one on the podcast-follow
                            // button. English uses "Subscribe" for both, but
                            // following a show and buying a plan are different
                            // verbs in several target languages, and one string
                            // cannot be right for both.
                            Text(String(localized: "paywall.subscribe",
                                        defaultValue: "Subscribe",
                                        comment: "Button that starts the paid YourPods Pro purchase. This is BUYING A SUBSCRIPTION — money — not subscribing to a podcast. The price appears beneath it."))
                                .font(.headline)
                            if let price = subscriptionManager.localizedPrice,
                               let period = subscriptionManager.periodDescription {
                                Text(String(localized: "paywall.pricePerPeriod",
                                            defaultValue: "\(price)/\(period)",
                                            comment: "Price and billing period on the subscribe button, e.g. '$19.99/year'. Argument 1 is the App Store's already-localized price, 2 the billing period. Some languages write this as 'per year' rather than with a slash."))
                                    .font(.caption)
                                    .opacity(0.8)
                            }
                        }
                        if subscriptionManager.isPurchasing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(subscriptionManager.isPurchasing || isRestoring)
                .padding(.horizontal, 32)
                .accessibilityLabel("Subscribe to YourPods Pro")
                .accessibilityHint(Self.subscribeHint(price: subscriptionManager.localizedPrice,
                                                      period: subscriptionManager.periodDescription))

                // Restore + terms
                VStack(spacing: 8) {
                    Text("Cancel anytime · No contracts")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button {
                        Task { await restore() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Restore Purchase")
                            if isRestoring {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .font(.caption)
                    }
                    .disabled(subscriptionManager.isPurchasing || isRestoring)
                    .accessibilityLabel("Restore previous purchase")

                    HStack(spacing: 4) {
                        Link("Terms", destination: AppURLs.termsOfService)
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Link("Privacy", destination: AppURLs.privacyPolicy)
                    }
                    .font(.caption2)
                }

                // Skip button
                if let onSkip {
                    Button {
                        onSkip()
                    } label: {
                        Text("Continue with Free →")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.15))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 32)
                    .accessibilityLabel("Continue with YourPods Free")
                }

                // Permanent-dismiss (Settings nudge only). Kept low-emphasis so
                // it doesn't compete with Subscribe / Continue with Free.
                if let onDoNotAskAgain {
                    Button {
                        onDoNotAskAgain()
                    } label: {
                        Text("Don't show this again")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    .accessibilityHint("Hides the YourPods Pro upgrade row in Settings")
                }

                // Indie message
                VStack(spacing: 4) {
                    Text("❤️ Built indie. Funded by listeners.")
                        .font(.caption.weight(.medium))
                    Text("Every subscription funds development directly.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 48)
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Feature Comparison

    private var featureComparison: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack {
                Spacer()
                    .frame(maxWidth: .infinity)
                Text(String(localized: "paywall.tier.free",
                            defaultValue: "Free",
                            comment: "Column header for the free subscription tier in a two-column comparison table. This is the NAME OF A PRICE TIER, not the adjective meaning unrestricted — German uses 'Gratis'."))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 50)
                Text(String(localized: "paywall.tier.pro",
                            defaultValue: "Pro",
                            comment: "Column header for the paid subscription tier. 'Pro' is the product name and is on the do-not-translate list — keep it as 'Pro' in every language."))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                    .frame(width: 50)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            
            featureRow("Subscription sync", free: true, pro: true)
            featureRow("Listen position sync", free: true, pro: true)
            featureRow("Web player", free: false, pro: true)
            featureRow("Queue sync", free: false, pro: true)
            featureRow("Listening Stats", free: false, pro: true)
            featureRow("Notes & annotations", free: false, pro: true)
            featureRow("gPodder bridge", free: false, pro: true)
            featureRow("Media proxy", free: false, pro: true, isLast: true)
        }
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    /// `name` is a `LocalizedStringResource`, not a `String`, so the eight
    /// literals at the call sites above extract on their own. As a `String`
    /// parameter they bound the non-localizing overload and shipped in
    /// English everywhere, while the VoiceOver label that interpolated them
    /// collapsed the whole table into the single catalog key `%@: %@, %@`.
    private func featureRow(_ name: LocalizedStringResource, free: Bool, pro: Bool, isLast: Bool = false) -> some View {
        HStack {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

            // Decoration: the row's meaning is carried by the VoiceOver label
            // below, so the glyphs are verbatim and never enter the catalog.
            Text(verbatim: free ? "✓" : "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(free ? Color.green : Color.gray)
                .frame(width: 50)

            Text(verbatim: pro ? "✓" : "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pro ? Color.purple : Color.gray)
                .frame(width: 50)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.featureRowLabel(name: name, free: free, pro: pro))
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 16)
            }
        }
    }

    /// VoiceOver hint for the subscribe button — "$19.99 per year".
    ///
    /// Built inline in a `.map { … }` closure, so it returned `String` and
    /// neither "per", "year", nor "Loading price" ever extracted. The
    /// fallback period is a catalog key too: a language that inflects it
    /// after "per" cannot reach a literal frozen in Swift.
    private static func subscribeHint(price: String?, period: String?) -> String {
        guard let price else {
            return String(localized: "a11y.paywall.loadingPrice", defaultValue: "Loading price",
                          comment: "VoiceOver hint on the subscribe button while the App Store price is still being fetched.")
        }
        let billingPeriod = period ?? String(localized: "paywall.period.year", defaultValue: "year",
                                             comment: "Fallback billing period when the App Store has not supplied one. Follows 'per', as in 'per year'.")
        return String(localized: "a11y.paywall.pricePerPeriod",
                      defaultValue: "\(price) per \(billingPeriod)",
                      comment: "VoiceOver hint on the subscribe button. Argument 1 is the App Store's already-localized price, 2 the billing period — e.g. '$19.99 per year'.")
    }

    /// VoiceOver label for one row of the Free/Pro comparison table.
    ///
    /// The four English fragments were built inside a single interpolation, so
    /// "included in Free" and its three siblings never reached the catalog —
    /// the extractor saw only the punctuation between them. Each state is now
    /// its own key, and the row template is a fifth so a language can reorder
    /// or repunctuate it.
    private static func featureRowLabel(name: LocalizedStringResource, free: Bool, pro: Bool) -> String {
        let freeState = free
            ? String(localized: "a11y.paywall.includedInFree", defaultValue: "included in Free",
                     comment: "VoiceOver: this feature is part of the free tier.")
            : String(localized: "a11y.paywall.notInFree", defaultValue: "not in Free",
                     comment: "VoiceOver: this feature is not part of the free tier.")
        let proState = pro
            ? String(localized: "a11y.paywall.includedInPro", defaultValue: "included in Pro",
                     comment: "VoiceOver: this feature is part of the Pro tier.")
            : String(localized: "a11y.paywall.notInPro", defaultValue: "not in Pro",
                     comment: "VoiceOver: this feature is not part of the Pro tier.")
        return String(localized: "a11y.paywall.featureRow",
                      defaultValue: "\(String(localized: name)): \(freeState), \(proState)",
                      comment: "VoiceOver label for one row of the Free/Pro comparison table. Argument 1 is the feature name, 2 its free-tier state, 3 its Pro state.")
    }

    // MARK: - Actions

    private func purchase() async {
        do {
            try await subscriptionManager.purchasePro()
            if subscriptionManager.isPro {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func restore() async {
        isRestoring = true
        do {
            try await subscriptionManager.restorePurchases()
            if subscriptionManager.isPro {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isRestoring = false
    }
}

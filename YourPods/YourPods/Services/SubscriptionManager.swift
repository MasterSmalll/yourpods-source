import Foundation
import RevenueCat
import os

// ─── YourPods Sync ───────────────────────────────────────────────────────
// SubscriptionManager wraps RevenueCat for in-app purchase management.
// The server (sync.yourpods.app) is the source of truth for Pro entitlements.
// RevenueCat handles Apple receipt validation and fires webhooks to the server.
// ─────────────────────────────────────────────────────────────────────────

/// Manages YourPods Pro subscription state via RevenueCat.
///
/// The app checks entitlement from the server (`validateSession`) as the primary
/// source. RevenueCat entitlements are a local fallback for offline/edge cases.
@MainActor
@Observable
final class SubscriptionManager: NSObject {

    /// The server's authoritative Pro verdict (from `/auth/session`). The server is the
    /// single source of truth; this is the floor that RevenueCat may never pull down.
    private(set) var serverIsPro: Bool = false

    /// The local RevenueCat entitlement view. Used only to *upgrade* — e.g. optimistic
    /// unlock right after an in-app purchase, before the webhook reaches the server.
    /// A stale/inactive RevenueCat read must never downgrade a server-confirmed Pro
    /// (e.g. someone who subscribed on the web, whose local `customerInfo` hasn't refreshed).
    private(set) var rcIsPro: Bool = false

    /// Whether the current user has an active Pro subscription.
    /// Server-authoritative, upgrade-only: Pro if the server says so OR RevenueCat has a
    /// fresh local entitlement. RevenueCat can raise this but never lower it below the
    /// server's verdict.
    var isPro: Bool { serverIsPro || rcIsPro }

    /// Whether RevenueCat has been configured this launch. Configure runs exactly once;
    /// subsequent identity changes go through `logIn`/`logOut`.
    ///
    /// **Read this before touching `Purchases.shared` anywhere.** That getter is a
    /// trapping `fatalError` when `Purchases.configure` never ran, and configure happens
    /// only in `identify(firebaseUID:earlyAdopterPricingEligible:)` — which needs a
    /// Firebase UID. Vault, gPodder/Nextcloud, and offline users therefore reach the
    /// paywall unconfigured, and they are exactly who the Pro nudge targets.
    /// This has shipped as a crash before: `Purchases.shared.getter` →
    /// `restorePurchases()` → `ProPaywallView.restore()`.
    private(set) var isConfigured = false

    /// Whether a purchase is currently in progress.
    private(set) var isPurchasing: Bool = false

    /// Last purchase error message for display.
    private(set) var purchaseError: String?

    /// The current RevenueCat offering (product + pricing info).
    private(set) var currentOffering: Offering?

    private static let logger = Logger(subsystem: "com.yourpods", category: "subscription")

    /// RevenueCat public SDK key. Placeholder in the open-source mirror — supply your own
    /// from the RevenueCat dashboard if you build against your own YourPods Cloud server.
    /// Only the optional hosted-account path reads this; Vault, gPodder and Nextcloud never do.
    private static let apiKey = "YOUR_REVENUECAT_API_KEY"

    // MARK: - Configuration

    /// Identify the user to RevenueCat by their **Firebase UID**.
    ///
    /// This is the linchpin of buy-anywhere/use-everywhere: the server keys RevenueCat
    /// customers by Firebase UID (`app_user_id`), so a web purchase and an app
    /// (App Store) purchase resolve to the same customer only if the app identifies with
    /// that exact UID. **Never runs anonymous** — the server ignores `$RC*` ids, so an
    /// anonymous purchase can never map to an account.
    ///
    /// Configure runs once per launch; later identity changes (user switch) go through
    /// `logIn` so RevenueCat migrates the alias correctly.
    ///
    /// - Parameters:
    ///   - firebaseUID: The Firebase Auth UID (RevenueCat `appUserID`).
    ///   - earlyAdopterPricingEligible: Server decision — show the `early_adopter`
    ///     offering when true, else the `default` one.
    @MainActor
    func identify(firebaseUID: String, earlyAdopterPricingEligible: Bool) {
        guard !firebaseUID.isEmpty else {
            Self.logger.error("identify called with empty Firebase UID — skipping (would run anonymous)")
            return
        }

        if !isConfigured {
            Purchases.configure(
                with: .builder(withAPIKey: Self.apiKey)
                    .with(appUserID: firebaseUID)
                    .build()
            )
            Purchases.shared.delegate = self
            isConfigured = true
            Self.logger.info("RevenueCat configured for \(firebaseUID, privacy: .private)")
        } else {
            Task {
                do {
                    _ = try await Purchases.shared.logIn(firebaseUID)
                    Self.logger.info("RevenueCat logIn succeeded")
                } catch {
                    Self.logger.error("RevenueCat logIn failed: \(error.localizedDescription)")
                }
            }
        }

        Task {
            await fetchOfferings(eligibleForEarlyAdopter: earlyAdopterPricingEligible)
            await refreshEntitlement()
        }
    }

    /// Detach the RevenueCat identity on sign-out and clear local Pro state.
    /// RevenueCat reverts to an anonymous id (fine — signed-out users don't purchase).
    @MainActor
    func signOut() {
        serverIsPro = false
        rcIsPro = false
        guard isConfigured else { return }
        Task {
            do {
                _ = try await Purchases.shared.logOut()
                Self.logger.info("RevenueCat logOut succeeded")
            } catch {
                Self.logger.error("RevenueCat logOut failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Entitlement

    /// Refresh subscription status. A server value sets the authoritative floor; a nil
    /// value only consults RevenueCat's local cache to *upgrade* (never downgrade).
    ///
    /// - Parameter serverIsPro: If provided, becomes the authoritative server verdict.
    ///   If nil, check RevenueCat's local entitlement cache (upgrade-only).
    func refreshEntitlement(fromServer serverIsPro: Bool? = nil) async {
        if let serverIsPro {
            self.serverIsPro = serverIsPro
            Self.logger.info("Pro status from server: \(serverIsPro)")
            return
        }

        // Fallback: RevenueCat local entitlement — upgrade-only, never clears the server floor.
        guard isConfigured else {
            Self.logger.info("refreshEntitlement: RevenueCat not configured — keeping server verdict")
            return
        }
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            let hasEntitlement = customerInfo.entitlements["pro"]?.isActive == true
            applyRevenueCatEntitlement(isActive: hasEntitlement)
            Self.logger.info("Pro status from RevenueCat: \(hasEntitlement)")
        } catch {
            Self.logger.error("Failed to check RevenueCat entitlement: \(error.localizedDescription)")
        }
    }

    /// Apply Pro entitlement from a server `/auth/session` response.
    ///
    /// The server is the source of truth for Pro (see file header). Call this right
    /// after `validateSession()` on sign-in and on launch so the account's Pro status
    /// is reflected immediately — otherwise `isPro` stays false and the upgrade
    /// nag/paywall shows even for an account that already has Pro.
    @MainActor
    func applyServerSession(_ session: ProSessionResponse) {
        serverIsPro = session.isProEntitled
        Self.logger.info("Pro status from /auth/session: isPro=\(self.serverIsPro), tier=\(session.accountTier ?? "nil"), earlyAdopter=\(session.isEarlyAdopter ?? false)")
    }

    /// Apply a RevenueCat entitlement signal (delegate update, purchase, restore, or the
    /// offline fallback). This only ever moves the *local* RevenueCat view — it can
    /// upgrade `isPro`, but because the server verdict is OR'd in, it can never downgrade
    /// a server-confirmed Pro.
    @MainActor
    func applyRevenueCatEntitlement(isActive: Bool) {
        rcIsPro = isActive
    }

    // MARK: - Purchase

    /// Purchase the Pro subscription via RevenueCat.
    ///
    /// Never double-sells: if the account is already Pro (e.g. bought on web and the
    /// server session already unlocked it), this is a no-op. Callers should suppress the
    /// paywall for entitled users too; this is the last-line guard.
    @MainActor
    func purchasePro() async throws {
        guard !isPro else {
            Self.logger.info("purchasePro skipped — already Pro (never double-sell)")
            return
        }
        guard isConfigured else {
            Self.logger.error("purchasePro: RevenueCat not configured — no Firebase identity this launch")
            throw SubscriptionError.notConfigured
        }
        guard let offering = currentOffering,
              let package = offering.availablePackages.first else {
            throw SubscriptionError.noProductAvailable
        }

        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if !result.userCancelled {
                applyRevenueCatEntitlement(isActive: result.customerInfo.entitlements["pro"]?.isActive == true)
                Self.logger.info("Purchase completed, pro=\(self.isPro)")
            }
        } catch {
            purchaseError = error.localizedDescription
            Self.logger.error("Purchase failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Restore previous Apple IAP purchases via RevenueCat.
    @MainActor
    func restorePurchases() async throws {
        guard isConfigured else {
            Self.logger.error("restorePurchases: RevenueCat not configured — no Firebase identity this launch")
            throw SubscriptionError.notConfigured
        }
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            applyRevenueCatEntitlement(isActive: customerInfo.entitlements["pro"]?.isActive == true)
            Self.logger.info("Restore completed, pro=\(self.isPro)")
        } catch {
            Self.logger.error("Restore failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Offerings

    /// Fetch the appropriate offering based on early-adopter pricing eligibility.
    ///
    /// Eligibility is a **server** decision (`earlyAdopterPricingEligible` from
    /// `/auth/session`), never derived locally, so web and app always agree on who qualifies.
    /// Eligible users see the `early_adopter` offering; everyone else sees `default`.
    /// Prices come from App Store Connect via RevenueCat — never hardcoded here.
    func fetchOfferings(eligibleForEarlyAdopter: Bool) async {
        guard isConfigured else {
            Self.logger.error("fetchOfferings: RevenueCat not configured — skipping")
            return
        }
        do {
            let offerings = try await Purchases.shared.offerings()
            if eligibleForEarlyAdopter, let earlyBird = offerings.offering(identifier: "early_adopter") {
                currentOffering = earlyBird
                Self.logger.info("Using early_adopter offering")
            } else {
                currentOffering = offerings.current
                Self.logger.info("Using default offering")
            }
        } catch {
            Self.logger.error("Failed to fetch offerings: \(error.localizedDescription)")
        }
    }

    // MARK: - Pricing Helpers

    /// Localized price string for display (e.g., "$29.99/year").
    var localizedPrice: String? {
        currentOffering?.availablePackages.first?.localizedPriceString
    }

    /// The subscription period description (e.g., "year").
    var periodDescription: String? {
        currentOffering?.availablePackages.first?.storeProduct.subscriptionPeriod?.periodDescription
    }
}

// MARK: - PurchasesDelegate

extension SubscriptionManager: PurchasesDelegate {
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        let newPro = customerInfo.entitlements["pro"]?.isActive == true
        Task { @MainActor in
            self.applyRevenueCatEntitlement(isActive: newPro)
            Self.logger.info("RevenueCat delegate update: pro=\(newPro)")
        }
    }
}

// MARK: - Errors

enum SubscriptionError: LocalizedError {
    case noProductAvailable
    /// RevenueCat was never configured this launch — see `SubscriptionManager.isConfigured`.
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .noProductAvailable:
            return "No subscription product is currently available. Please try again later."
        case .notConfigured:
            return "Sign in to your YourPods account to buy or restore a subscription."
        }
    }
}

// MARK: - StoreProduct Extension

private extension SubscriptionPeriod {
    var periodDescription: String {
        switch unit {
        case .month: return value == 1 ? "month" : "\(value) months"
        case .year: return value == 1 ? "year" : "\(value) years"
        case .week: return value == 1 ? "week" : "\(value) weeks"
        case .day: return value == 1 ? "day" : "\(value) days"
        @unknown default: return ""
        }
    }
}

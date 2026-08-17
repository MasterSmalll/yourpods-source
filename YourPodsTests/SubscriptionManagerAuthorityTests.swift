import XCTest
@testable import YourPods

/// Pins the server-authoritative, upgrade-only entitlement model in `SubscriptionManager`.
///
/// Background: a user who bought Pro on the **web** is Pro server-side,
/// but their local RevenueCat `customerInfo` may not reflect it yet. The old code set
/// `isPro` directly from RevenueCat in the delegate and the offline fallback, so a
/// server-confirmed Pro could be **downgraded** to non-Pro by a stale RevenueCat read —
/// showing the paywall to (and re-selling) an existing subscriber.
///
/// The model: `isPro == serverIsPro || rcIsPro`. The server verdict is authoritative;
/// RevenueCat may only *upgrade* (optimistic unlock right after an in-app purchase),
/// never *downgrade* a server-confirmed Pro.
@MainActor
final class SubscriptionManagerAuthorityTests: XCTestCase {

    private func proSession() throws -> ProSessionResponse {
        let json = #"{"user": {"id": "u1", "email": "a@b.com", "firebaseUid": "fuid"}, "appPassword": null, "isNewUser": false, "accountTier": "pro", "isEarlyAdopter": false, "isPro": true}"#
        return try JSONDecoder().decode(ProSessionResponse.self, from: Data(json.utf8))
    }

    private func syncSession() throws -> ProSessionResponse {
        let json = #"{"user": {"id": "u1", "email": "a@b.com", "firebaseUid": "fuid"}, "appPassword": null, "isNewUser": false, "accountTier": "sync", "isEarlyAdopter": false, "isPro": false}"#
        return try JSONDecoder().decode(ProSessionResponse.self, from: Data(json.utf8))
    }

    /// A stale RevenueCat "inactive" must NOT downgrade a server-confirmed Pro.
    func test_revenueCatInactive_doesNotDowngradeServerPro() throws {
        let m = SubscriptionManager()
        m.applyServerSession(try proSession())          // server: Pro
        XCTAssertTrue(m.isPro)

        m.applyRevenueCatEntitlement(isActive: false)   // stale RC read (e.g. web buyer)
        XCTAssertTrue(m.isPro, "RevenueCat must not downgrade a server-confirmed Pro")
    }

    /// RevenueCat active must upgrade an as-yet-not-Pro account (optimistic unlock
    /// immediately after an in-app purchase, before the webhook lands server-side).
    func test_revenueCatActive_upgradesBeforeServerConfirms() throws {
        let m = SubscriptionManager()
        m.applyServerSession(try syncSession())         // server: not Pro yet
        XCTAssertFalse(m.isPro)

        m.applyRevenueCatEntitlement(isActive: true)    // fresh in-app purchase
        XCTAssertTrue(m.isPro, "A fresh RevenueCat entitlement optimistically unlocks Pro")
    }

    /// Both sources negative → not Pro.
    func test_bothInactive_isNotPro() throws {
        let m = SubscriptionManager()
        m.applyServerSession(try syncSession())
        m.applyRevenueCatEntitlement(isActive: false)
        XCTAssertFalse(m.isPro)
    }

    /// Server Pro alone (no RevenueCat signal) → Pro. This is the web-buyer case:
    /// signed into the app, never purchased in-app, RevenueCat locally silent.
    func test_serverProAlone_isPro() throws {
        let m = SubscriptionManager()
        m.applyServerSession(try proSession())
        XCTAssertTrue(m.isPro, "A web subscriber is Pro from the server alone")
    }

    /// A later server session that says not-Pro (genuine downgrade — cancellation
    /// reflected server-side) does clear Pro, even if a prior RC signal was inactive.
    func test_serverDowngrade_clearsPro() throws {
        let m = SubscriptionManager()
        m.applyServerSession(try proSession())
        XCTAssertTrue(m.isPro)

        m.applyServerSession(try syncSession())         // server now says not Pro
        XCTAssertFalse(m.isPro, "An authoritative server downgrade clears Pro")
    }

    // MARK: - Unconfigured RevenueCat must never trap

    /// `Purchases.shared` is a trapping getter — it calls `fatalError` when
    /// `Purchases.configure` was never run. `configure` happens in exactly one place,
    /// `identify(firebaseUID:earlyAdopterPricingEligible:)`, which early-returns on an
    /// empty UID — so RevenueCat stays unconfigured for Vault, gPodder/Nextcloud, and
    /// any user whose launch `validateSession()` failed (offline). Those are precisely
    /// the non-Pro users the Settings → Pro nudge row shows the paywall to.
    ///
    /// A shipped crash (EXC_BREAKPOINT SIGTRAP):
    ///   `Purchases.shared.getter` → `SubscriptionManager.restorePurchases()`
    ///   → `ProPaywallView.restore()`
    ///
    /// Every entry point that touches `Purchases.shared` must be gated on
    /// `isConfigured` and fail as a recoverable error, never a trap.

    func test_restorePurchases_whenRevenueCatUnconfigured_throwsInsteadOfTrapping() async {
        let m = SubscriptionManager()
        XCTAssertFalse(m.isConfigured, "a fresh manager has not configured RevenueCat")
        do {
            try await m.restorePurchases()
            XCTFail("restorePurchases must throw when RevenueCat was never configured")
        } catch {
            guard case SubscriptionError.notConfigured = error else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    func test_purchasePro_whenRevenueCatUnconfigured_throwsInsteadOfTrapping() async {
        let m = SubscriptionManager()
        do {
            try await m.purchasePro()
            XCTFail("purchasePro must throw when RevenueCat was never configured")
        } catch {
            guard case SubscriptionError.notConfigured = error else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    /// The non-throwing entry points must degrade to a no-op rather than trapping.
    /// `refreshEntitlement()` with no server verdict falls through to
    /// `Purchases.shared.customerInfo()`; `fetchOfferings` hits `Purchases.shared.offerings()`.
    func test_nonThrowingEntryPoints_whenRevenueCatUnconfigured_areNoOps() async {
        let m = SubscriptionManager()

        await m.refreshEntitlement()          // must not trap
        await m.fetchOfferings(eligibleForEarlyAdopter: false)   // must not trap

        XCTAssertFalse(m.isPro, "an unconfigured manager cannot claim Pro")
        XCTAssertNil(m.currentOffering, "no offering can be loaded without configuration")
    }
}

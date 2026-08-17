import XCTest
@testable import YourPods

/// Regression pin for the "Pro account still sees the upgrade nag after sign-in" bug,
/// plus the flag↔entitlement decouple.
///
/// The server's POST /auth/session response is the single source of truth. It now
/// carries an authoritative `isPro` verdict (and `earlyAdopterPricingEligible` for
/// paywall pricing) alongside `accountTier` / `isEarlyAdopter`. The iOS client must:
///   1. Prefer the server's `isPro` field — never re-derive Pro from the durable
///      `isEarlyAdopter` flag locally (a lapsed early adopter keeps the flag but is
///      not Pro; the server owns that verdict).
///   2. Fall back to `accountTier == "pro"` only when a legacy server omits `isPro`.
///   3. Flip `SubscriptionManager` Pro state from that server verdict on sign-in.
///
/// These tests pin the model decode + derivation and the wire round-trip.
@MainActor
final class ProEntitlementSignInTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a realistic /auth/session response body (camelCase, as the Go server sends).
    private func sessionJSON(
        accountTier: String?,
        isEarlyAdopter: Bool?,
        isPro: Bool? = nil,
        earlyAdopterPricingEligible: Bool? = nil
    ) -> Data {
        var fields: [String] = [
            #""user": {"id": "u1", "email": "a@b.com", "firebaseUid": "fuid"}"#,
            #""appPassword": null"#,
            #""isNewUser": false"#,
            #""deviceName": "yourpodspro""#,
        ]
        if let accountTier { fields.append(#""accountTier": "\#(accountTier)""#) }
        if let isEarlyAdopter { fields.append(#""isEarlyAdopter": \#(isEarlyAdopter)"#) }
        if let isPro { fields.append(#""isPro": \#(isPro)"#) }
        if let earlyAdopterPricingEligible {
            fields.append(#""earlyAdopterPricingEligible": \#(earlyAdopterPricingEligible)"#)
        }
        return Data("{\(fields.joined(separator: ", "))}".utf8)
    }

    // MARK: - 1. Model decode + isProEntitled

    /// Table-driven: the server's authoritative `isPro` wins when present; otherwise
    /// fall back to `accountTier == "pro"`. The durable `isEarlyAdopter` flag NEVER
    /// grants Pro on its own (that's the decouple — pricing eligibility is separate).
    func test_proSessionResponse_isProEntitled_matrix() throws {
        let cases: [(isPro: Bool?, tier: String?, early: Bool?, expected: Bool, note: String)] = [
            // Server sends the authoritative verdict → honor it verbatim.
            (true,  "sync", false, true,  "server isPro=true on sync tier is Pro (authoritative)"),
            (true,  "sync", true,  true,  "server isPro=true, early adopter → Pro"),
            (false, "pro",  false, false, "server isPro=false overrides a stale 'pro' tier"),
            (false, "sync", true,  false, "server isPro=false, early flag set → NOT Pro (decouple)"),
            // Legacy server omits isPro → fall back to tier only (flag ignored).
            (nil,   "pro",  false, true,  "fallback: paid Pro tier"),
            (nil,   "pro",  nil,   true,  "fallback: paid Pro, early flag omitted"),
            (nil,   "sync", true,  false, "fallback: early flag alone does NOT grant Pro"),
            (nil,   "sync", false, false, "fallback: free Sync account → not Pro"),
            (nil,   "pending", false, false, "fallback: unvalidated signup → not Pro"),
            (nil,   nil,    nil,   false, "legacy server omits everything → not Pro"),
        ]

        let decoder = JSONDecoder()
        for (i, c) in cases.enumerated() {
            let session = try decoder.decode(
                ProSessionResponse.self,
                from: sessionJSON(accountTier: c.tier, isEarlyAdopter: c.early, isPro: c.isPro)
            )
            XCTAssertEqual(session.accountTier, c.tier, "Case \(i): accountTier should round-trip")
            XCTAssertEqual(session.isProEntitled, c.expected,
                "Case \(i): \(c.note) → expected isProEntitled=\(c.expected)")
        }
    }

    /// The server's `earlyAdopterPricingEligible` field must decode (drives which
    /// offering the paywall shows). Absent on legacy servers → nil.
    func test_proSessionResponse_decodesEarlyAdopterPricingEligible() throws {
        let decoder = JSONDecoder()
        let eligible = try decoder.decode(ProSessionResponse.self,
            from: sessionJSON(accountTier: "sync", isEarlyAdopter: false, earlyAdopterPricingEligible: true))
        XCTAssertEqual(eligible.earlyAdopterPricingEligible, true)

        let legacy = try decoder.decode(ProSessionResponse.self,
            from: sessionJSON(accountTier: "sync", isEarlyAdopter: false))
        XCTAssertNil(legacy.earlyAdopterPricingEligible, "Legacy server omits the field")
    }

    /// The Firebase UID must decode off the session — it is RevenueCat's appUserID,
    /// the identity that ties a web purchase and an App Store purchase together.
    func test_proSessionResponse_decodesFirebaseUID() throws {
        let session = try JSONDecoder().decode(
            ProSessionResponse.self, from: sessionJSON(accountTier: "pro", isEarlyAdopter: false))
        XCTAssertEqual(session.user.firebaseUid, "fuid", "firebaseUid must decode for RevenueCat identity")
    }

    // MARK: - 2. SubscriptionManager.applyServerSession

    /// Applying a server session must set Pro to the session's authoritative verdict.
    func test_applyServerSession_setsIsPro_fromServerVerdict() throws {
        let decoder = JSONDecoder()
        let manager = SubscriptionManager()
        XCTAssertFalse(manager.isPro, "Precondition: fresh manager is not Pro")

        let proSession = try decoder.decode(
            ProSessionResponse.self, from: sessionJSON(accountTier: "pro", isEarlyAdopter: false))
        manager.applyServerSession(proSession)
        XCTAssertTrue(manager.isPro, "Signing into a Pro account must set isPro = true")

        let syncSession = try decoder.decode(
            ProSessionResponse.self, from: sessionJSON(accountTier: "sync", isEarlyAdopter: false))
        manager.applyServerSession(syncSession)
        XCTAssertFalse(manager.isPro, "A Sync-tier session must not be treated as Pro")
    }

    /// The durable early-adopter flag alone (legacy server, no `isPro`) must NOT be
    /// treated as Pro — this is the decouple that prevents a lapsed early adopter
    /// from keeping Pro UI forever.
    func test_applyServerSession_earlyAdopterFlagAlone_isNotPro() throws {
        let manager = SubscriptionManager()
        let session = try JSONDecoder().decode(
            ProSessionResponse.self, from: sessionJSON(accountTier: "sync", isEarlyAdopter: true))
        manager.applyServerSession(session)
        XCTAssertFalse(manager.isPro, "Early-adopter flag without a server Pro verdict is not Pro")
    }

    /// When the server explicitly says a (possibly sync-tier) account is Pro, honor it.
    func test_applyServerSession_serverIsProVerdict_isHonored() throws {
        let manager = SubscriptionManager()
        let session = try JSONDecoder().decode(
            ProSessionResponse.self,
            from: sessionJSON(accountTier: "sync", isEarlyAdopter: true, isPro: true))
        manager.applyServerSession(session)
        XCTAssertTrue(manager.isPro, "Server's authoritative isPro=true must set Pro")
    }

    // MARK: - 3. End-to-end wire decode via validateSession()

    /// `validateSession()` must decode the tier off the wire (the client uses
    /// .convertFromSnakeCase; the server keys are camelCase-without-underscores so
    /// they must pass through unchanged) and yield the right Pro entitlement.
    func test_validateSession_decodesAccountTier_fromWire() async throws {
        SessionMockURLProtocol.responseBody = sessionJSON(accountTier: "pro", isEarlyAdopter: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: SessionStubAuthProvider(),
            session: session
        )

        let response = try await client.validateSession()

        XCTAssertEqual(response.accountTier, "pro", "accountTier must decode off the wire")
        XCTAssertTrue(response.isProEntitled, "A 'pro' tier session must be Pro-entitled")
    }

    /// Backward compatibility: a legacy server response without the tier fields must
    /// still decode (the fields are optional) and resolve to non-Pro rather than throwing.
    func test_validateSession_legacyResponse_withoutTier_decodes() async throws {
        SessionMockURLProtocol.responseBody = sessionJSON(accountTier: nil, isEarlyAdopter: nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: SessionStubAuthProvider(),
            session: session
        )

        let response = try await client.validateSession()

        XCTAssertNil(response.accountTier, "Legacy response has no accountTier")
        XCTAssertFalse(response.isProEntitled, "Missing tier must default to non-Pro")
    }
}

// MARK: - Mocks

private final class SessionStubAuthProvider: AuthProvider, @unchecked Sendable {
    var isAuthenticated: Bool { true }
    var currentUserEmail: String? { "test@example.com" }
    func signIn(email: String, password: String) async throws -> String { "stub-token" }
    func createUser(email: String, password: String) async throws -> String { "stub-token" }
    func getValidToken() async throws -> String { "stub-token" }
    func signOut() async {}
}

private final class SessionMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

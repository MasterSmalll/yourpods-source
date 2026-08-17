import XCTest
@testable import YourPods

/// Firebase must not be configured from a placeholder `GoogleService-Info.plist`.
///
/// The open-source mirror ships the plist with `YOUR_*` placeholders. Firebase raises
/// an uncatchable exception on a malformed `GOOGLE_APP_ID`, so a presence-only check
/// crashed every clone at launch. These pin the value check that replaced it.
final class FirebaseBootstrapTests: XCTestCase {

    private func realPlist(overrides: [String: Any] = [:]) -> [String: Any] {
        var plist: [String: Any] = [
            // Deliberately not shaped like a real Google API key — `isUsable` only
            // checks for presence and placeholders here, and a realistic-looking key
            // would trip secret scanners on every push.
            "API_KEY": "test-api-key",
            "GOOGLE_APP_ID": "1:123456789012:ios:abcdef0123456789",
            "GCM_SENDER_ID": "123456789012",
            "PROJECT_ID": "example-project",
        ]
        for (key, value) in overrides { plist[key] = value }
        return plist
    }

    // MARK: - Usable configurations

    func test_realConfiguration_isUsable() {
        XCTAssertTrue(FirebaseBootstrap.isUsable(realPlist()))
    }

    /// Extra keys Firebase ships (STORAGE_BUCKET, IS_*) must not affect the verdict.
    func test_extraKeys_doNotAffectVerdict() {
        let plist = realPlist(overrides: [
            "STORAGE_BUCKET": "example-project.firebasestorage.app",
            "IS_ANALYTICS_ENABLED": false,
        ])
        XCTAssertTrue(FirebaseBootstrap.isUsable(plist))
    }

    // MARK: - The sanitized mirror's own plist

    /// The exact placeholder set this repository ships. If someone re-sanitizes with a
    /// different placeholder token, this test is the thing that should fail.
    func test_mirrorPlaceholders_areNotUsable() {
        let plist: [String: Any] = [
            "API_KEY": "YOUR_API_KEY",
            "GOOGLE_APP_ID": "YOUR_GOOGLE_APP_ID",
            "GCM_SENDER_ID": "YOUR_GCM_SENDER_ID",
            "PROJECT_ID": "YOUR_PROJECT_ID",
        ]
        XCTAssertFalse(FirebaseBootstrap.isUsable(plist),
                       "Configuring Firebase from the mirror's placeholders crashes at launch")
    }

    func test_anyPlaceholderKey_isNotUsable() {
        for key in ["API_KEY", "GOOGLE_APP_ID", "GCM_SENDER_ID", "PROJECT_ID"] {
            XCTAssertFalse(FirebaseBootstrap.isUsable(realPlist(overrides: [key: "YOUR_\(key)"])),
                           "\(key) left as a placeholder must disable Firebase")
        }
    }

    // MARK: - Missing and empty values

    func test_missingRequiredKey_isNotUsable() {
        for key in ["API_KEY", "GOOGLE_APP_ID", "GCM_SENDER_ID", "PROJECT_ID"] {
            var plist = realPlist()
            plist.removeValue(forKey: key)
            XCTAssertFalse(FirebaseBootstrap.isUsable(plist), "missing \(key) must disable Firebase")
        }
    }

    func test_emptyValue_isNotUsable() {
        XCTAssertFalse(FirebaseBootstrap.isUsable(realPlist(overrides: ["API_KEY": ""])))
    }

    func test_nonStringValue_isNotUsable() {
        XCTAssertFalse(FirebaseBootstrap.isUsable(realPlist(overrides: ["PROJECT_ID": 42])))
    }

    // MARK: - GOOGLE_APP_ID shape

    func test_wellFormedAppID() {
        XCTAssertTrue(FirebaseBootstrap.isWellFormedGoogleAppID("1:123456789012:ios:abcdef0123456789"))
    }

    func test_malformedAppIDs() {
        let bad = [
            "YOUR_GOOGLE_APP_ID",           // the placeholder
            "",                             // empty
            "1:123456789012:ios",           // too few components
            "1:123456789012:ios:abc:extra", // too many components
            "2:123456789012:ios:abcdef",    // wrong version prefix
            "1:notanumber:ios:abcdef",      // non-numeric project number
            "1::ios:abcdef",                // empty project number
            "1:123456789012:android:abcdef",// wrong platform
            "1:123456789012:ios:",          // empty hex suffix
            "1:123456789012:ios:xyz!@#",    // non-hex suffix
        ]
        for appID in bad {
            XCTAssertFalse(FirebaseBootstrap.isWellFormedGoogleAppID(appID),
                           "\(appID) must be rejected")
        }
    }
}

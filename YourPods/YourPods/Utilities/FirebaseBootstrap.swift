import Foundation

/// Decides whether `FirebaseApp.configure()` can safely run.
///
/// Firebase is optional in YourPods: it backs the hosted YourPods Cloud account only.
/// Vault Mode, gPodder and Nextcloud sync never touch it.
///
/// The open-source mirror ships `GoogleService-Info.plist` with `YOUR_*` placeholders
/// rather than real credentials. Firebase raises an uncatchable exception when
/// `GOOGLE_APP_ID` is malformed, so a presence-only check ("is the file there?") would
/// crash the app at launch for anyone who cloned the repo and hit Run. This checks the
/// values, not just the file.
///
/// To enable the hosted account in your own build, drop your real
/// `GoogleService-Info.plist` from the Firebase console over the placeholder one.
enum FirebaseBootstrap {

    /// `true` when a real `GoogleService-Info.plist` is bundled.
    static var hasUsableConfiguration: Bool {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return false
        }
        return isUsable(plist)
    }

    /// Testable core. A configuration is usable when the keys Firebase validates at
    /// startup are present, non-empty, not placeholders, and — for `GOOGLE_APP_ID` —
    /// shaped the way Firebase requires (`1:<sender>:ios:<hex>`).
    static func isUsable(_ plist: [String: Any]) -> Bool {
        let required = ["API_KEY", "GOOGLE_APP_ID", "GCM_SENDER_ID", "PROJECT_ID"]
        for key in required {
            guard let value = plist[key] as? String,
                  !value.isEmpty,
                  !value.hasPrefix("YOUR_"),
                  !value.contains("YOUR_") else { return false }
        }
        guard let appID = plist["GOOGLE_APP_ID"] as? String else { return false }
        return isWellFormedGoogleAppID(appID)
    }

    /// Firebase's own `GOOGLE_APP_ID` shape: `1:<project number>:ios:<hex>`.
    /// It validates this at configure time and raises if it does not match.
    static func isWellFormedGoogleAppID(_ appID: String) -> Bool {
        let parts = appID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        guard parts[0] == "1" else { return false }
        guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return false }
        guard parts[2] == "ios" else { return false }
        guard !parts[3].isEmpty,
              parts[3].allSatisfy({ $0.isHexDigit }) else { return false }
        return true
    }
}

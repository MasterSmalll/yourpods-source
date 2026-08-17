import Foundation
import os
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif
import FirebaseCore

/// Errors surfaced when an App Check token can't be produced.
enum AppCheckTokenError: Error, Equatable {
    /// Firebase isn't configured (e.g. OSS build with no GoogleService-Info.plist),
    /// or App Check has no usable provider on this device.
    case unavailable
}

/// Supplies a Firebase App Check token for the share endpoint. A protocol so
/// tests can inject a fake without a Secure Enclave / Firebase.
protocol AppCheckTokenProviding: Sendable {
    func token(forcingRefresh: Bool) async throws -> String
}

/// Firebase-backed implementation. Returns `.unavailable` when Firebase isn't
/// configured so `ShareLinkBuilder` degrades to a plain link.
struct FirebaseAppCheckTokenProvider: AppCheckTokenProviding {
    private var logger: Logger { Logger(subsystem: "com.yourpods", category: "share") }

    func token(forcingRefresh: Bool) async throws -> String {
        guard FirebaseApp.app() != nil else {
            logger.debug("App Check token unavailable — Firebase not configured")
            throw AppCheckTokenError.unavailable
        }
        #if canImport(FirebaseAppCheck)
        do {
            let result = try await AppCheck.appCheck().token(forcingRefresh: forcingRefresh)
            return result.token
        } catch {
            logger.error("App Check token fetch failed: \(error.localizedDescription)")
            throw error
        }
        #else
        throw AppCheckTokenError.unavailable
        #endif
    }
}

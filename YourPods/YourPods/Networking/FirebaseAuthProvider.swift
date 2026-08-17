// ─── YourPods Sync ───────────────────────────────────────────────────────
// Firebase Auth is used EXCLUSIVELY for YourPods Sync account
// authentication. It is NOT required to build or run the app —
// Vault Mode (local-only) and gPodder sync work without it.
//
// This is the concrete AuthProvider implementation that wraps the
// Firebase iOS SDK. The app can swap this for SupabaseAuthProvider
// or any other JWT-issuing backend without changing client code.
//
// For up-to-date information on the app source and YourPods Sync
// spec/source, visit: https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

import Foundation
import FirebaseCore
import FirebaseAuth
import os


/// Concrete `AuthProvider` backed by the Firebase iOS SDK.
///
/// Firebase handles token caching, automatic refresh, and Keychain persistence
/// internally. This class simply bridges the SDK calls into the `AuthProvider`
/// protocol that `YourPodsProClient` uses.
///
/// Thread safety: all Firebase Auth methods are internally thread-safe.
/// The `@unchecked Sendable` conformance reflects that the underlying
/// `Auth` singleton manages its own synchronization.
final class FirebaseAuthProvider: AuthProvider, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.yourpods", category: "FirebaseAuth")
    
    // MARK: - Firebase availability guard
    
    /// `true` if `FirebaseApp.configure()` has been called (i.e. GoogleService-Info.plist
    /// is present in the bundle). If `false`, all Auth calls would assert-crash.
    private static var isConfigured: Bool { FirebaseApp.app() != nil }
    
    private func requireConfigured() throws {
        guard Self.isConfigured else {
            logger.error("FirebaseApp not configured — GoogleService-Info.plist missing from bundle")
            throw AuthProviderError.unknown(
                message: "YourPods Sync is not available in this build. Please download YourPods from the App Store."
            )
        }
    }
    
    // MARK: - AuthProvider
    
    var isAuthenticated: Bool {
        guard Self.isConfigured else { return false }
        return Auth.auth().currentUser != nil
    }
    
    var currentUserEmail: String? {
        guard Self.isConfigured else { return nil }
        return Auth.auth().currentUser?.email
    }
    
    func signIn(email: String, password: String) async throws -> String {
        try requireConfigured()
        guard EmailValidator.isValid(email) else {
            logger.error("Sign-in rejected: invalid email format")
            throw AuthProviderError.invalidEmail
        }
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            let token = try await result.user.getIDToken()
            logger.info("Firebase sign-in successful for \(email)")
            return token
        } catch let error as NSError {
            logger.error("Firebase sign-in failed: \(error.localizedDescription)")
            
            // Map Firebase error codes to our domain errors
            switch error.code {
            case AuthErrorCode.wrongPassword.rawValue,
                 AuthErrorCode.userNotFound.rawValue,
                 AuthErrorCode.invalidEmail.rawValue,
                 AuthErrorCode.invalidCredential.rawValue:
                throw AuthProviderError.invalidCredentials
            case AuthErrorCode.networkError.rawValue:
                throw AuthProviderError.networkError(underlying: error)
            default:
                throw AuthProviderError.unknown(message: error.localizedDescription)
            }
        }
    }
    
    func createUser(email: String, password: String) async throws -> String {
        try requireConfigured()
        guard EmailValidator.isValid(email) else {
            logger.error("Account creation rejected: invalid email format")
            throw AuthProviderError.invalidEmail
        }
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let token = try await result.user.getIDToken()
            logger.info("Firebase account created for \(email)")
            return token
        } catch let error as NSError {
            logger.error("Firebase account creation failed: \(error.localizedDescription)")
            
            switch error.code {
            case AuthErrorCode.emailAlreadyInUse.rawValue:
                throw AuthProviderError.emailAlreadyInUse
            case AuthErrorCode.invalidEmail.rawValue:
                throw AuthProviderError.invalidCredentials
            case AuthErrorCode.weakPassword.rawValue:
                throw AuthProviderError.unknown(message: "Password is too weak. Please use at least 6 characters.")
            case AuthErrorCode.networkError.rawValue:
                throw AuthProviderError.networkError(underlying: error)
            default:
                throw AuthProviderError.unknown(message: error.localizedDescription)
            }
        }
    }
    
    func getValidToken() async throws -> String {
        try requireConfigured()
        guard let user = Auth.auth().currentUser else {
            logger.warning("getValidToken called but no current user")
            throw AuthProviderError.notAuthenticated
        }
        
        do {
            // Firebase SDK automatically refreshes expired tokens (1hr TTL).
            // getIDToken(forcingRefresh: false) returns a cached token if still
            // valid, or silently refreshes if expired.
            let token = try await user.getIDToken()
            return token
        } catch {
            logger.error("Token refresh failed: \(error.localizedDescription)")
            throw AuthProviderError.networkError(underlying: error)
        }
    }
    
    func signOut() async {
        guard Self.isConfigured else { return }
        do {
            try Auth.auth().signOut()
            logger.info("Firebase sign-out successful")
        } catch {
            // Log and continue — never crash the player
            logger.error("Firebase sign-out failed: \(error.localizedDescription)")
        }
    }
}

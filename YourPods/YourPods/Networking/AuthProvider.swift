// ─── YourPods Sync ───────────────────────────────────────────────────────
// The AuthProvider protocol and its Firebase implementation are used
// EXCLUSIVELY for YourPods Sync account authentication. They are NOT
// required to build or run the app — Vault Mode (local-only) and gPodder
// sync work without them.
//
// AuthProvider is a protocol so the app can swap Firebase for Supabase
// or any JWT-issuing backend in the future without changing client code.
//
// For up-to-date information on the app source and YourPods Sync
// spec/source, visit: https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

import Foundation

/// Abstracts the authentication provider (Firebase, Supabase, etc.).
/// `YourPodsProClient` depends on this protocol, never a concrete auth type.
/// Supports both sign-in and account creation for YourPods Sync.
protocol AuthProvider: Sendable {
    /// Sign in with email + password. Returns a valid JWT (ID token).
    func signIn(email: String, password: String) async throws -> String
    
    /// Create a new account with email + password. Returns a valid JWT (ID token).
    func createUser(email: String, password: String) async throws -> String
    
    /// Get a valid access token (JWT), refreshing if expired.
    /// Call before every API request.
    func getValidToken() async throws -> String
    
    /// Sign out — clear all stored credentials and session state.
    func signOut() async
    
    /// Whether the user has an active session (stored refresh token).
    var isAuthenticated: Bool { get async }
    
    /// The currently signed-in user's email, if available.
    var currentUserEmail: String? { get async }
}

/// Errors from auth operations.
enum AuthProviderError: LocalizedError {
    case notAuthenticated
    case invalidCredentials
    case invalidEmail
    case emailAlreadyInUse
    case networkError(underlying: Error)
    case unknown(message: String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in. Please sign in to your YourPods Sync account."
        case .invalidCredentials:
            return "Invalid email or password. Please try again."
        case .invalidEmail:
            return "Please enter a valid email address."
        case .emailAlreadyInUse:
            return "An account with this email already exists. Try signing in instead."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .unknown(let message):
            return message
        }
    }
}

import AuthenticationServices
import SwiftUI

/// Coordinates Nextcloud Login Flow v2 with `ASWebAuthenticationSession`.
///
/// Handles the full three-phase flow:
/// 1. **Initiate** — get login URL + poll token from the server.
/// 2. **Browser** — open `ASWebAuthenticationSession` for user authentication.
/// 3. **Poll** — receive `appPassword` when the user grants access.
///
/// The coordinator is an `ObservableObject` that publishes its state for the UI.
@MainActor
final class LoginFlowCoordinator: NSObject, ObservableObject,
                                   ASWebAuthenticationPresentationContextProviding {

    /// The current state of the login flow.
    enum State: Equatable {
        case idle
        case initiating
        case waitingForBrowser
        case success(server: String, loginName: String, appPassword: String)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.initiating, .initiating), (.waitingForBrowser, .waitingForBrowser):
                return true
            case (.success(let a, let b, _), .success(let c, let d, _)):
                return a == c && b == d
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: State = .idle

    private let loginFlowClient: LoginFlowClient
    private var flowTask: Task<Void, Never>?
    private var webAuthSession: ASWebAuthenticationSession?

    init(loginFlowClient: LoginFlowClient = LoginFlowClient()) {
        self.loginFlowClient = loginFlowClient
    }

    deinit {
        flowTask?.cancel()
    }

    // MARK: - Public API

    /// Starts the full Login Flow v2 sequence.
    ///
    /// - Parameter serverURL: Normalized HTTPS server URL (e.g. `https://cloud.example.com`).
    func startLoginFlow(serverURL: String) {
        state = .initiating
        flowTask?.cancel()

        flowTask = Task { [weak self] in
            guard let self else { return }

            do {
                // Phase 1: Initiate — get poll token + login URL
                let session = try await loginFlowClient.initiate(serverURL: serverURL)

                // Phase 2: Open browser + start polling concurrently
                state = .waitingForBrowser
                openBrowser(loginURL: session.loginURL)

                // Phase 3: Poll until user grants access or timeout
                let result = try await loginFlowClient.poll(session: session)

                // Success — dismiss browser and report credentials
                webAuthSession?.cancel()
                state = .success(
                    server: result.server,
                    loginName: result.loginName,
                    appPassword: result.appPassword
                )
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Cancels any in-progress login flow.
    func cancel() {
        flowTask?.cancel()
        webAuthSession?.cancel()
        state = .idle
    }

    // MARK: - Browser

    /// Opens `ASWebAuthenticationSession` for the user to authenticate in-browser.
    ///
    /// We detect flow completion via polling, not via the callback URL.
    /// The callback scheme is set to our existing "yourpods" scheme so that
    /// `ASWebAuthenticationSession` has a valid scheme to register, but we
    /// don't rely on it for credential delivery.
    private func openBrowser(loginURL: URL) {
        let session = ASWebAuthenticationSession(
            url: loginURL,
            callbackURLScheme: "yourpods"
        ) { [weak self] _, error in
            // If user tapped Cancel in the browser sheet
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                self?.cancel()
            }
            // Otherwise, we rely on polling to detect completion
        }

        // Allow SSO cookies to work by not using ephemeral session
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        session.start()
        webAuthSession = session
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        #if os(iOS)
        MainActor.assumeIsolated {
            UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
        #elseif os(macOS)
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? ASPresentationAnchor()
        }
        #endif
    }
}

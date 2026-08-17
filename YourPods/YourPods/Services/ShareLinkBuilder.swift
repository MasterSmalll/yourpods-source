import Foundation
import os

/// All the data needed to build a share — rich if possible, plain otherwise.
struct ShareRequest: Sendable {
    let kind: ShareKind
    let podcastUrl: String
    let episodeUrl: String?
    let episodeGuid: String?
    let startSec: Int?          // timestamp shares only
    let episodeTitle: String?
    let podcastTitle: String
    let episodeLink: String?
}

/// Produces UIActivityViewController items: a rich share.yourpods.app/s/{id}
/// link when App Check + create succeed, else the existing plain link. The
/// share gesture never dead-ends. Failures are logged, not surfaced.
struct ShareLinkBuilder: Sendable {
    let tokenProvider: AppCheckTokenProviding
    let client: ShareCreating
    /// Non-nil when the user has an active Pro session.
    /// Used to send `Authorization: Bearer` instead of `X-Firebase-AppCheck`.
    let authProvider: (any AuthProvider)?
    private var logger: Logger { Logger(subsystem: "com.yourpods", category: "share") }

    init(tokenProvider: AppCheckTokenProviding, client: ShareCreating, authProvider: (any AuthProvider)? = nil) {
        self.tokenProvider = tokenProvider
        self.client = client
        self.authProvider = authProvider
    }

    func makeItems(for req: ShareRequest) async -> [Any] {
        if let richURL = await richShareURL(for: req) {
            logger.info("Share: rich link minted (\(req.kind.rawValue, privacy: .public)) → \(richURL.absoluteString)")
            let text = ShareService.richShareText(
                episodeTitle: req.episodeTitle, podcastTitle: req.podcastTitle, startSec: req.startSec)
            return [text, richURL]
        }
        logger.info("Share: PLAIN-link fallback (\(req.kind.rawValue, privacy: .public)) — no rich link produced")
        return fallbackItems(for: req)
    }

    private func richShareURL(for req: ShareRequest) async -> URL? {
        let payload = ShareCreatePayload(
            kind: req.kind, podcastUrl: req.podcastUrl,
            episodeUrl: req.episodeUrl, episodeGuid: req.episodeGuid, startSec: req.startSec)

        // Pro path: Bearer auth → 25/day tier.
        // Must NOT send X-Firebase-AppCheck — the middleware checks it first
        // and would route to the lower 5/day cap.
        if let authProvider, await authProvider.isAuthenticated {
            logger.info("Share: trying Pro Bearer path (Firebase session active)")
            do {
                let bearerToken = try await authProvider.getValidToken()
                let url = try await client.createShareAuthenticated(payload, bearerToken: bearerToken)
                logger.info("Share: Pro Bearer create succeeded")
                return url
            } catch {
                logger.info("Share: Pro Bearer path failed — falling back to App Check (\(String(describing: error)))")
            }
        } else {
            logger.info("Share: no Firebase session — using App Check (device) path")
        }

        // App Check path: device verification → 5/day tier.
        logger.info("Share: requesting App Check token")
        do {
            let token = try await tokenProvider.token(forcingRefresh: false)
            let url = try await client.createShare(payload, token: token)
            logger.info("Share: App Check create succeeded")
            return url
        } catch ShareClientError.appCheckInvalid {
            logger.info("Share: 401 app_check_invalid — refreshing token, retrying once")
            do {
                let fresh = try await tokenProvider.token(forcingRefresh: true)
                let url = try await client.createShare(payload, token: fresh)
                logger.info("Share: App Check create succeeded after refresh")
                return url
            } catch {
                logger.info("Share: rich link failed after token refresh — plain-link fallback (\(String(describing: error)))")
                return nil
            }
        } catch ShareClientError.appNotAllowed {
            logger.warning("Share: 403 app_not_allowed — App Check allow-list/config mismatch; plain-link fallback")
            return nil
        } catch {
            logger.info("Share: rich link unavailable — plain-link fallback (\(String(describing: error)))")
            return nil
        }
    }

    private func fallbackItems(for req: ShareRequest) -> [Any] {
        switch req.kind {
        case .podcast:
            return ShareService.sharePodcast(title: req.podcastTitle, website: req.episodeLink, feedUrl: req.podcastUrl)
        case .episode:
            if let startSec = req.startSec {
                return ShareService.sharePosition(
                    episodeTitle: req.episodeTitle ?? "", podcastTitle: req.podcastTitle,
                    position: TimeInterval(startSec), link: req.episodeLink, audioUrl: req.episodeUrl)
            }
            return ShareService.shareEpisode(
                title: req.episodeTitle ?? "", podcastTitle: req.podcastTitle,
                link: req.episodeLink, audioUrl: req.episodeUrl)
        }
    }
}

extension ShareLinkBuilder {
    /// Default production builder.
    ///
    /// The `authProvider` is a `FirebaseAuthProvider`, which reads **live**
    /// Firebase auth state at share time (`isAuthenticated` → `currentUser != nil`).
    /// So the Bearer-vs-App-Check decision is made dynamically per share:
    /// a Pro user signed into Firebase gets the 25/day Bearer tier — even if
    /// they signed in mid-session — and Vault/gPodder/OSS builds (no Firebase
    /// session) fall through to the App Check device path. No re-wiring on
    /// profile switch required; `isAuthenticated` is `false` when Firebase
    /// isn't configured, so this degrades cleanly.
    nonisolated(unsafe) static var shared = ShareLinkBuilder(
        tokenProvider: FirebaseAppCheckTokenProvider(),
        client: ShareClient(),
        authProvider: FirebaseAuthProvider())
}

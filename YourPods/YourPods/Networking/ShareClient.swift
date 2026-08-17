import Foundation
import os

enum ShareKind: String, Sendable { case episode, podcast }

struct ShareCreatePayload: Sendable {
    let kind: ShareKind
    let podcastUrl: String
    let episodeUrl: String?
    let episodeGuid: String?
    let startSec: Int?
}

enum ShareClientError: Error, Equatable, Sendable {
    case appCheckInvalid     // 401 — retry-able after token refresh
    case appNotAllowed       // 403 — not retry-able
    case rejected(Int)       // other non-2xx (400/429/5xx)
    case badResponse
}

/// Creates share links; a protocol so callers can inject a fake.
protocol ShareCreating: Sendable {
    func createShare(_ payload: ShareCreatePayload, token: String) async throws -> URL
    /// Authenticated variant for Pro users — sends Bearer token instead of App Check.
    func createShareAuthenticated(_ payload: ShareCreatePayload, bearerToken: String) async throws -> URL
}

extension ShareCreating {
    func createShareAuthenticated(_ payload: ShareCreatePayload, bearerToken: String) async throws -> URL {
        throw ShareClientError.badResponse
    }
}

struct ShareClient: ShareCreating {
    private static let createURL = URL(string: "https://sync.yourpods.app/api/yourpods/share/create")!
    private let session: URLSession
    private static let logger = Logger(subsystem: "com.yourpods", category: "share")

    init(session: URLSession = .shared) { self.session = session }

    /// Pure, testable request builder.
    static func makeCreateRequest(token: String, payload: ShareCreatePayload) -> URLRequest {
        var req = URLRequest(url: createURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        let body: [String: Any] = [
            "kind": payload.kind.rawValue,
            "podcastUrl": payload.podcastUrl,
            "episodeUrl": payload.episodeUrl ?? "",
            "episodeGuid": payload.episodeGuid ?? "",
            "startSec": payload.startSec ?? 0,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Pure, testable request builder — Bearer auth variant for Pro users.
    /// Uses `Authorization: Bearer` instead of `X-Firebase-AppCheck`.
    /// IMPORTANT: Must NOT set `X-Firebase-AppCheck` — the server middleware
    /// checks that header first and would route Pro users to the 5/day cap.
    static func makeCreateRequestAuthenticated(bearerToken: String, payload: ShareCreatePayload) -> URLRequest {
        var req = URLRequest(url: createURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "kind": payload.kind.rawValue,
            "podcastUrl": payload.podcastUrl,
            "episodeUrl": payload.episodeUrl ?? "",
            "episodeGuid": payload.episodeGuid ?? "",
            "startSec": payload.startSec ?? 0,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    func createShare(_ payload: ShareCreatePayload, token: String) async throws -> URL {
        let (data, response) = try await session.data(for: Self.makeCreateRequest(token: token, payload: payload))
        return try Self.parseCreateResponse(data: data, response: response)
    }

    func createShareAuthenticated(_ payload: ShareCreatePayload, bearerToken: String) async throws -> URL {
        let (data, response) = try await session.data(for: Self.makeCreateRequestAuthenticated(bearerToken: bearerToken, payload: payload))
        return try Self.parseCreateResponse(data: data, response: response)
    }

    private static func parseCreateResponse(data: Data, response: URLResponse) throws -> URL {
        guard let http = response as? HTTPURLResponse else { throw ShareClientError.badResponse }
        switch http.statusCode {
        case 200...299:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlString = obj["shareUrl"] as? String, let url = URL(string: urlString)
            else { throw ShareClientError.badResponse }
            return url
        case 401: throw ShareClientError.appCheckInvalid
        case 403: throw ShareClientError.appNotAllowed
        default:  throw ShareClientError.rejected(http.statusCode)
        }
    }
}

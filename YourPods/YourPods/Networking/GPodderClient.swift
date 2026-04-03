import Foundation
import os

/// gPodder-compatible REST API client for Nextcloud gPodder Sync.
/// Handles subscription management and episode action sync.
actor GPodderClient {
    private let logger = Logger(subsystem: "com.yourpods", category: "GPodderClient")
    
    let baseUrl: String
    private let username: String
    private let password: String
    private let authHeader: String
    private let session: URLSession
    
    /// Session cookie from `POST /api/2/auth/{user}/login.json` (nil if not authenticated or server doesn't support it).
    private var sessionCookie: String?
    /// Whether session auth has been attempted and failed (avoids retrying on NC gPodder).
    private var sessionAuthFailed = false
    
    init(baseUrl: String, username: String, password: String, session: URLSession = .shared) {
        self.baseUrl = URLSanitizer.sanitize(baseUrl)
        self.username = username
        self.password = password
        self.session = session
        
        let credentials = "\(username):\(password)"
        let data = credentials.data(using: .utf8)!
        self.authHeader = "Basic \(data.base64EncodedString())"
    }
    
    // MARK: - Session Auth (gpodder.net API v2)
    
    /// Attempt session-based auth. Falls back to Basic auth if the server doesn't support it (e.g. NC gPodder).
    func login() async throws {
        guard !sessionAuthFailed else { return } // Don't retry if we already know it fails
        
        let url = "\(baseUrl)/api/2/auth/\(username)/login.json"
        do {
            let (_, response) = try await performPOSTRaw(url: url, body: ["username": username, "password": password])
            
            // Extract session cookie from Set-Cookie header
            if let httpResponse = response as? HTTPURLResponse,
               let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie") {
                // Extract the session ID cookie (typically "sessionid=..." or similar)
                sessionCookie = setCookie.components(separatedBy: ";").first
                logger.info("Session auth succeeded")
            }
        } catch GPodderError.httpError(let code) where code == 404 || code == 405 {
            // Server doesn't support session auth (NC gPodder) — fall back silently
            sessionAuthFailed = true
            logger.info("Server does not support session auth (\(code)), using Basic auth")
        } catch GPodderError.unauthorized {
            // Credentials are wrong even for session auth
            throw GPodderError.unauthorized
        } catch {
            // Network error or other — fall back to Basic
            sessionAuthFailed = true
            logger.warning("Session auth failed: \(error.localizedDescription). Falling back to Basic.")
        }
    }
    
    /// Logout and invalidate session cookie.
    func logout() async {
        guard sessionCookie != nil else { return }
        let url = "\(baseUrl)/api/2/auth/\(username)/logout.json"
        do {
            _ = try await performPOSTRaw(url: url, body: nil)
        } catch {
            logger.warning("Logout failed: \(error.localizedDescription)")
        }
        sessionCookie = nil
    }
    
    // MARK: - Subscriptions
    
    func getSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        let url = "\(baseUrl)/index.php/apps/gpoddersync/subscriptions?since=\(since)"
        let data = try await performGET(url: url)
        
        // Server may return a dict with add/remove/timestamp or a flat list (full sync)
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let add = (dict["add"] as? [String]) ?? []
            let remove = (dict["remove"] as? [String]) ?? []
            let timestamp = (dict["timestamp"] as? Int) ?? Int(Date().timeIntervalSince1970)
            return SubscriptionDelta(add: add, remove: remove, timestamp: timestamp)
        } else if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let urls = list.compactMap { $0["url"] as? String }
            return SubscriptionDelta(add: urls, remove: [], timestamp: Int(Date().timeIntervalSince1970))
        } else if let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return SubscriptionDelta(add: list, remove: [], timestamp: Int(Date().timeIntervalSince1970))
        }
        
        throw GPodderError.invalidResponse
    }
    
    /// Upload subscription changes and parse any `update_urls` from the response.
    func updateSubscriptions(deviceId: String, add: [String] = [], remove: [String] = []) async throws -> [URLRewrite] {
        let url = "\(baseUrl)/index.php/apps/gpoddersync/subscription_change/create?deviceid=\(deviceId)"
        let body: [String: Any] = ["add": add, "remove": remove]
        let responseData = try await performPOST(url: url, body: body)
        return parseUpdateUrls(from: responseData)
    }
    
    /// Get the full subscription list for a device (used for initial sync / re-install recovery).
    func getSubscriptions(deviceId: String) async throws -> [String] {
        // Try OPML first (gpodder.net), fall back to JSON delta with since=0 (NC gPodder)
        let delta = try await getSubscriptionChanges(deviceId: deviceId, since: 0)
        return delta.add
    }
    
    // MARK: - Devices
    
    /// Register or update a device on the server.
    func registerDevice(deviceId: String, caption: String, type: String = "mobile") async throws {
        let url = "\(baseUrl)/api/2/devices/\(username)/\(deviceId).json"
        let body: [String: Any] = ["caption": caption, "type": type]
        do {
            _ = try await performPOST(url: url, body: body)
            logger.info("Registered device: \(deviceId)")
        } catch GPodderError.httpError(let code) where code == 404 {
            // NC gPodder doesn't support device registration — that's fine
            logger.info("Server does not support device registration (404)")
        }
    }
    
    /// List devices registered on the server.
    func listDevices() async throws -> [[String: Any]] {
        let url = "\(baseUrl)/api/2/devices/\(username).json"
        do {
            let data = try await performGET(url: url)
            return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        } catch GPodderError.httpError(let code) where code == 404 {
            // NC gPodder doesn't support device listing
            return []
        }
    }
    
    // MARK: - Episode Actions
    
    /// Upload episode actions and parse any `update_urls` from the response.
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        guard !actions.isEmpty else { return [] }
        let url = "\(baseUrl)/index.php/apps/gpoddersync/episode_action/create"
        let body = actions.map { $0.toUploadJSON() }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await performPOST(url: url, bodyData: jsonData)
        return parseUpdateUrls(from: responseData)
    }
    
    func getEpisodeActions(since: Int = 0) async throws -> [EpisodeAction] {
        // Don't filter by device — we want actions from ALL devices
        // (Flutter app, other clients, etc.)
        let url = "\(baseUrl)/index.php/apps/gpoddersync/episode_action?since=\(since)"
        let data = try await performGET(url: url)
        
        let parsed = try JSONSerialization.jsonObject(with: data)
        
        var list: [[String: Any]] = []
        if let array = parsed as? [[String: Any]] {
            list = array
        } else if let dict = parsed as? [String: Any] {
            if let actions = dict["actions"] as? [[String: Any]] {
                list = actions
            } else if let dataList = dict["data"] as? [[String: Any]] {
                list = dataList
            }
        }
        
        return list.compactMap { EpisodeAction.from(json: $0) }
    }
    
    // MARK: - Private HTTP Helpers
    
    private func performGET(url urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GPodderError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }
    
    @discardableResult
    private func performPOST(url urlString: String, body: Any? = nil, bodyData: Data? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GPodderError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        if let bodyData {
            request.httpBody = bodyData
        } else if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }
    
    /// Raw POST that returns both data and response (for session auth cookie extraction).
    private func performPOSTRaw(url urlString: String, body: Any?) async throws -> (Data, URLResponse) {
        guard let url = URL(string: urlString) else { throw GPodderError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return (data, response)
    }
    
    /// Apply session cookie if available, otherwise Basic auth.
    private func applyAuth(to request: inout URLRequest) {
        if let cookie = sessionCookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
    }
    
    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GPodderError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw GPodderError.unauthorized
        case 500...599: throw GPodderError.serverError(http.statusCode)
        default: throw GPodderError.httpError(http.statusCode)
        }
    }
    
    // MARK: - update_urls Parsing
    
    /// Parse `update_urls` from a gPodder API response.
    /// The response may contain `{"update_urls": [["old_url", "new_url"], ...]}` indicating server-side URL rewrites.
    private func parseUpdateUrls(from data: Data) -> [URLRewrite] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updates = json["update_urls"] as? [[String]] else {
            return []
        }
        return updates.compactMap { pair in
            guard pair.count == 2 else { return nil }
            logger.info("Server rewrote URL: \(pair[0]) → \(pair[1])")
            return URLRewrite(oldUrl: pair[0], newUrl: pair[1])
        }
    }
}

// MARK: - URL Rewrite

/// Represents a feed URL rewrite from the server's `update_urls` response.
struct URLRewrite: Equatable {
    let oldUrl: String
    let newUrl: String
}

// MARK: - Errors

enum GPodderError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    case httpError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .invalidResponse: return "Unexpected response format"
        case .unauthorized: return "Invalid username or password"
        case .serverError(let code): return "Server error (\(code))"
        case .httpError(let code): return "Request failed (\(code))"
        }
    }
}

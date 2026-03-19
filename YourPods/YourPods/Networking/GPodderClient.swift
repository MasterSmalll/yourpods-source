import Foundation
import os

/// gPodder-compatible REST API client for Nextcloud gPodder Sync.
/// Handles subscription management and episode action sync.
actor GPodderClient {
    private let logger = Logger(subsystem: "com.yourpods", category: "GPodderClient")
    
    let baseUrl: String
    let username: String
    let password: String
    private let session: URLSession
    
    private var authHeader: String {
        let credentials = "\(username):\(password)"
        let data = credentials.data(using: .utf8)!
        return "Basic \(data.base64EncodedString())"
    }
    
    init(baseUrl: String, username: String, password: String, session: URLSession = .shared) {
        self.baseUrl = URLSanitizer.sanitize(baseUrl)
        self.username = username
        self.password = password
        self.session = session
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
    
    func updateSubscriptions(deviceId: String, add: [String] = [], remove: [String] = []) async throws {
        let url = "\(baseUrl)/index.php/apps/gpoddersync/subscription_change/create?deviceid=\(deviceId)"
        let body: [String: Any] = ["add": add, "remove": remove]
        try await performPOST(url: url, body: body)
    }
    
    // MARK: - Episode Actions
    
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws {
        guard !actions.isEmpty else { return }
        let url = "\(baseUrl)/index.php/apps/gpoddersync/episode_action/create"
        let body = actions.map { $0.toUploadJSON() }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        try await performPOST(url: url, bodyData: jsonData)
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
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }
    
    private func performPOST(url urlString: String, body: Any? = nil, bodyData: Data? = nil) async throws {
        guard let url = URL(string: urlString) else { throw GPodderError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        if let bodyData {
            request.httpBody = bodyData
        } else if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
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
}

// MARK: - Errors

enum GPodderError: LocalizedError {
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

import Foundation
import os

/// Resolves podcast tracking/ad-insertion redirect chains to the final CDN URL.
///
/// Podcast episode URLs often pass through multiple tracking hops
/// (pscrb.fm → mgln.ai → swap.fm → art19 → CDN) before reaching the actual
/// audio file. Each hop adds latency and the final CDN URL may include
/// time-limited validation tokens that expire after hours.
///
/// This service:
/// - Follows HTTP 3xx redirect chains using lightweight HEAD requests
/// - Caches resolved URLs with a configurable TTL (default 2 hours)
/// - Falls back to the original URL on any error
/// - Skips resolution for local file paths
actor URLResolver {
    private let logger = Logger(subsystem: "com.yourpods", category: "URLResolver")
    
    private var cache: [String: CacheEntry] = [:]
    private var activeTasks: [String: Task<String, Never>] = [:]
    private let cacheTTL: TimeInterval
    private let resolveTimeout: TimeInterval = 5.0
    
    struct CacheEntry {
        let resolvedUrl: String
        let resolvedAt: Date
        
        func isExpired(ttl: TimeInterval) -> Bool {
            Date().timeIntervalSince(resolvedAt) > ttl
        }
    }
    
    init(cacheTTL: TimeInterval = 2 * 60 * 60) {  // 2 hours
        self.cacheTTL = cacheTTL
    }
    
    /// Resolve [originalUrl] through its redirect chain, returning the final
    /// destination URL. Returns the original URL on any error.
    func resolveUrl(_ originalUrl: String, headers: [String: String]? = nil) async -> String {
        // Skip local file paths
        guard !originalUrl.hasPrefix("/") else { return originalUrl }
        
        // Check cache
        if let cached = cache[originalUrl], !cached.isExpired(ttl: cacheTTL) {
            logger.debug("Cache hit for \(originalUrl) → \(cached.resolvedUrl)")
            return cached.resolvedUrl
        }
        
        // Coalesce duplicate concurrent requests for the same URL
        if let activeTask = activeTasks[originalUrl] {
            logger.debug("Coalescing duplicate resolution request for \(originalUrl)")
            return await activeTask.value
        }
        
        let task = Task {
            do {
                let resolved = try await doResolve(originalUrl, headers: headers)
                return resolved
            } catch {
                logger.warning("Resolution failed for \(originalUrl) (falling back): \(error.localizedDescription)")
                return originalUrl
            }
        }
        
        activeTasks[originalUrl] = task
        let result = await task.value
        activeTasks.removeValue(forKey: originalUrl)
        
        // Always cache the result to avoid re-requesting even if no redirect occurred
        cache[originalUrl] = CacheEntry(resolvedUrl: result, resolvedAt: Date())
        
        if result != originalUrl {
            logger.info("Resolved \(originalUrl) → \(result)")
        }
        
        return result
    }
    
    /// Clear the cached entry for a URL, forcing re-resolution next time.
    /// Call before stream recovery retries to get a fresh CDN token.
    func invalidate(_ url: String) {
        cache.removeValue(forKey: url)
        logger.debug("Invalidated cache for \(url)")
    }
    
    // MARK: - Private
    
    private func doResolve(_ urlString: String, headers: [String: String]?) async throws -> String {
        guard let url = URL(string: urlString) else { return urlString }
        
        // Create a session that does NOT follow redirects automatically
        // so we can track the chain manually.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = resolveTimeout
        
        // Use a delegate that follows redirects, records the final URL,
        // and protects auth headers from leaking on cross-host redirects.
        let delegate = RedirectTracker(authHeader: headers?["Authorization"])
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("YourPods/1.0", forHTTPHeaderField: "User-Agent")
        
        // Forward auth headers (for protected feeds)
        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        let (_, response) = try await session.data(for: request)
        
        // The final URL after all redirects
        if let httpResponse = response as? HTTPURLResponse,
           let finalUrl = httpResponse.url {
            return finalUrl.absoluteString
        }
        
        // If we tracked redirects via the delegate, use the last one
        if let lastRedirect = delegate.finalURL {
            return lastRedirect.absoluteString
        }
        
        return urlString
    }
}

/// Tracks redirects through the URLSession delegate to capture the final URL.
/// Strips Authorization headers on cross-host or HTTPS→HTTP downgrade redirects
/// to prevent credential leakage through tracking/CDN redirect chains.
private final class RedirectTracker: NSObject, URLSessionTaskDelegate {
    var finalURL: URL?
    private let authHeader: String?
    
    init(authHeader: String? = nil) {
        self.authHeader = authHeader
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        finalURL = request.url
        
        // Re-attach Authorization header only if host matches and no downgrade occurs.
        // This prevents credentials from leaking to third-party tracking/CDN hosts.
        guard let authHeader,
              let originalUrl = task.originalRequest?.url,
              let newUrl = request.url,
              originalUrl.host == newUrl.host else {
            completionHandler(request)
            return
        }
        
        // Prevent credential leakage on HTTPS → HTTP downgrade
        if originalUrl.scheme == "https" && newUrl.scheme == "http" {
            completionHandler(request)
            return
        }
        
        var redirectedRequest = request
        redirectedRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        completionHandler(redirectedRequest)
    }
}

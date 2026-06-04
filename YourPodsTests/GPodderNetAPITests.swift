/// GPodder.net API & Auth Tests
import XCTest
@testable import YourPods

// MARK: - From GPodderNetAPITests.swift

/// Tests for Bug 2: gpodder.net returns 403 because GPodderClient uses Nextcloud paths.
///
/// Verifies that:
///   - GPodderClient with `.gpodderNet` flavor constructs v2 API paths
///   - GPodderClient with `.nextcloud` flavor still uses NC paths (regression safety)
///   - ProfileType has a `.gpodderNet` case
///   - Response parsing works for gpodder.net format
final class GPodderNetAPITests: XCTestCase {

    // MARK: - ProfileType

    /// ProfileType must include `.gpodderNet` as a distinct case from `.gpodder`.
    func test_profileType_hasGpodderNetCase() {
        let type = ProfileType.gpodderNet
        XCTAssertEqual(type.rawValue, "gpodderNet",
                       "ProfileType.gpodderNet should have rawValue 'gpodderNet'")
        XCTAssertNotEqual(type, ProfileType.gpodder,
                          ".gpodderNet must be distinct from .gpodder")
    }

    /// ProfileType.gpodderNet should survive Codable round-trip.
    func test_profileType_gpodderNet_codableRoundTrip() throws {
        let profile = ServerProfile(
            name: "gpodder.net Account",
            baseUrl: "https://gpodder.net",
            username: "testuser",
            deviceId: "yourpods-ios",
            profileType: .gpodderNet
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(decoded.profileType, .gpodderNet,
                       ".gpodderNet must survive encode/decode round-trip")
    }

    // MARK: - GPodderClient URL Construction

    /// gpodder.net flavor must use `/api/2/subscriptions/{user}/{device}.json`
    /// for subscription pull, NOT the Nextcloud path.
    func test_gpodderNetFlavor_usesV2SubscriptionPaths() async throws {
        let recorder = RequestRecorder.install()
        defer { RequestRecorder.uninstall() }
        
        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        // Attempt to pull subscriptions — will fail but we check the URL
        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 100)
        } catch {
            // Expected — no real server
        }

        // Verify the URL used v2 path format (may have auth requests before it)
        let matchingUrl = recorder.allRequestedURLs.first(where: {
            $0.contains("/api/2/subscriptions/testuser/yourpods-ios.json")
        })
        XCTAssertNotNil(matchingUrl,
                       "gpodder.net flavor must use /api/2/subscriptions/{user}/{device}.json. All URLs: \(recorder.allRequestedURLs)")
        XCTAssertFalse(matchingUrl!.contains("/index.php/apps/gpoddersync"),
                       "gpodder.net flavor must NOT use Nextcloud paths")
    }

    /// gpodder.net flavor must use `/api/2/episodes/{user}.json`
    /// for episode action pull, NOT the Nextcloud path.
    func test_gpodderNetFlavor_usesV2EpisodeActionPaths() async throws {
        let recorder = RequestRecorder.install()
        defer { RequestRecorder.uninstall() }
        
        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getEpisodeActions(since: 100)
        } catch {
            // Expected
        }

        let matchingUrl = recorder.allRequestedURLs.first(where: {
            $0.contains("/api/2/episodes/testuser.json")
        })
        XCTAssertNotNil(matchingUrl,
                       "gpodder.net flavor must use /api/2/episodes/{user}.json. All URLs: \(recorder.allRequestedURLs)")
    }

    /// Nextcloud flavor must still use the existing paths — regression safety net.
    func test_nextcloudFlavor_usesNCPaths_unchanged() async throws {
        let recorder = RequestRecorder.install()
        defer { RequestRecorder.uninstall() }
        
        let client = GPodderClient(
            baseUrl: "https://cloud.example.com",
            username: "admin",
            password: "pass",
            flavor: .nextcloud,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {
            // Expected
        }

        let matchingUrl = recorder.allRequestedURLs.first(where: {
            $0.contains("/index.php/apps/gpoddersync/subscriptions")
        })
        XCTAssertNotNil(matchingUrl,
                       "Nextcloud flavor must still use NC paths. All URLs: \(recorder.allRequestedURLs)")
    }

    /// gpodder.net subscription push should use POST with add/remove delta body
    /// to `/api/2/subscriptions/{user}/{device}.json`.
    func test_gpodderNetFlavor_subscriptionPush_usesV2Path() async throws {
        let recorder = RequestRecorder.install()
        defer { RequestRecorder.uninstall() }
        
        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.updateSubscriptions(
                deviceId: "yourpods-ios",
                add: ["https://example.com/feed.rss"],
                remove: []
            )
        } catch {
            // Expected
        }

        let matchingUrl = recorder.allRequestedURLs.first(where: {
            $0.contains("/api/2/subscriptions/testuser/yourpods-ios.json")
        })
        XCTAssertNotNil(matchingUrl,
                       "Subscription push must use v2 path for gpodder.net. All URLs: \(recorder.allRequestedURLs)")
    }

    /// gpodder.net episode action upload should use POST to
    /// `/api/2/episodes/{user}.json`.
    func test_gpodderNetFlavor_episodeActionUpload_usesV2Path() async throws {
        let recorder = RequestRecorder.install()
        defer { RequestRecorder.uninstall() }
        
        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-1",
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 120,
            started: 0,
            total: 3600,
            device: "yourpods-ios"
        )

        do {
            _ = try await client.uploadEpisodeActions([action])
        } catch {
            // Expected
        }

        let matchingUrl = recorder.allRequestedURLs.first(where: {
            $0.contains("/api/2/episodes/testuser.json")
        })
        XCTAssertNotNil(matchingUrl,
                       "Episode action upload must use v2 path for gpodder.net. All URLs: \(recorder.allRequestedURLs)")
    }
}

// MARK: - RequestRecorder

/// Thread-safe request URL recorder using URLProtocol.
/// Captures all requested URLs for assertion.
final class RequestRecorder {
    /// All URLs that were requested through this recorder's session.
    private(set) var allRequestedURLs: [String] = []
    let session: URLSession
    
    private init(session: URLSession) {
        self.session = session
    }
    
    /// Install the recorder and return the instance. Caller must call `uninstall()` when done.
    static func install() -> RequestRecorder {
        RecordingProtocol.recorder = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        let session = URLSession(configuration: config)
        let recorder = RequestRecorder(session: session)
        RecordingProtocol.recorder = recorder
        return recorder
    }
    
    /// Remove the recorder reference.
    static func uninstall() {
        RecordingProtocol.recorder = nil
    }
    
    fileprivate func record(_ url: String) {
        allRequestedURLs.append(url)
    }
}

/// URLProtocol that captures request URLs and returns mock 200 responses.
/// Returns appropriate mock responses to allow ensureAuthenticated() to complete.
final class RecordingProtocol: URLProtocol {
    /// Shared recorder instance — set before creating the URLSession.
    nonisolated(unsafe) static var recorder: RequestRecorder?
    
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    
    override func startLoading() {
        if let url = request.url?.absoluteString {
            Self.recorder?.record(url)
        }
        
        let urlString = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        
        // Return appropriate mock responses
        let (data, statusCode, headers) = Self.mockResponse(for: urlString, method: method)
        
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() {}
    
    private static func mockResponse(for url: String, method: String) -> (Data, Int, [String: String]?) {
        // Login — return 200 with session cookie
        if url.contains("/auth/") && url.contains("/login.json") {
            return (Data("{}".utf8), 200, ["Set-Cookie": "sessionid=mock; Path=/"])
        }
        // Device registration — return 200
        if url.contains("/devices/") && method == "POST" {
            return (Data("".utf8), 200, nil)
        }
        // Subscriptions
        if url.contains("/subscriptions/") && method == "GET" {
            return (Data(#"{"add":[],"remove":[],"timestamp":0}"#.utf8), 200, nil)
        }
        if url.contains("/subscriptions/") && method == "POST" {
            return (Data(#"{"timestamp":1234,"update_urls":[]}"#.utf8), 200, nil)
        }
        // Episode actions
        if url.contains("/episodes/") && method == "GET" {
            return (Data(#"{"actions":[],"timestamp":0}"#.utf8), 200, nil)
        }
        if url.contains("/episodes/") && method == "POST" {
            return (Data(#"{"timestamp":1234,"update_urls":[]}"#.utf8), 200, nil)
        }
        // Nextcloud
        if url.contains("/gpoddersync/subscriptions") {
            return (Data(#"{"add":[],"remove":[],"timestamp":0}"#.utf8), 200, nil)
        }
        if url.contains("/gpoddersync/episode_action") && method == "GET" {
            return (Data("[]".utf8), 200, nil)
        }
        if url.contains("/gpoddersync/") {
            return (Data(#"{"timestamp":1234,"update_urls":[]}"#.utf8), 200, nil)
        }
        // Default
        return (Data("{}".utf8), 200, nil)
    }
}

// MARK: - From GPodderNetAuthBugTests.swift

/// Regression tests for gpodder.net authentication and connection bugs.
///
/// Bug report: Users with gpodder.net accounts receive 404 errors during sign-in.
///
/// Root causes identified and fixed:
///   1. `login()` was never called — gpodder.net session auth was not established
///   2. Device was never registered — gpodder.net returns 404 for unknown deviceId
///   3. Username/deviceId were not URL-encoded — special chars broke URL construction
///   4. `ensureAuthenticated()` now runs login + device registration once per session
final class GPodderNetAuthBugTests: XCTestCase {

    // MARK: - Bug 1: ensureAuthenticated calls login() for gpodder.net

    /// gpodder.net flavor must call login() via ensureAuthenticated() before
    /// the first API request. Without this, session auth is never established.
    func test_gpodderNetFlavor_callsLoginBeforeFirstRequest() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        // Attempt a subscription pull — should trigger ensureAuthenticated first
        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {
            // Expected — mock server returns minimal responses
        }

        // Verify login was attempted BEFORE the subscription request
        let urls = recorder.requestedURLs
        XCTAssertGreaterThanOrEqual(urls.count, 2,
            "Should have made at least 2 requests (login + device reg or subscription). Got \(urls.count): \(urls)")
        XCTAssertTrue(urls[0].contains("/api/2/auth/testuser/login.json"),
            "First request must be the login endpoint, got: \(urls[0])")
    }

    /// Nextcloud flavor must NOT call login() — it doesn't support session auth.
    func test_nextcloudFlavor_doesNotCallLogin() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://cloud.example.com",
            username: "admin",
            password: "pass",
            flavor: .nextcloud,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {
            // Expected
        }

        // Verify no login attempt was made
        let urls = recorder.requestedURLs
        XCTAssertFalse(urls.contains(where: { $0.contains("/login.json") }),
            "Nextcloud flavor must NOT attempt session auth login. Requests: \(urls)")
    }

    /// After ensureAuthenticated completes, login should NOT be called again
    /// on subsequent API calls (idempotent).
    func test_gpodderNetFlavor_loginCalledOnlyOnce() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        // Make two API calls
        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {}
        do {
            _ = try await client.getEpisodeActions(since: 0)
        } catch {}

        // Login should only be called once (not before every request)
        let loginUrls = recorder.requestedURLs.filter { $0.contains("/login.json") }
        XCTAssertEqual(loginUrls.count, 1,
            "Login should be called exactly once, not before every request. Got \(loginUrls.count)")
    }

    // MARK: - Bug 2: Device not registered

    /// gpodder.net flavor must attempt device registration during
    /// ensureAuthenticated() so that subscription endpoints don't 404.
    func test_gpodderNetFlavor_registersDeviceDuringAuth() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        // Trigger auth flow
        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {}

        // Verify device registration was attempted
        let urls = recorder.requestedURLs
        let deviceRegUrl = urls.first(where: {
            $0.contains("/api/2/devices/testuser/yourpods-ios.json")
        })
        XCTAssertNotNil(deviceRegUrl,
            "gpodder.net flavor must register the device during auth setup. Requests: \(urls)")
    }

    /// The request order must be: login → device registration → actual API call.
    func test_gpodderNetFlavor_correctRequestOrder() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {}

        let urls = recorder.requestedURLs
        XCTAssertGreaterThanOrEqual(urls.count, 3,
            "Expected at least 3 requests: login, device reg, subscription pull. Got \(urls.count): \(urls)")

        // 1. Login
        XCTAssertTrue(urls[0].contains("/auth/testuser/login.json"),
            "Request #1 must be login. Got: \(urls[0])")
        // 2. Device registration
        XCTAssertTrue(urls[1].contains("/devices/testuser/yourpods-ios.json"),
            "Request #2 must be device registration. Got: \(urls[1])")
        // 3. Actual subscription request
        XCTAssertTrue(urls[2].contains("/subscriptions/testuser/yourpods-ios.json"),
            "Request #3 must be subscription pull. Got: \(urls[2])")
    }

    /// Nextcloud flavor must NOT attempt device registration.
    func test_nextcloudFlavor_doesNotRegisterDevice() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://cloud.example.com",
            username: "admin",
            password: "pass",
            flavor: .nextcloud,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {}

        let urls = recorder.requestedURLs
        XCTAssertFalse(urls.contains(where: { $0.contains("/devices/") }),
            "Nextcloud flavor must NOT attempt device registration. Requests: \(urls)")
    }

    // MARK: - Bug 3: URL encoding

    /// Username with special characters must be properly URL-encoded in the path.
    func test_gpodderNetFlavor_urlEncodesUsernameInPath() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "user with spaces",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "mydevice", since: 0)
        } catch {}

        // Check that ALL URLs with the username have encoded spaces
        let urlsWithUsername = recorder.requestedURLs.filter {
            $0.contains("user") && !$0.contains("User-Agent")
        }
        for url in urlsWithUsername {
            XCTAssertFalse(url.contains("user with spaces"),
                "URL must not contain unencoded spaces in username: \(url)")
            XCTAssertTrue(url.contains("user%20with%20spaces"),
                "Username must be percent-encoded in path: \(url)")
        }
    }

    /// DeviceId with special characters must be URL-encoded.
    func test_gpodderNetFlavor_urlEncodesDeviceIdInPath() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "my iPhone", since: 0)
        } catch {}

        let subscriptionUrls = recorder.requestedURLs.filter { $0.contains("/subscriptions/") }
        XCTAssertFalse(subscriptionUrls.isEmpty, "Should have made a subscription request")
        for url in subscriptionUrls {
            XCTAssertFalse(url.contains("my iPhone"),
                "DeviceId must not contain unencoded spaces: \(url)")
            XCTAssertTrue(url.contains("my%20iPhone"),
                "DeviceId spaces must be percent-encoded in path: \(url)")
        }
    }

    // MARK: - Episode action sync

    /// Episode actions must also trigger ensureAuthenticated for gpodder.net.
    func test_gpodderNetFlavor_ensureAuthBeforeEpisodeActions() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getEpisodeActions(since: 0)
        } catch {}

        let urls = recorder.requestedURLs
        // First request should be login, not the episode action fetch
        XCTAssertGreaterThanOrEqual(urls.count, 2,
            "Should have login + at least one API call. Got: \(urls)")
        XCTAssertTrue(urls[0].contains("/login.json"),
            "First request must be login for gpodder.net. Got: \(urls[0])")
    }

    /// Episode action upload must also trigger ensureAuthenticated.
    func test_gpodderNetFlavor_ensureAuthBeforeUploadEpisodeActions() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        let action = EpisodeAction(
            podcast: "https://example.com/feed.rss",
            episode: "https://example.com/ep1.mp3",
            guid: nil,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 120,
            started: 0,
            total: 600,
            device: "yourpods-ios"
        )

        do {
            _ = try await client.uploadEpisodeActions([action])
        } catch {}

        let urls = recorder.requestedURLs
        XCTAssertTrue(urls[0].contains("/login.json"),
            "First request must be login. Got: \(urls[0])")
    }

    // MARK: - Subscription upload

    /// Subscription upload must also trigger ensureAuthenticated.
    func test_gpodderNetFlavor_ensureAuthBeforeSubscriptionUpload() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://gpodder.net",
            username: "testuser",
            password: "testpass",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.updateSubscriptions(
                deviceId: "yourpods-ios",
                add: ["https://example.com/feed.rss"],
                remove: []
            )
        } catch {}

        let urls = recorder.requestedURLs
        XCTAssertTrue(urls[0].contains("/login.json"),
            "First request must be login. Got: \(urls[0])")
    }
}

// MARK: - GPodderRequestRecorder

/// URLProtocol-based recorder that captures ALL requested URLs in order.
/// Returns valid mock responses so ensureAuthenticated() can progress through
/// login → device registration → actual API call.
final class GPodderRequestRecorder: @unchecked Sendable {
    private(set) var requestedURLs: [String] = []
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GPodderMockProtocol.self]
        self.session = URLSession(configuration: config)
        GPodderMockProtocol.recorder = self
    }

    /// Call after each test to safely clean up.
    func tearDown() {
        session.invalidateAndCancel()
        GPodderMockProtocol.recorder = nil
    }

    fileprivate func record(_ url: String) {
        requestedURLs.append(url)
    }
}

/// URLProtocol that captures request URLs and returns appropriate mock responses
/// based on the endpoint being hit.
final class GPodderMockProtocol: URLProtocol {
    // Use nonisolated(unsafe) to silence concurrency warnings — test-only code,
    // each test has its own URLSession configuration, no actual races.
    nonisolated(unsafe) static var recorder: GPodderRequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.recorder?.record(urlString)

        // Return appropriate mock responses based on the endpoint
        let (data, statusCode) = Self.mockResponse(for: urlString, method: request.httpMethod ?? "GET")

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: urlString.contains("/login.json")
                ? ["Set-Cookie": "sessionid=mock_session_id; Path=/"]
                : nil
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Generate appropriate mock responses for each gpodder.net endpoint.
    private static func mockResponse(for url: String, method: String) -> (Data, Int) {
        // Login endpoint — return 200 with session cookie
        if url.contains("/auth/") && url.contains("/login.json") {
            return (Data("{}".utf8), 200)
        }

        // Device registration — return 200
        if url.contains("/devices/") && method == "POST" {
            return (Data("".utf8), 200)
        }

        // Device list — return empty array
        if url.contains("/devices/") && method == "GET" {
            return (Data("[]".utf8), 200)
        }

        // Subscription changes — return empty delta
        if url.contains("/subscriptions/") && method == "GET" {
            let json = #"{"add":[],"remove":[],"timestamp":0}"#
            return (Data(json.utf8), 200)
        }

        // Subscription upload — return timestamp + empty update_urls
        if url.contains("/subscriptions/") && method == "POST" {
            let json = #"{"timestamp":1234,"update_urls":[]}"#
            return (Data(json.utf8), 200)
        }

        // Episode actions GET — return empty actions
        if url.contains("/episodes/") && method == "GET" {
            let json = #"{"actions":[],"timestamp":0}"#
            return (Data(json.utf8), 200)
        }

        // Episode actions POST — return timestamp
        if url.contains("/episodes/") && method == "POST" {
            let json = #"{"timestamp":1234,"update_urls":[]}"#
            return (Data(json.utf8), 200)
        }

        // Nextcloud endpoints
        if url.contains("/gpoddersync/subscriptions") {
            let json = #"{"add":[],"remove":[],"timestamp":0}"#
            return (Data(json.utf8), 200)
        }
        if url.contains("/gpoddersync/episode_action") && method == "GET" {
            return (Data("[]".utf8), 200)
        }
        if url.contains("/gpoddersync/subscription_change") {
            let json = #"{"timestamp":1234,"update_urls":[]}"#
            return (Data(json.utf8), 200)
        }
        if url.contains("/gpoddersync/episode_action/create") {
            let json = #"{"timestamp":1234,"update_urls":[]}"#
            return (Data(json.utf8), 200)
        }

        // Default — 200 with empty body
        return (Data("{}".utf8), 200)
    }
}

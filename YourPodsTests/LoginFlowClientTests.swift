/// Nextcloud Login Flow v2 Client Tests
///
/// Tests the HTTP protocol layer (initiate + poll) using URLProtocol mocks.
/// Also tests AuthMethod migration safety on ServerProfile.
import XCTest
@testable import YourPods

// MARK: - LoginFlowClient Tests

final class LoginFlowClientTests: XCTestCase {

    // MARK: - Initiate

    /// Initiate should POST to /index.php/login/v2 with correct headers.
    func test_initiate_sendsCorrectPOST() async throws {
        let recorder = LoginFlowRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        _ = try await client.initiate(serverURL: "https://cloud.example.com")

        let urls = recorder.requestedURLs
        XCTAssertEqual(urls.count, 1, "Should make exactly one request")
        XCTAssertEqual(urls[0], "https://cloud.example.com/index.php/login/v2")

        let request = recorder.allRequests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "YourPods/1.0 (iOS)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OCS-APIREQUEST"), "true")
    }

    /// Initiate should parse a valid server response into LoginFlowSession.
    func test_initiate_parsesValidResponse() async throws {
        let recorder = LoginFlowRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        let session = try await client.initiate(serverURL: "https://cloud.example.com")

        XCTAssertEqual(session.pollToken, "mock-token-123")
        XCTAssertEqual(session.pollEndpoint.absoluteString, "https://cloud.example.com/login/v2/poll")
        XCTAssertEqual(session.loginURL.absoluteString, "https://cloud.example.com/index.php/login/v2/grant?token=mock-token-123")
    }

    /// Initiate should throw .serverRejected on non-200 response.
    func test_initiate_throwsOnNon200() async throws {
        let recorder = LoginFlowRecorder(initiateStatusCode: 404)
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        do {
            _ = try await client.initiate(serverURL: "https://cloud.example.com")
            XCTFail("Should have thrown LoginFlowError.serverRejected")
        } catch let error as LoginFlowError {
            XCTAssertEqual(error, .serverRejected)
        }
    }

    /// Initiate should throw .invalidURL for garbage input.
    func test_initiate_throwsOnInvalidURL() async throws {
        let recorder = LoginFlowRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        do {
            _ = try await client.initiate(serverURL: "")
            XCTFail("Should have thrown LoginFlowError.invalidURL")
        } catch let error as LoginFlowError {
            XCTAssertEqual(error, .invalidURL)
        }
    }

    // MARK: - Poll

    /// Poll should return credentials immediately on 200 response.
    func test_poll_returnsCredentialsOn200() async throws {
        let recorder = LoginFlowRecorder(pollMode: .immediateSuccess)
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        let session = LoginFlowClient.LoginFlowSession(
            pollToken: "test-token",
            pollEndpoint: URL(string: "https://cloud.example.com/login/v2/poll")!,
            loginURL: URL(string: "https://cloud.example.com/login")!
        )

        let result = try await client.poll(session: session)

        XCTAssertEqual(result.server, "https://cloud.example.com")
        XCTAssertEqual(result.loginName, "john")
        XCTAssertEqual(result.appPassword, "Abc12-Def34-Ghi56-Jkl78")
    }

    /// Poll should normalize trailing slashes from the server field.
    func test_poll_normalizesTrailingSlash() async throws {
        let recorder = LoginFlowRecorder(pollMode: .immediateSuccessWithTrailingSlash)
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        let session = LoginFlowClient.LoginFlowSession(
            pollToken: "test-token",
            pollEndpoint: URL(string: "https://cloud.example.com/login/v2/poll")!,
            loginURL: URL(string: "https://cloud.example.com/login")!
        )

        let result = try await client.poll(session: session)

        XCTAssertEqual(result.server, "https://cloud.example.com",
            "Trailing slash should be stripped from server field")
        XCTAssertFalse(result.server.hasSuffix("/"),
            "Server field must not end with a slash")
    }

    /// Poll should send correct POST with form-encoded token.
    func test_poll_sendsCorrectPOST() async throws {
        let recorder = LoginFlowRecorder(pollMode: .immediateSuccess)
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        let session = LoginFlowClient.LoginFlowSession(
            pollToken: "test-token",
            pollEndpoint: URL(string: "https://cloud.example.com/login/v2/poll")!,
            loginURL: URL(string: "https://cloud.example.com/login")!
        )

        _ = try await client.poll(session: session)

        let request = recorder.allRequests.first(where: {
            $0.url?.absoluteString.contains("/login/v2/poll") == true
        })
        XCTAssertNotNil(request, "Should have made a poll request")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        // URLProtocol consumes httpBody; check the body via the recorder instead
        let body = recorder.allBodies.first(where: {
            $0.key.contains("/login/v2/poll")
        })?.value
        XCTAssertEqual(body, "token=test-token")
    }

    /// Poll should respect Task cancellation.
    func test_poll_respectsCancellation() async throws {
        let recorder = LoginFlowRecorder(pollMode: .alwaysNotReady)
        addTeardownBlock { recorder.tearDown() }

        let client = LoginFlowClient(session: recorder.session)
        let session = LoginFlowClient.LoginFlowSession(
            pollToken: "test-token",
            pollEndpoint: URL(string: "https://cloud.example.com/login/v2/poll")!,
            loginURL: URL(string: "https://cloud.example.com/login")!
        )

        let task = Task {
            try await client.poll(session: session)
        }

        // Give the poll loop a moment to start
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }
}

// MARK: - AuthMethod Tests

final class AuthMethodTests: XCTestCase {

    /// New profiles without authMethod should default to .manual via resolvedAuthMethod.
    func test_authMethod_defaultsToManual() {
        let profile = ServerProfile(
            name: "Test",
            baseUrl: "https://cloud.example.com",
            username: "admin"
        )
        XCTAssertNil(profile.storedAuthMethod)
        XCTAssertEqual(profile.resolvedAuthMethod, .manual)
    }

    /// AuthMethod.loginFlow should survive encode/decode round-trip.
    func test_authMethod_loginFlow_codableRoundTrip() throws {
        let profile = ServerProfile(
            name: "NC Login Flow",
            baseUrl: "https://cloud.example.com",
            username: "john",
            authMethod: .loginFlow
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(decoded.storedAuthMethod, .loginFlow)
        XCTAssertEqual(decoded.resolvedAuthMethod, .loginFlow)
    }

    /// Profiles encoded WITHOUT storedAuthMethod should decode as nil → .manual.
    func test_authMethod_nilFallback_forOldProfiles() throws {
        // Simulate an old profile JSON without storedAuthMethod
        let json = """
        {
            "id": "old-profile-id",
            "name": "Old NC Profile",
            "baseUrl": "https://cloud.example.com",
            "username": "admin",
            "deviceId": "yourpods-ios",
            "profileType": "gpodder"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ServerProfile.self, from: json)
        XCTAssertNil(decoded.storedAuthMethod,
            "Old profiles must decode storedAuthMethod as nil")
        XCTAssertEqual(decoded.resolvedAuthMethod, .manual,
            "resolvedAuthMethod must fall back to .manual for nil")
    }

    /// AuthMethod enum raw values must be stable for persistence.
    func test_authMethod_rawValues() {
        XCTAssertEqual(AuthMethod.manual.rawValue, "manual")
        XCTAssertEqual(AuthMethod.loginFlow.rawValue, "loginFlow")
    }
}

// MARK: - LoginFlowRecorder

/// URLProtocol-based mock for LoginFlowClient tests.
final class LoginFlowRecorder: @unchecked Sendable {
    enum PollMode {
        case immediateSuccess
        case immediateSuccessWithTrailingSlash
        case alwaysNotReady
    }

    private(set) var requestedURLs: [String] = []
    private(set) var allRequests: [URLRequest] = []
    private(set) var allBodies: [(key: String, value: String)] = []
    let session: URLSession

    init(initiateStatusCode: Int = 200, pollMode: PollMode = .immediateSuccess) {
        LoginFlowMockProtocol.initiateStatusCode = initiateStatusCode
        LoginFlowMockProtocol.pollMode = pollMode
        LoginFlowMockProtocol.recorder = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoginFlowMockProtocol.self]
        self.session = URLSession(configuration: config)
        LoginFlowMockProtocol.recorder = self
    }

    func tearDown() {
        session.invalidateAndCancel()
        LoginFlowMockProtocol.recorder = nil
    }

    fileprivate func record(url: String, request: URLRequest, body: String?) {
        requestedURLs.append(url)
        allRequests.append(request)
        if let body {
            allBodies.append((key: url, value: body))
        }
    }
}

/// URLProtocol that returns Login Flow v2 mock responses.
final class LoginFlowMockProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder: LoginFlowRecorder?
    nonisolated(unsafe) static var initiateStatusCode: Int = 200
    nonisolated(unsafe) static var pollMode: LoginFlowRecorder.PollMode = .immediateSuccess

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""

        // Read body from httpBodyStream (httpBody is nil inside URLProtocol)
        var bodyString: String?
        if let stream = request.httpBodyStream {
            stream.open()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate(); stream.close() }
            var data = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 { data.append(buffer, count: read) }
                else { break }
            }
            bodyString = String(data: data, encoding: .utf8)
        } else if let httpBody = request.httpBody {
            bodyString = String(data: httpBody, encoding: .utf8)
        }

        Self.recorder?.record(url: urlString, request: request, body: bodyString)

        let (data, statusCode) = Self.mockResponse(for: urlString)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func mockResponse(for url: String) -> (Data, Int) {
        // Initiate endpoint
        if url.contains("/index.php/login/v2") && !url.contains("/poll") && !url.contains("/grant") {
            let json = """
            {
                "poll": {
                    "token": "mock-token-123",
                    "endpoint": "https://cloud.example.com/login/v2/poll"
                },
                "login": "https://cloud.example.com/index.php/login/v2/grant?token=mock-token-123"
            }
            """
            return (Data(json.utf8), initiateStatusCode)
        }

        // Poll endpoint
        if url.contains("/login/v2/poll") {
            switch pollMode {
            case .immediateSuccess:
                let json = """
                {
                    "server": "https://cloud.example.com",
                    "loginName": "john",
                    "appPassword": "Abc12-Def34-Ghi56-Jkl78"
                }
                """
                return (Data(json.utf8), 200)
            case .immediateSuccessWithTrailingSlash:
                let json = """
                {
                    "server": "https://cloud.example.com/",
                    "loginName": "john",
                    "appPassword": "Abc12-Def34-Ghi56-Jkl78"
                }
                """
                return (Data(json.utf8), 200)
            case .alwaysNotReady:
                return (Data("{}".utf8), 404)
            }
        }

        return (Data("{}".utf8), 200)
    }
}

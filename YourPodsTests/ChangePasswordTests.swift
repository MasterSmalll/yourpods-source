import XCTest
@testable import YourPods

/// Tests for the in-app password change feature.
///
/// `YourPodsProClient.changePassword(currentPassword:newPassword:)` calls
/// `POST /account/change-password`. The server verifies the current password
/// and returns mapped HTTP status codes:
///   200 → success, 400 → validation, 403 → wrong password, 401 → expired.
@MainActor
final class ChangePasswordTests: XCTestCase {

    // MARK: - Mock URLProtocol for HTTP-level testing

    /// Intercepts URLSession requests and returns preconfigured responses.
    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let (data, response) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// A mock `AuthProvider` that returns a fixed token without hitting Firebase.
    private final class StubAuthProvider: AuthProvider, @unchecked Sendable {
        var isAuthenticated: Bool { true }
        var currentUserEmail: String? { "test@example.com" }
        func signIn(email: String, password: String) async throws -> String { "stub-token" }
        func createUser(email: String, password: String) async throws -> String { "stub-token" }
        func getValidToken() async throws -> String { "stub-token" }
        func signOut() async {}
    }

    private var session: URLSession!
    private var client: YourPodsProClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: StubAuthProvider(),
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        session = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// 200 OK — password changed successfully.
    func test_changePassword_success() async throws {
        MockURLProtocol.handler = { request in
            // Verify request structure
            XCTAssertEqual(request.url?.path, "/account/change-password")
            XCTAssertEqual(request.httpMethod, "POST")

            // Verify body contains both passwords
            if let body = request.httpBody ?? request.httpBodyStream.flatMap({ stream in
                stream.open()
                let data = Data(reading: stream)
                stream.close()
                return data
            }) {
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(json?["current_password"] as? String, "oldPass123")
                XCTAssertEqual(json?["new_password"] as? String, "newPass456")
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let data = #"{"message":"password updated"}"#.data(using: .utf8)!
            return (data, response)
        }

        // Should not throw
        try await client.changePassword(currentPassword: "oldPass123", newPassword: "newPass456")
    }

    /// 403 Forbidden — wrong current password.
    func test_changePassword_wrongCurrentPassword_throws403() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 403,
                httpVersion: nil, headerFields: nil
            )!
            let data = #"{"error":"current password is incorrect"}"#.data(using: .utf8)!
            return (data, response)
        }

        do {
            try await client.changePassword(currentPassword: "wrongPass", newPassword: "newPass456")
            XCTFail("Should have thrown for 403")
        } catch let error as YourPodsProError {
            XCTAssertEqual(error, .forbidden,
                           "403 should map to .forbidden — wrong current password")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// 400 Bad Request — password too short.
    func test_changePassword_passwordTooShort_throws400() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400,
                httpVersion: nil, headerFields: nil
            )!
            let data = #"{"error":"password must be at least 6 characters"}"#.data(using: .utf8)!
            return (data, response)
        }

        do {
            try await client.changePassword(currentPassword: "oldPass123", newPassword: "ab")
            XCTFail("Should have thrown for 400")
        } catch let error as YourPodsProError {
            XCTAssertEqual(error, .httpError(400),
                           "400 should map to .httpError(400)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// 401 Unauthorized — expired session token.
    func test_changePassword_expiredSession_throws401() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            let data = #"{"error":"invalid or expired token"}"#.data(using: .utf8)!
            return (data, response)
        }

        do {
            try await client.changePassword(currentPassword: "oldPass123", newPassword: "newPass456")
            XCTFail("Should have thrown for 401")
        } catch let error as YourPodsProError {
            XCTAssertEqual(error, .unauthorized,
                           "401 should map to .unauthorized")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// 500 Internal Server Error — server-side failure.
    func test_changePassword_serverError_throws500() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil
            )!
            let data = #"{"error":"failed to update password"}"#.data(using: .utf8)!
            return (data, response)
        }

        do {
            try await client.changePassword(currentPassword: "oldPass123", newPassword: "newPass456")
            XCTFail("Should have thrown for 500")
        } catch let error as YourPodsProError {
            XCTAssertEqual(error, .serverError(500),
                           "500 should map to .serverError(500)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Data helper for reading InputStream

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                self.append(buffer, count: bytesRead)
            } else {
                break
            }
        }
    }
}

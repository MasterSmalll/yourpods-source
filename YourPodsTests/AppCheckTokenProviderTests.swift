import XCTest
@testable import YourPods

final class AppCheckTokenProviderTests: XCTestCase {
    func test_fakeProvider_returnsConfiguredToken() async throws {
        let provider = FakeAppCheckTokenProvider(result: .success("tok-123"))
        let token = try await provider.token(forcingRefresh: false)
        XCTAssertEqual(token, "tok-123")
    }

    func test_fakeProvider_throwsConfiguredError() async {
        let provider = FakeAppCheckTokenProvider(result: .failure(AppCheckTokenError.unavailable))
        do { _ = try await provider.token(forcingRefresh: false); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? AppCheckTokenError, .unavailable) }
    }
}

/// Test double — lives in the test target.
struct FakeAppCheckTokenProvider: AppCheckTokenProviding, Sendable {
    let result: Result<String, Error>
    func token(forcingRefresh: Bool) async throws -> String { try result.get() }
}

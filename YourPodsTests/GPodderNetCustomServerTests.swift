/// GPodder.net Custom Server Tests
///
/// Verifies that `.gpodderNet` flavor works with custom (non-gpodder.net) base URLs.
/// Users who self-host a gpodder.net-compatible server should be able to
/// point their profile at their own instance.
import XCTest
@testable import YourPods

final class GPodderNetCustomServerTests: XCTestCase {

    // MARK: - Custom base URL uses v2 API paths

    /// A `.gpodderNet` client pointed at a custom server must still use
    /// v2 API paths (`/api/2/subscriptions/...`), not Nextcloud paths.
    func test_gpodderNetFlavor_customBaseUrl_usesV2Paths() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://mygpodder.example.com",
            username: "alice",
            password: "secret",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {}

        let subUrl = recorder.requestedURLs.first(where: {
            $0.contains("/api/2/subscriptions/alice/yourpods-ios.json")
        })
        XCTAssertNotNil(subUrl,
            "Custom-server gpodder.net client must use v2 subscription paths. Got: \(recorder.requestedURLs)")
        XCTAssertTrue(subUrl!.hasPrefix("https://mygpodder.example.com"),
            "Request must target the custom base URL, not gpodder.net. Got: \(subUrl!)")
    }

    // MARK: - Custom base URL login endpoint

    /// Session auth login must target the custom server, not hardcoded gpodder.net.
    func test_gpodderNetFlavor_customBaseUrl_loginEndpoint() async throws {
        let recorder = GPodderRequestRecorder()
        addTeardownBlock { recorder.tearDown() }

        let client = GPodderClient(
            baseUrl: "https://mygpodder.example.com",
            username: "alice",
            password: "secret",
            flavor: .gpodderNet,
            session: recorder.session
        )

        do {
            _ = try await client.getSubscriptionChanges(deviceId: "yourpods-ios", since: 0)
        } catch {}

        let loginUrl = recorder.requestedURLs.first(where: {
            $0.contains("/api/2/auth/alice/login.json")
        })
        XCTAssertNotNil(loginUrl,
            "Login must be attempted on custom server. Got: \(recorder.requestedURLs)")
        XCTAssertTrue(loginUrl!.hasPrefix("https://mygpodder.example.com"),
            "Login must target the custom base URL. Got: \(loginUrl!)")
    }

    // MARK: - Codable round-trip with custom URL

    /// A `.gpodderNet` profile with a non-default baseUrl must survive encode/decode.
    func test_gpodderNetProfile_customUrl_codableRoundTrip() throws {
        let profile = ServerProfile(
            name: "My Private gPodder",
            baseUrl: "https://mygpodder.example.com",
            username: "alice",
            deviceId: "yourpods-ios",
            profileType: .gpodderNet
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)

        XCTAssertEqual(decoded.profileType, .gpodderNet,
            "profileType must survive round-trip")
        XCTAssertEqual(decoded.baseUrl, "https://mygpodder.example.com",
            "Custom baseUrl must survive round-trip")
    }
}

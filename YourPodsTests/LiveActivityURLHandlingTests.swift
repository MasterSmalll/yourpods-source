import XCTest
@testable import YourPods

/// Contract tests for `LiveActivityService.handleURL` — the deep-link grammar that
/// both the Home Screen playback widget and the Live Activity / Dynamic Island
/// controls depend on.
///
/// These controls open the app via `Link(destination: yourpods://action/...)`,
/// which routes through `.onOpenURL → handleURL → onAction → AudioManager`.
/// (Interactive `Button(intent:)` controls were tried for true no-launch but
/// can't work here: the audio engine lives in the app process, so from a
/// suspended/killed app iOS runs the intent's widget-extension copy — which
/// can't touch audio — and foregrounds the app anyway. Confirmed on real
/// hardware, so the deep-link path is the working contract.)
///
/// This locks the parsing so the three actions can't silently regress.
final class LiveActivityURLHandlingTests: XCTestCase {

    private var service: LiveActivityService!

    override func setUp() {
        super.setUp()
        service = LiveActivityService.shared
    }

    override func tearDown() {
        service.onAction = nil
        super.tearDown()
    }

    // MARK: - Valid action URLs route to onAction

    func test_handleURL_routesValidActionURLsToOnAction() {
        // Exactly the URLs emitted by the widget and Live Activity controls.
        let cases: [(url: String, expected: String)] = [
            ("yourpods://action/togglePlay", "togglePlay"),
            ("yourpods://action/skipForward", "skipForward"),
            ("yourpods://action/skipBackward", "skipBackward"),
        ]

        for c in cases {
            var received: String?
            service.onAction = { received = $0 }

            service.handleURL(URL(string: c.url)!)

            XCTAssertEqual(received, c.expected, "URL \(c.url) should route to action \(c.expected)")
        }
    }

    // MARK: - EDGE: non-action URLs must not invoke onAction

    func test_handleURL_ignoresNonActionURLs() {
        let sentinel = "<<not-called>>"
        let rejected: [String] = [
            "spotify://action/togglePlay",   // wrong scheme
            "yourpods://share/togglePlay",   // wrong host
            "yourpods://action/",            // empty action (trailing slash only)
            "yourpods://action",             // empty action (no path)
        ]

        for urlString in rejected {
            var received = sentinel
            service.onAction = { received = $0 }

            service.handleURL(URL(string: urlString)!)

            XCTAssertEqual(received, sentinel, "URL \(urlString) should NOT invoke onAction")
        }
    }
}

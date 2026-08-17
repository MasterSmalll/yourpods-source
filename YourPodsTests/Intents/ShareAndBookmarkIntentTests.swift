import XCTest
import AppIntents
@testable import YourPods

@MainActor
final class ShareAndBookmarkIntentTests: XCTestCase {

    private var received: [SiriIntentCommand] = []

    override func setUp() {
        super.setUp()
        received = []
    }

    override func tearDown() {
        SiriIntentBridge.shared.handler = nil
        super.tearDown()
    }

    // MARK: - Timestamp formatting (pure)

    func test_mmss_formatsPerTable() {
        let cases: [(seconds: Int, expected: String)] = [
            (0, "0:00"), (59, "0:59"), (60, "1:00"), (2537, "42:17"),
            (3600, "1:00:00"), (3725, "1:02:05"),
        ]
        for c in cases {
            XCTAssertEqual(TimestampFormatter.mmss(c.seconds), c.expected, "\(c.seconds)s")
        }
    }

    // MARK: - Intents route through the bridge

    func test_bookmarkIntent_sendsNoteText() async throws {
        SiriIntentBridge.shared.handler = { [weak self] c in
            self?.received.append(c); return .success(dialog: "ok")
        }
        let intent = BookmarkMomentIntent()
        intent.note = "great point"
        _ = try await intent.perform()
        XCTAssertEqual(received, [.bookmarkCurrentMoment(note: "great point")])
    }

    func test_getShareLink_returnsURLValue() async throws {
        let url = URL(string: "https://share.yourpods.app/s/abc")!
        SiriIntentBridge.shared.handler = { _ in .url(url, dialog: "Here's your link.") }
        let result = try await GetShareLinkIntent().perform()
        XCTAssertEqual(result.value, url)
    }

    func test_getShareLink_throwsHonestError_whenNothingPlaying() async {
        SiriIntentBridge.shared.handler = { _ in .failure(message: "Nothing is playing right now.") }
        do {
            _ = try await GetShareLinkIntent().perform()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Nothing is playing"))
        }
    }
}

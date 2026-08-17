import XCTest
@testable import YourPods

final class ChapterModelTests: XCTestCase {

    // MARK: - Backward compatibility

    /// EDGE: chaptersJSON persisted before embeddedImageKey/isHidden existed.
    /// Must decode, not throw — otherwise every existing user loses chapters on upgrade.
    func test_decodesLegacyPayload_withoutNewFields() throws {
        let legacy = """
        [{"startTime":0,"title":"Intro","img":"https://e.g/a.jpg","url":null}]
        """.data(using: .utf8)!

        let chapters = try JSONDecoder().decode([Chapter].self, from: legacy)

        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "Intro")
        XCTAssertEqual(chapters[0].img, "https://e.g/a.jpg")
        XCTAssertNil(chapters[0].embeddedImageKey)
        XCTAssertFalse(chapters[0].isHidden)
    }

    func test_decodesLegacyPayload_withOnlyRequiredFields() throws {
        let minimal = """
        [{"startTime":12.5,"title":"Chapter One"}]
        """.data(using: .utf8)!

        let chapters = try JSONDecoder().decode([Chapter].self, from: minimal)

        XCTAssertEqual(chapters[0].startTime, 12.5)
        XCTAssertNil(chapters[0].img)
        XCTAssertNil(chapters[0].embeddedImageKey)
        XCTAssertFalse(chapters[0].isHidden)
    }

    func test_roundTripsNewFields() throws {
        let original = Chapter(startTime: 30, title: "Two", img: nil, url: nil,
                               embeddedImageKey: "chapterart:abc:1", isHidden: true)

        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([Chapter].self, from: data)

        XCTAssertEqual(decoded[0].embeddedImageKey, "chapterart:abc:1")
        XCTAssertTrue(decoded[0].isHidden)
    }

    // MARK: - unhidden()

    func test_unhidden_clearsFlag_preservingEverythingElse() {
        let hidden = Chapter(startTime: 5, title: "T", img: "i", url: "u",
                             embeddedImageKey: "k", isHidden: true)

        let shown = hidden.unhidden()

        XCTAssertFalse(shown.isHidden)
        XCTAssertEqual(shown.startTime, 5)
        XCTAssertEqual(shown.title, "T")
        XCTAssertEqual(shown.img, "i")
        XCTAssertEqual(shown.url, "u")
        XCTAssertEqual(shown.embeddedImageKey, "k")
    }
}

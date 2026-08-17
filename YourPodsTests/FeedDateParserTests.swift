import XCTest
@testable import YourPods

final class FeedDateParserTests: XCTestCase {
    func test_parsesAllRealWorldShapes() {
        let inputs = [
            "Sat, 07 Sep 2002 00:00:01 GMT", "Wed, 02 Oct 2002 08:00:00 EST",
            "Mon, 6 Sep 2010 08:00:00 -0500", "07 Sep 2002 00:00:01 GMT",
            "Sat, 07 Sep 2002 00:00 GMT", "Sat, 07 September 2002 00:00:01 +0000",
            "Tue Sep 07 00:00:01 2002", "2002-09-07T00:00:01Z",
            "2002-09-07T00:00:01+02:00", "2002-09-07T00:00:01.123Z",
            "2002-09-07 00:00:01", "2026-06-12",
        ]
        for input in inputs {
            XCTAssertNotNil(FeedDateParser.parse(input), "should parse: \(input)")
        }
    }
    func test_namedZone_resolvesToCorrectInstant() {
        let est = FeedDateParser.parse("Wed, 02 Oct 2002 08:00:00 EST")
        let utc = FeedDateParser.parse("Wed, 02 Oct 2002 13:00:00 GMT")
        XCTAssertEqual(est, utc, "EST 08:00 == UTC 13:00")
    }
    func test_garbage_returnsNil() { XCTAssertNil(FeedDateParser.parse("not a date")) }
    func test_empty_returnsNil() { XCTAssertNil(FeedDateParser.parse("   ")) }
}

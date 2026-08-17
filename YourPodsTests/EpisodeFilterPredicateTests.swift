import XCTest
@testable import YourPods

final class EpisodeFilterPredicateTests: XCTestCase {

    private func ep(guid: String = "g", pubDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
                    isPlayed: Bool = false, isStale: Bool = false) -> Episode {
        let e = Episode(guid: guid, title: "T", pubDate: pubDate)
        e.isPlayed = isPlayed
        e.isStale = isStale
        return e
    }

    // MARK: isUnplayed (explicit cutoff — pure)

    func test_isUnplayed_true_whenUnplayedNonStale_noCutoff() {
        XCTAssertTrue(EpisodeFilterPredicate.isUnplayed(ep(), markedPlayedBefore: nil))
    }
    func test_isUnplayed_false_whenPlayed() {
        XCTAssertFalse(EpisodeFilterPredicate.isUnplayed(ep(isPlayed: true), markedPlayedBefore: nil))
    }
    func test_isUnplayed_false_whenStale() {
        XCTAssertFalse(EpisodeFilterPredicate.isUnplayed(ep(isStale: true), markedPlayedBefore: nil))
    }
    func test_isUnplayed_false_whenNoPubDate() {
        XCTAssertFalse(EpisodeFilterPredicate.isUnplayed(ep(pubDate: nil), markedPlayedBefore: nil))
    }
    func test_isUnplayed_respectsCutoff() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let older = ep(pubDate: cutoff.addingTimeInterval(-1))
        let newer = ep(pubDate: cutoff.addingTimeInterval(1))
        XCTAssertFalse(EpisodeFilterPredicate.isUnplayed(older, markedPlayedBefore: cutoff),
                       "Episodes at/older than the cutoff are treated as already caught up")
        XCTAssertTrue(EpisodeFilterPredicate.isUnplayed(newer, markedPlayedBefore: cutoff))
    }

    // MARK: isDownloaded / isInProgress (closure-injected — pure)

    func test_isDownloaded_usesClosureAndStaleGuard() {
        let e = ep(guid: "d1")
        XCTAssertTrue(EpisodeFilterPredicate.isDownloaded(e, isDownloaded: { $0 == "d1" }))
        XCTAssertFalse(EpisodeFilterPredicate.isDownloaded(e, isDownloaded: { _ in false }))
        let stale = ep(guid: "d1", isStale: true)
        XCTAssertFalse(EpisodeFilterPredicate.isDownloaded(stale, isDownloaded: { _ in true }),
                       "Stale episodes never count as downloaded")
    }
    func test_isInProgress_usesClosureAndStaleGuard() {
        let e = ep(guid: "p1")
        XCTAssertTrue(EpisodeFilterPredicate.isInProgress(e, hasAction: { $0 == "p1" }))
        XCTAssertFalse(EpisodeFilterPredicate.isInProgress(e, hasAction: { _ in false }))
        let stale = ep(guid: "p1", isStale: true)
        XCTAssertFalse(EpisodeFilterPredicate.isInProgress(stale, hasAction: { _ in true }))
    }
}

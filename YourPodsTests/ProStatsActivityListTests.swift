import XCTest
@testable import YourPods

/// Tests that ProStatsView includes an episode activity list for YourPods Sync/Pro users.
/// The activity list shows played episodes from the local actionMap — the same data
/// gPodder users see in GpodderActivityView.
final class ProStatsActivityListTests: XCTestCase {

    // MARK: - Activity List Enabled

    /// ProStatsView must show an episode activity list.
    func test_activityList_isEnabled() {
        XCTAssertTrue(
            ProStatsView.showsActivityList,
            "ProStatsView must show an episode activity list for YourPods Sync/Pro users"
        )
    }

    // MARK: - Sort Logic Parity with GpodderActivityView

    /// Recent sort: actions sorted newest-first by timestamp.
    func test_sortRecent_returnsNewestFirst() {
        let older = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep1",
            action: "play",
            timestamp: 1000,
            position: 600,
            started: 0,
            total: 3600,
            device: "test"
        )
        let newer = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep2.mp3",
            guid: "ep2",
            action: "play",
            timestamp: 2000,
            position: 300,
            started: 0,
            total: 1800,
            device: "test"
        )

        let actions = [older, newer]
        let sorted = ProStatsView.sortActions(actions, by: .recent)

        XCTAssertEqual(sorted.first?.guid, "ep2",
                       "Recent sort should return newest action first")
        XCTAssertEqual(sorted.last?.guid, "ep1",
                       "Recent sort should return oldest action last")
    }

    /// By-podcast sort: actions sorted by podcast URL then timestamp ascending.
    func test_sortByPodcast_groupsByPodcast() {
        let feedA = EpisodeAction(
            podcast: "https://aaa.com/feed",
            episode: "https://aaa.com/ep1.mp3",
            guid: "a1",
            action: "play",
            timestamp: 2000,
            position: 100,
            started: 0,
            total: 600,
            device: "test"
        )
        let feedB = EpisodeAction(
            podcast: "https://bbb.com/feed",
            episode: "https://bbb.com/ep1.mp3",
            guid: "b1",
            action: "play",
            timestamp: 1000,
            position: 200,
            started: 0,
            total: 900,
            device: "test"
        )

        let actions = [feedB, feedA]
        let sorted = ProStatsView.sortActions(actions, by: .byPodcast)

        XCTAssertEqual(sorted.first?.podcast, "https://aaa.com/feed",
                       "By-podcast sort should group by podcast URL alphabetically")
    }

    /// Empty action list should produce empty sorted result.
    func test_sortEmpty_returnsEmpty() {
        let sorted = ProStatsView.sortActions([], by: .recent)
        XCTAssertTrue(sorted.isEmpty, "Sorting empty actions should return empty array")
    }

    // MARK: - Navigation Title

    /// The navigation title must be "Episode Activity" to match the settings row
    /// and gPodder/Nextcloud behavior.
    func test_navigationTitle_isEpisodeActivity() {
        XCTAssertEqual(
            ProStatsView.navigationTitleText, "Episode Activity",
            "Navigation title must be 'Episode Activity' to match settings row and gPodder behavior"
        )
    }
}

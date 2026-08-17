import XCTest
import AppIntents
@testable import YourPods

@MainActor
final class PlaybackIntentTests: XCTestCase {

    private var received: [SiriIntentCommand] = []

    override func setUp() {
        super.setUp()
        received = []
        SiriIntentBridge.shared.handler = { [weak self] command in
            self?.received.append(command)
            return .success(dialog: "stub")
        }
    }

    override func tearDown() {
        SiriIntentBridge.shared.handler = nil
        super.tearDown()
    }

    // MARK: - Parameterless intents send the right command (table-driven)

    func test_parameterlessIntents_sendExpectedCommand() async throws {
        let cases: [(name: String, run: () async throws -> Void, expected: SiriIntentCommand)] = [
            ("PlayQueue",   { _ = try await PlayQueueIntent().perform() },       .playQueue),
            ("Resume",      { _ = try await ResumePlaybackIntent().perform() },  .playQueue),
            ("Pause",       { _ = try await PausePodcastIntent().perform() },    .pause),
            ("Stop",        { _ = try await StopPlaybackIntent().perform() },    .stop),
            ("SkipFwd",     { _ = try await SkipForwardIntent().perform() },     .skipForward),
            ("SkipBack",    { _ = try await SkipBackwardIntent().perform() },    .skipBackward),
            ("Next",        { _ = try await SkipToNextIntent().perform() },      .nextEpisode),
            ("CancelTimer", { _ = try await CancelSleepTimerIntent().perform() }, .cancelSleepTimer),
            ("WhatsPlaying", { _ = try await WhatsPlayingIntent().perform() },   .getCurrentEpisode),
        ]
        for c in cases {
            received = []
            try await c.run()
            XCTAssertEqual(received, [c.expected], c.name)
        }
    }

    // MARK: - Parameterized intents

    func test_setSleepTimerIntent_passesMinutes() async throws {
        let intent = SetSleepTimerIntent()
        intent.minutes = 45
        _ = try await intent.perform()
        XCTAssertEqual(received, [.setSleepTimer(minutes: 45)])
    }

    func test_setPlaybackSpeedIntent_passesSpeed() async throws {
        let intent = SetPlaybackSpeedIntent()
        intent.speed = 1.5
        _ = try await intent.perform()
        XCTAssertEqual(received, [.setSpeed(1.5)])
    }

    func test_playPodcastIntent_sendsFeedUrlFromEntity() async throws {
        let snap = PodcastSnapshot(feedUrl: "https://feed/atp", title: "ATP",
                                   author: nil, artworkUrl: nil)
        let intent = PlayPodcastIntent()
        intent.podcast = PodcastEntity(snapshot: snap)
        _ = try await intent.perform()
        XCTAssertEqual(received, [.playPodcast(feedUrl: "https://feed/atp")])
    }

    // MARK: - Configuration guards

    func test_intentsNeverOpenTheApp() {
        XCTAssertFalse(PlayQueueIntent.openAppWhenRun)
        XCTAssertFalse(PausePodcastIntent.openAppWhenRun)
        XCTAssertFalse(WhatsPlayingIntent.openAppWhenRun)
    }

    // MARK: - Phrase-cap guard (Apple limit: 10 App Shortcuts per app)

    func test_appShortcutsProvider_staysWithinAppleCapOfTen() {
        XCTAssertLessThanOrEqual(YourPodsShortcuts.appShortcuts.count, 10,
            "Apple silently drops phrase registration past 10 App Shortcuts — trim the provider.")
    }
}

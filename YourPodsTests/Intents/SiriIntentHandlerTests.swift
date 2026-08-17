import XCTest
@testable import YourPods

@MainActor
final class SiriIntentHandlerTests: XCTestCase {
    private var audio: AudioManager!
    private var player: PlayerManager!
    private var settings: SettingsManager!
    private var sleepTimer: SleepTimerManager!
    private var handler: SiriIntentHandler!

    override func setUp() {
        super.setUp()
        // Clear persisted queue + current item to prevent restoreQueue() from loading stale data
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        UserDefaults.standard.removeObject(forKey: "savedPlaybackEventTime")
        audio = AudioManager()
        player = PlayerManager(audioManager: audio)
        settings = SettingsManager()
        sleepTimer = SleepTimerManager()
        handler = SiriIntentHandler(
            audio: audio, player: player, settings: settings, sleepTimer: sleepTimer,
            podcastManager: nil, downloadManager: nil, navigationState: nil,
            chapterCoordinator: nil)
    }

    // MARK: - Guards fire honest failures when nothing is playing

    func test_returnsNothingPlayingFailure_whenNoCurrentItem() async {
        let commands: [SiriIntentCommand] = [.pause, .skipForward, .skipBackward,
                                             .restartEpisode, .nextChapter, .previousChapter,
                                             .getCurrentEpisode, .bookmarkCurrentMoment(note: nil),
                                             .getShareLink]
        for command in commands {
            let outcome = await handler.handle(command)
            XCTAssertTrue(outcome.isFailure, "\(command) should fail with nothing playing")
            XCTAssertEqual(outcome.spokenDialog, "Nothing is playing right now.", "\(command)")
        }
    }

    func test_nextEpisode_fails_whenQueueEmpty() async {
        let outcome = await handler.handle(.nextEpisode)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog, "Nothing next in your queue.")
    }

    // MARK: - Sleep timer

    func test_setSleepTimer_startsTimer_andClampsMinutes() async {
        let outcome = await handler.handle(.setSleepTimer(minutes: 9999))
        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(sleepTimer.isActive)
        XCTAssertEqual(sleepTimer.selectedMinutes, 480)  // clamp 1...480
    }

    func test_extendSleepTimer_fails_whenNoTimerActive() async {
        let outcome = await handler.handle(.extendSleepTimer(minutes: 10))
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog, "There's no sleep timer running.")
    }

    func test_extendSleepTimer_addsMinutes_whenActive() async {
        sleepTimer.start(minutes: 10)
        let before = sleepTimer.remainingSeconds
        let outcome = await handler.handle(.extendSleepTimer(minutes: 5))
        XCTAssertFalse(outcome.isFailure)
        XCTAssertEqual(sleepTimer.remainingSeconds, before + 5 * 60)
    }

    func test_cancelSleepTimer_stopsTimer() async {
        sleepTimer.start(minutes: 10)
        _ = await handler.handle(.cancelSleepTimer)
        XCTAssertFalse(sleepTimer.isActive)
    }

    // MARK: - Speed

    func test_setSpeed_clampsAndApplies() async {
        _ = await handler.handle(.setSpeed(9.0))
        XCTAssertEqual(audio.playbackRate, 3.0)
        _ = await handler.handle(.setSpeed(0.1))
        XCTAssertEqual(audio.playbackRate, 0.5)
    }

    // MARK: - Open actions

    func test_openQueue_switchesToUpNextTab() async {
        let nav = NavigationState()
        let h = SiriIntentHandler(audio: audio, player: player, settings: settings,
                                  sleepTimer: sleepTimer, podcastManager: nil,
                                  downloadManager: nil, navigationState: nav,
                                  chapterCoordinator: nil)
        nav.selectedTab = 0
        let outcome = await h.handle(.openQueue)
        XCTAssertFalse(outcome.isFailure)
        XCTAssertEqual(nav.selectedTab, 2)
    }

    func test_openPodcast_fails_whenFeedUnknown() async {
        let nav = NavigationState()
        let h = SiriIntentHandler(audio: audio, player: player, settings: settings,
                                  sleepTimer: sleepTimer, podcastManager: nil,
                                  downloadManager: nil, navigationState: nav,
                                  chapterCoordinator: nil)
        let outcome = await h.handle(.openPodcast(feedUrl: "https://nope"))
        XCTAssertTrue(outcome.isFailure)
    }

    // MARK: - Getters

    private func makeItem(id: String, title: String) -> QueueItem {
        // Reuse/adapt the QueueItem factory from SiriIntentBridgeTests — same init caveat.
        QueueItem(id: id, title: title, podcastTitle: "Pod",
                  audioUrl: "https://a/\(id).mp3", artworkUrl: nil,
                  durationSeconds: 100, positionSeconds: 0,
                  podcastUrl: "https://feed", pubDate: nil)
    }

    func test_getQueue_returnsSnapshotsAndCountDialog() async {
        audio.appendToQueue([makeItem(id: "g1", title: "One"), makeItem(id: "g2", title: "Two")])
        let outcome = await handler.handle(.getQueue)
        guard case .episodes(let snaps, let dialog) = outcome else {
            return XCTFail("expected .episodes, got \(outcome)")
        }
        XCTAssertEqual(snaps.map(\.guid), ["g1", "g2"])
        XCTAssertEqual(dialog, "You have 2 episodes in your queue.")
    }

    func test_getQueue_returnsEmptyListWithDialog_whenQueueEmpty() async {
        let outcome = await handler.handle(.getQueue)
        guard case .episodes(let snaps, let dialog) = outcome else {
            return XCTFail("expected .episodes, got \(outcome)")
        }
        XCTAssertTrue(snaps.isEmpty)
        XCTAssertEqual(dialog, "Your queue is empty.")
    }

    func test_whatsNext_speaksFirstQueuedEpisode() async {
        audio.appendToQueue([makeItem(id: "g1", title: "One")])
        let outcome = await handler.handle(.whatsNext)
        guard case .episode(let snap, let dialog) = outcome else {
            return XCTFail("expected .episode, got \(outcome)")
        }
        XCTAssertEqual(snap.guid, "g1")
        XCTAssertEqual(dialog, "Up next is One from Pod.")
    }

    func test_whatsNext_fails_whenQueueEmpty() async {
        let outcome = await handler.handle(.whatsNext)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog, "Nothing next in your queue.")
    }

    func test_getCurrentEpisode_returnsEpisode_whenPlaying() async {
        audio.currentItem = makeItem(id: "g1", title: "One")
        let outcome = await handler.handle(.getCurrentEpisode)
        guard case .episode(let snap, let dialog) = outcome else {
            return XCTFail("expected .episode, got \(outcome)")
        }
        XCTAssertEqual(snap.title, "One")
        XCTAssertEqual(dialog, "Now playing One from Pod.")
    }

    func test_getPodcasts_failsHonestly_whenPodcastManagerMissing() async {
        let outcome = await handler.handle(.getPodcasts)
        XCTAssertTrue(outcome.isFailure)  // handler built with podcastManager: nil in setUp
    }

    // MARK: - Queue & library

    func test_clearQueue_emptiesQueue() async {
        audio.appendToQueue([makeItem(id: "g1", title: "One")])
        let outcome = await handler.handle(.clearQueue)
        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(audio.queue.isEmpty)
        XCTAssertEqual(outcome.spokenDialog, "Queue cleared.")
    }

    func test_markPlayedAndPlayNext_fails_whenNothingPlaying() async {
        let outcome = await handler.handle(.markPlayedAndPlayNext)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog, "Nothing is playing right now.")
    }

    func test_markPlayedAndPlayNext_marksPlayedAndStops_whenQueueEmpty() async {
        audio.currentItem = makeItem(id: "g1", title: "One")
        let outcome = await handler.handle(.markPlayedAndPlayNext)
        XCTAssertFalse(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog, "Marked One as played.")
        XCTAssertNil(audio.currentItem)
    }

    func test_markPlayedAndPlayNext_advancesQueue_whenNextExists() async {
        // skipToNext() promotes audioManager.currentItem asynchronously (unstructured
        // Task), so this deterministically checks the synchronous side effect —
        // the next item popped off the queue — rather than racing currentItem.
        audio.currentItem = makeItem(id: "g1", title: "One")
        audio.appendToQueue([makeItem(id: "g2", title: "Two")])
        let outcome = await handler.handle(.markPlayedAndPlayNext)
        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(audio.queue.isEmpty, "skipToNext should have popped the next item off the queue")
    }

    func test_libraryCommands_failHonestly_whenManagersMissing() async {
        // handler from setUp has podcastManager/downloadManager nil
        for command in [SiriIntentCommand.checkForNewEpisodes, .downloadQueue,
                        .downloadLatest(feedUrl: "f")] {
            let outcome = await handler.handle(command)
            XCTAssertTrue(outcome.isFailure, "\(command)")
        }
    }

    // MARK: - Listening Stats

    func test_getListeningStats_failsHonestly_whenNoCache() async {
        ListeningStatsService.clearCache()
        let outcome = await handler.handle(.getListeningStats)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(outcome.spokenDialog,
                       "Stats aren't ready yet — open Listening Stats in YourPods first.")
    }

    func test_downloadQueue_reportsNothingToDownload_whenQueueEmpty() async {
        // Rebuild handler WITH a real DownloadManager for this case.
        let dl = DownloadManager()
        let h = SiriIntentHandler(audio: audio, player: player, settings: settings,
                                  sleepTimer: sleepTimer, podcastManager: nil,
                                  downloadManager: dl, navigationState: nil,
                                  chapterCoordinator: nil)
        let outcome = await h.handle(.downloadQueue)
        XCTAssertEqual(outcome.spokenDialog, "Your queue is empty.")
    }
}

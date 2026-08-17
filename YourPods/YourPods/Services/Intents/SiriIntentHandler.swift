import Foundation
import OSLog

enum TimestampFormatter {
    /// 2537 → "42:17"; 3725 → "1:02:05".
    static func mmss(_ seconds: Int) -> String {
        DurationFormatting.timestamp(TimeInterval(seconds))
    }
}

/// App-side executor for SiriIntentCommand. Installed on SiriIntentBridge by
/// YourPodsApp at launch. Holds weak manager references (the managers are
/// environment-injected @State instances owned by YourPodsApp, same lifetime
/// as the app — weak avoids retain cycles without practical nil risk).
@MainActor
final class SiriIntentHandler {
    private weak var audio: AudioManager?
    private weak var player: PlayerManager?
    private weak var settings: SettingsManager?
    private weak var sleepTimer: SleepTimerManager?
    private weak var podcastManager: PodcastManager?
    private weak var downloadManager: DownloadManager?
    private weak var navigationState: NavigationState?
    private weak var chapterCoordinator: ChapterCoordinator?

    private let log = Logger(subsystem: "com.yourpods", category: "audio")

    init(audio: AudioManager?, player: PlayerManager?, settings: SettingsManager?,
         sleepTimer: SleepTimerManager?, podcastManager: PodcastManager?,
         downloadManager: DownloadManager?, navigationState: NavigationState?,
         chapterCoordinator: ChapterCoordinator?) {
        self.audio = audio
        self.player = player
        self.settings = settings
        self.sleepTimer = sleepTimer
        self.podcastManager = podcastManager
        self.downloadManager = downloadManager
        self.navigationState = navigationState
        self.chapterCoordinator = chapterCoordinator
    }

    private static let notReady =
        String(localized: "siri.error.notReady",
               defaultValue: "YourPods isn't ready yet. Try again in a moment.",
               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when any Siri request arrives before the app's playback managers exist. No arguments.")
    private static let nothingPlaying =
        String(localized: "siri.error.nothingPlaying",
               defaultValue: "Nothing is playing right now.",
               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to act on the current episode (pause, skip, restart, jump chapter, bookmark, share, 'what's playing') and nothing is playing. No arguments.")

    func handle(_ command: SiriIntentCommand) async -> IntentOutcome {
        log.info("⟦siri-handler⟧ \(command.caseName, privacy: .public)")
        guard let audio, let player, let settings, let sleepTimer else {
            return failure(Self.notReady, logAs: "managers deallocated", command: command, unexpected: true)
        }

        switch command {
        // MARK: Playback
        case .playQueue:
            if audio.isPlaying {
                return .success(dialog: String(localized: "siri.playback.alreadyPlaying",
                                               defaultValue: "Already playing.",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to start playback and audio is already playing. No arguments."))
            }
            await audio.resumePlayback()
            if let item = audio.currentItem {
                return .success(dialog: String(localized: "siri.playback.playing",
                                               defaultValue: "Playing \(item.title).",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when playback starts in response to 'play' or 'skip to the next episode'. Argument 1 is the episode title — user content from the podcast feed, never translated."))
            }
            return failure(String(localized: "siri.queue.empty",
                                  defaultValue: "Your queue is empty.",
                                  comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to play, list or download the queue and it holds no episodes. No arguments."),
                           logAs: "queue empty", command: command)

        case .pause:
            guard audio.currentItem != nil else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            player.pause()
            return .success(dialog: String(localized: "siri.playback.paused",
                                           defaultValue: "Paused.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to pause playback. No arguments."))

        case .stop:
            audio.stop()
            return .success(dialog: String(localized: "siri.playback.stopped",
                                           defaultValue: "Stopped.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to stop playback. No arguments."))

        case .skipForward:
            guard audio.currentItem != nil else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            player.seekRelative(seconds: Double(settings.skipForwardSeconds))
            return .success(dialog: String(localized: "siri.playback.skippedForward",
                                           defaultValue: "Skipped forward.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to skip ahead by the user's configured skip-forward interval. No arguments."))

        case .skipBackward:
            guard audio.currentItem != nil else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            player.seekRelative(seconds: -Double(settings.skipBackwardSeconds))
            return .success(dialog: String(localized: "siri.playback.skippedBack",
                                           defaultValue: "Skipped back.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to skip back by the user's configured skip-back interval. No arguments."))

        case .nextEpisode:
            guard !audio.queue.isEmpty else {
                return failure(String(localized: "siri.queue.nothingNext",
                                      defaultValue: "Nothing next in your queue.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks for the next episode, or what is up next, and the queue is empty. No arguments."),
                               logAs: "queue empty", command: command)
            }
            player.skipToNext()
            let next = audio.currentItem?.title
            return .success(dialog: next.map {
                String(localized: "siri.playback.playing",
                       defaultValue: "Playing \($0).",
                       comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when playback starts in response to 'play' or 'skip to the next episode'. Argument 1 is the episode title — user content from the podcast feed, never translated.")
            } ?? String(localized: "siri.playback.playingNextEpisode",
                        defaultValue: "Playing next episode.",
                        comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when Siri advances to the next queued episode but its title is not known yet. No arguments."))

        case .restartEpisode:
            guard let item = audio.currentItem else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            player.seek(to: 0)
            return .success(dialog: String(localized: "siri.playback.restarting",
                                           defaultValue: "Restarting \(item.title).",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to start the current episode over. Argument 1 is the episode title — user content from the podcast feed, never translated."))

        case .setSpeed(let requested):
            let clamped = min(max(requested, 0.5), 3.0)
            player.setPlaybackRate(clamped)
            // `fractionLength(0...2)`, not `(1)`. One fraction digit rounds
            // 0.75 to "0.8", 1.25 to "1.2" and 1.75 to "1.8" — three of the
            // nine presets — so Siri was speaking a rate the app was not
            // playing while the screen showed the right one. Same defect the
            // on-screen readout was fixed for in B1; the voice path kept it.
            let rate = clamped.formatted(.number.precision(.fractionLength(0...2)))
            return .success(dialog: String(localized: "siri.playback.speedSet",
                                           defaultValue: "Speed set to \(rate)x.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to change the playback speed. Argument 1 is the already-formatted rate, which carries its own locale's decimal separator (1.5 in English, 1,5 in French). The trailing 'x' is the English multiplier abbreviation and is part of this string: the multiplier convention differs by language, so replace it with whatever your language says aloud for 'times'."))

        case .playPodcast(let feedUrl):
            guard let podcastManager else { return failure(Self.notReady, logAs: "podcastManager nil", command: command, unexpected: true) }
            guard let podcast = podcastManager.subscriptions.first(where: { $0.url == feedUrl }) else {
                return failure(String(localized: "siri.library.podcastNotFound",
                                      defaultValue: "That podcast isn't in your library.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user names a podcast to play, download or open and the app is not subscribed to it. No arguments."),
                               logAs: "feed not in library", command: command)
            }
            let latest = podcast.episodes
                .filter { $0.audioUrl != nil }
                .max { ($0.pubDate ?? .distantPast) < ($1.pubDate ?? .distantPast) }
            guard let latest else {
                return failure(String(localized: "siri.playback.noPlayableEpisodes",
                                      defaultValue: "\(podcast.title) has no playable episodes.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to play a subscribed podcast whose feed carries no episode with audio. Argument 1 is the podcast title — user content from the feed, never translated."),
                               logAs: "no playable episodes", command: command)
            }
            player.playEpisode(latest)
            return .success(dialog: String(localized: "siri.playback.playingFromPodcast",
                                           defaultValue: "Playing \(latest.title) from \(podcast.title).",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when Siri starts the newest episode of a podcast the user named. Argument 1 is the episode title and argument 2 the podcast title — both user content from the feed, never translated."))

        // MARK: Chapters
        case .nextChapter, .previousChapter:
            guard audio.currentItem != nil else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            // The currently-playing item is a `ChapterCoordinator`-owned
            // surface (chapter-images plan's "currently-playing item" rule),
            // so read its already-resolved chapters — the same embedded-first
            // list CarPlay chapter-seek and the mini-player chapter button
            // use. Fetching the feed-only chain here (the pre-fix behaviour)
            // answered "This episode doesn't have chapters" for any episode
            // whose chapters are embedded in the audio file and absent from
            // the feed — exactly the shows this feature added support for.
            let chapters = chapterCoordinator?.visibleChapters ?? []
            guard !chapters.isEmpty else {
                return failure(String(localized: "siri.chapters.none",
                                      defaultValue: "This episode doesn't have chapters.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri for the next or previous chapter and the playing episode has none. No arguments."),
                               logAs: "no chapters", command: command)
            }
            let target: Chapter?
            if case .nextChapter = command {
                target = ChapterNavigator.next(in: chapters, after: audio.currentPosition)
            } else {
                target = ChapterNavigator.previous(in: chapters, before: audio.currentPosition,
                                                   restartThreshold: 3)
            }
            if let target {
                player.seek(to: target.startTime)
                return .success(dialog: String(localized: "siri.chapters.jumpingTo",
                                               defaultValue: "Jumping to \(target.title).",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after Siri seeks to the next or previous chapter. Argument 1 is the chapter title — user content from the episode's chapter data, never translated."))
            }
            if case .previousChapter = command {
                player.seek(to: 0)   // before first chapter boundary → start of episode
                return .success(dialog: String(localized: "siri.chapters.backToBeginning",
                                               defaultValue: "Back to the beginning.",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks for the previous chapter while already inside the first one, so playback jumps to the start of the episode. No arguments."))
            }
            return failure(String(localized: "siri.chapters.alreadyLast",
                                  defaultValue: "You're already in the last chapter.",
                                  comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks for the next chapter and the last one is already playing. No arguments."),
                           logAs: "already in last chapter", command: command)

        // MARK: Sleep timer
        case .setSleepTimer(let minutes):
            let clamped = min(max(minutes, 1), 480)
            sleepTimer.start(minutes: clamped)
            return .success(dialog: String(localized: "siri.sleepTimer.set",
                                           defaultValue: "Sleep timer set for \(clamped) minutes.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to start a sleep timer. Argument 1 is the length in minutes, clamped to 1–480. Plural rules live in the catalog."))

        case .cancelSleepTimer:
            guard sleepTimer.isActive else {
                return failure(String(localized: "siri.sleepTimer.notRunning",
                                      defaultValue: "There's no sleep timer running.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to cancel or extend the sleep timer and none is running. No arguments."),
                               logAs: "no active timer", command: command)
            }
            sleepTimer.stop()
            return .success(dialog: String(localized: "siri.sleepTimer.cancelled",
                                           defaultValue: "Sleep timer cancelled.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to cancel a running sleep timer. No arguments."))

        case .extendSleepTimer(let minutes):
            guard sleepTimer.isActive else {
                return failure(String(localized: "siri.sleepTimer.notRunning",
                                      defaultValue: "There's no sleep timer running.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to cancel or extend the sleep timer and none is running. No arguments."),
                               logAs: "no active timer", command: command)
            }
            let clamped = min(max(minutes, 1), 480)
            sleepTimer.extend(minutes: clamped)
            return .success(dialog: String(localized: "siri.sleepTimer.extended",
                                           defaultValue: "Sleep timer extended by \(clamped) minutes.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to add time to a running sleep timer. Argument 1 is how many minutes were added, clamped to 1–480. Plural rules live in the catalog."))

        // MARK: Getters/actions that at least honor the nothing-playing guard
        case .getCurrentEpisode:
            guard let item = audio.currentItem else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            let snap = EpisodeSnapshot(item: item, livePositionSeconds: Int(audio.currentPosition))
            return .episode(snap, dialog: String(localized: "siri.playback.nowPlayingFromPodcast",
                                                 defaultValue: "Now playing \(item.title) from \(item.podcastTitle).",
                                                 comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri what is playing. Argument 1 is the episode title and argument 2 the podcast title — both user content from the feed, never translated."))

        case .bookmarkCurrentMoment(let note):
            guard let item = audio.currentItem else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            guard let podcastManager else { return failure(Self.notReady, logAs: "podcastManager nil", command: command, unexpected: true) }
            let position = audio.currentPosition
            _ = podcastManager.annotationService.createAnnotation(
                episodeUrl: item.audioUrl,
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id,
                timestampSec: position,
                noteText: note ?? "",
                podcastTitle: item.podcastTitle,
                episodeTitle: item.title,
                artUrl: item.artworkUrl,
                durationSec: item.durationSeconds.map(Double.init))
            return .success(dialog:
                String(localized: "siri.bookmark.created",
                       defaultValue: "Bookmarked at \(TimestampFormatter.mmss(Int(position))) in \(item.title).",
                       comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to bookmark the current moment. Argument 1 is a playback position already formatted as m:ss or h:mm:ss; argument 2 is the episode title — user content from the feed, never translated."))

        case .getShareLink:
            guard let item = audio.currentItem else { return failure(Self.nothingPlaying, logAs: "nothing playing", command: command) }
            let position = Int(audio.currentPosition)
            let items = await ShareLinkBuilder.shared.makeItems(for: ShareRequest(
                kind: .episode,
                podcastUrl: item.podcastUrl,
                episodeUrl: item.audioUrl,
                episodeGuid: item.id,
                startSec: position,
                episodeTitle: item.title,
                podcastTitle: item.podcastTitle,
                episodeLink: nil))
            guard let url = items.compactMap({ $0 as? URL }).first else {
                return failure(String(localized: "siri.share.buildFailed",
                                      defaultValue: "Couldn't build a share link right now.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to share the current episode and no shareable link could be produced. No arguments."),
                               logAs: "share builder returned no URL", command: command, unexpected: true)
            }
            return .url(url, dialog:
                String(localized: "siri.share.link",
                       defaultValue: "Here's your link to \(item.title) at \(TimestampFormatter.mmss(position)).",
                       comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when Siri hands the user a share link to the current episode at the current moment. Argument 1 is the episode title — user content from the feed, never translated; argument 2 is a playback position already formatted as m:ss or h:mm:ss."))

        case .getQueue:
            let snaps = audio.queue.map { EpisodeSnapshot(item: $0) }
            let dialog = snaps.isEmpty
                ? String(localized: "siri.queue.empty",
                         defaultValue: "Your queue is empty.",
                         comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to play, list or download the queue and it holds no episodes. No arguments.")
                : String(localized: "siri.queue.episodeCount",
                         defaultValue: "You have \(snaps.count) episodes in your queue.",
                         comment: "Spoken by Siri when the user asks what is in their queue. Argument 1 is the count. Plural rules live in the catalog.")
            return .episodes(snaps, dialog: dialog)

        case .getPodcasts:
            guard let podcastManager else { return failure(Self.notReady, logAs: "podcastManager nil", command: command, unexpected: true) }
            let snaps = podcastManager.subscriptions.map {
                PodcastSnapshot(feedUrl: $0.url, title: $0.title,
                                author: $0.author, artworkUrl: $0.logoUrl)
            }
            return .podcasts(snaps, dialog: String(localized: "siri.library.podcastCount",
                                                   defaultValue: "You follow \(snaps.count) podcasts.",
                                                   comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri which podcasts they follow. Argument 1 is how many podcasts are subscribed. Plural rules live in the catalog."))

        case .whatsNext:
            guard let first = audio.queue.first else {
                return failure(String(localized: "siri.queue.nothingNext",
                                      defaultValue: "Nothing next in your queue.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks for the next episode, or what is up next, and the queue is empty. No arguments."),
                               logAs: "queue empty", command: command)
            }
            let snap = EpisodeSnapshot(item: first)
            return .episode(snap, dialog: String(localized: "siri.queue.upNext",
                                                 defaultValue: "Up next is \(first.title) from \(first.podcastTitle).",
                                                 comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri what is up next in the queue. Argument 1 is the episode title and argument 2 the podcast title — both user content from the feed, never translated."))

        // MARK: Queue & library
        case .checkForNewEpisodes:
            guard let podcastManager, let downloadManager else {
                return failure(Self.notReady, logAs: "podcastManager or downloadManager nil", command: command, unexpected: true)
            }
            let syncLog = Logger(subsystem: "com.yourpods", category: "sync")
            let beforeGuids = Set(podcastManager.subscriptions.flatMap(\.episodes).map(\.guid))
            syncLog.info("⟦siri-handler⟧ checkForNewEpisodes: refreshAndSync starting")
            _ = await podcastManager.refreshAndSync(
                playerManager: player,
                downloadManager: downloadManager,
                settingsManager: settings,
                // Omitting this defaults to .serverWins, so a sync the user triggered by
                // voice silently resolved conflicts against a setting they had changed.
                strategy: settings.syncConflictStrategy)
            let newCount = podcastManager.subscriptions.flatMap(\.episodes)
                .filter { !beforeGuids.contains($0.guid) }.count
            syncLog.info("⟦siri-handler⟧ checkForNewEpisodes: \(newCount) new")
            return .success(dialog: newCount == 0
                ? String(localized: "siri.refresh.noNewEpisodes",
                         defaultValue: "You're all caught up — no new episodes.",
                         comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to check for new episodes and the refresh found none. No arguments.")
                : String(localized: "siri.refresh.newEpisodeCount",
                         defaultValue: "Found \(newCount) new episodes.",
                         comment: "Spoken by Siri after a feed refresh. Argument 1 is how many new episodes appeared. Plural rules live in the catalog."))

        case .downloadQueue:
            guard let downloadManager else {
                return failure(Self.notReady, logAs: "downloadManager nil", command: command, unexpected: true)
            }
            guard !audio.queue.isEmpty else {
                return failure(String(localized: "siri.queue.empty",
                                      defaultValue: "Your queue is empty.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to play, list or download the queue and it holds no episodes. No arguments."),
                               logAs: "queue empty", command: command)
            }
            let pending = audio.queue.filter { !downloadManager.isDownloaded($0.id) }
            guard !pending.isEmpty else {
                return .success(dialog: String(localized: "siri.download.allDownloaded",
                                               defaultValue: "Everything in your queue is already downloaded.",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to download the queue and every episode in it is already on the device. No arguments."))
            }
            for item in pending {
                downloadManager.downloadEpisode(guid: item.id, audioUrl: item.audioUrl)
            }
            return .success(dialog: String(localized: "siri.download.startedCount",
                                           defaultValue: "Downloading \(pending.count) episodes.",
                                           comment: "Spoken by Siri when downloads begin. Argument 1 is how many episodes were queued for download. Plural rules live in the catalog."))

        case .downloadLatest(let feedUrl):
            guard let downloadManager, let podcastManager else {
                return failure(Self.notReady, logAs: "downloadManager or podcastManager nil", command: command, unexpected: true)
            }
            guard let podcast = podcastManager.subscriptions.first(where: { $0.url == feedUrl }) else {
                return failure(String(localized: "siri.library.podcastNotFound",
                                      defaultValue: "That podcast isn't in your library.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user names a podcast to play, download or open and the app is not subscribed to it. No arguments."),
                               logAs: "feed not in library", command: command)
            }
            let latest = podcast.episodes
                .filter { $0.audioUrl != nil }
                .max { ($0.pubDate ?? .distantPast) < ($1.pubDate ?? .distantPast) }
            guard let latest, let audioUrl = latest.audioUrl else {
                return failure(String(localized: "siri.download.noDownloadableEpisodes",
                                      defaultValue: "\(podcast.title) has no downloadable episodes.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to download the latest episode of a subscribed podcast whose feed carries no downloadable audio. Argument 1 is the podcast title — user content from the feed, never translated."),
                               logAs: "no downloadable episodes", command: command)
            }
            if downloadManager.isDownloaded(latest.guid) {
                return .success(dialog: String(localized: "siri.download.alreadyDownloaded",
                                               defaultValue: "\(latest.title) is already downloaded.",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri to download a podcast's latest episode and it is already on the device. Argument 1 is the episode title — user content from the feed, never translated."))
            }
            downloadManager.downloadEpisode(guid: latest.guid, audioUrl: audioUrl)
            return .success(dialog: String(localized: "siri.download.started",
                                           defaultValue: "Downloading \(latest.title).",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when Siri starts downloading a podcast's latest episode. Argument 1 is the episode title — user content from the feed, never translated."))

        case .markPlayedAndPlayNext:
            guard let current = audio.currentItem else {
                return failure(Self.nothingPlaying, logAs: "nothing playing", command: command)
            }
            let hadNext = !audio.queue.isEmpty
            player.markCurrentEpisodeAsPlayed(fromSync: false)
            // markCurrentEpisodeAsPlayed's stop() nils audioManager.currentItem
            // synchronously on this branch (pre-mark-played-auto-advance), so
            // "didn't already advance" reads as currentItem == nil, NOT
            // currentItem still equal to `current` — the latter can never be
            // true once stop() has run. Once the mark-played-auto-advance plan
            // lands, a completed advance leaves currentItem already pointing at
            // the next (different, non-nil) item, so this guard still holds:
            // only nil-or-unchanged means "advance ourselves".
            if hadNext && (audio.currentItem == nil || audio.currentItem?.id == current.id) {
                player.skipToNext()
            }
            if let next = audio.currentItem, next.id != current.id {
                return .success(dialog: String(localized: "siri.markPlayed.andPlayingNext",
                                               defaultValue: "Marked played. Now playing \(next.title).",
                                               comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to mark the current episode played and playback moves on to the next queued one. Argument 1 is the title of the episode now playing — user content from the feed, never translated."))
            }
            return .success(dialog: String(localized: "siri.markPlayed.done",
                                           defaultValue: "Marked \(current.title) as played.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to mark the current episode played and there is nothing queued to play next. Argument 1 is the episode title — user content from the feed, never translated."))

        case .clearQueue:
            player.clearAllQueue()
            return .success(dialog: String(localized: "siri.queue.cleared",
                                           defaultValue: "Queue cleared.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said after the user asks Siri to empty the queue. No arguments."))

        case .getListeningStats:
            guard let stats = ListeningStatsService.loadFromCache() else {
                return failure(String(localized: "siri.stats.notReady",
                                      defaultValue: "Stats aren't ready yet — open Listening Stats in YourPods first.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri for listening stats before the app has ever built its stats cache. 'Listening Stats' names an in-app screen and 'YourPods' is the app name: use the same wording your translation gives that screen, and never translate the app name. No arguments."),
                               logAs: "no stats cache", command: command)
            }
            let snapshot = ListeningStatsSnapshot(
                minutesToday: ListeningStatsService.minutes(in: stats.dailyListening, daysBack: 1),
                minutesThisWeek: ListeningStatsService.minutes(in: stats.dailyListening, daysBack: 7),
                episodesCompleted: stats.episodesCompleted,
                currentStreakDays: stats.currentStreak)
            return .stats(snapshot, dialog:
                String(localized: "siri.stats.summary",
                       defaultValue: "You've listened \(snapshot.minutesToday) minutes today and \(snapshot.minutesThisWeek) minutes this week.",
                       comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user asks Siri for their listening stats. Argument 1 is minutes listened today, argument 2 is minutes listened over the last seven days; each count governs its own 'minutes', so plural rules live in the catalog."))

        case .openPodcast(let feedUrl):
            guard let navigationState, let podcastManager else {
                return failure(Self.notReady, logAs: "navigationState or podcastManager nil", command: command, unexpected: true)
            }
            guard let podcast = podcastManager.subscriptions.first(where: { $0.url == feedUrl }) else {
                return failure(String(localized: "siri.library.podcastNotFound",
                                      defaultValue: "That podcast isn't in your library.",
                                      comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said when the user names a podcast to play, download or open and the app is not subscribed to it. No arguments."),
                               logAs: "feed not in library", command: command)
            }
            navigationState.navigateToLibrary(podcast: podcast)
            return .success(dialog: String(localized: "siri.navigation.openingPodcast",
                                           defaultValue: "Opening \(podcast.title).",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said as Siri opens the app on a podcast's page. Argument 1 is the podcast title — user content from the feed, never translated."))

        case .openQueue:
            guard let navigationState else {
                return failure(Self.notReady, logAs: "navigationState nil", command: command, unexpected: true)
            }
            navigationState.selectedTab = 2   // Up Next tab (NavigationState.init "upnext" case)
            return .success(dialog: String(localized: "siri.navigation.openingQueue",
                                           defaultValue: "Opening your queue.",
                                           comment: "Spoken aloud by Siri, so it must sound natural read out rather than read on screen. Said as Siri opens the app on the Up Next queue tab. No arguments."))
        }
    }

    /// Project rule: guards always log when they fire. `reason` must be a static
    /// literal — the user-facing `message` may interpolate user data (titles) and
    /// must never reach public log output.
    private func failure(_ message: String, logAs reason: StaticString,
                         command: SiriIntentCommand, unexpected: Bool = false) -> IntentOutcome {
        if unexpected {
            log.error("⟦siri-handler⟧ \(command.caseName, privacy: .public) failed: \(reason, privacy: .public)")
        } else {
            log.info("⟦siri-handler⟧ \(command.caseName, privacy: .public) declined: \(reason, privacy: .public)")
        }
        return .failure(message: message)
    }
}

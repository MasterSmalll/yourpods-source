import XCTest
@testable import YourPods

final class EpisodeAccessibilityTests: XCTestCase {
    
    // MARK: - Episode Label Tests
    
    func test_episodeLabel_includesTitleAndPodcast() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "How AI is Changing Everything",
            podcastTitle: "Tech Daily",
            pubDate: nil,
            durationSeconds: 3600,
            listenedSeconds: 0,
            isPlayed: false,
            isPlaying: false,
            isDownloaded: false
        )
        XCTAssertTrue(label.contains("How AI is Changing Everything"), "Label must contain episode title")
        XCTAssertTrue(label.contains("Tech Daily"), "Label must contain podcast title")
    }
    
    func test_episodeLabel_includesSpokenDuration() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: "My Podcast",
            pubDate: nil,
            durationSeconds: 3660, // 1 hour 1 minute
            listenedSeconds: 0,
            isPlayed: false,
            isPlaying: false,
            isDownloaded: false
        )
        XCTAssertTrue(label.contains("1 hour"), "Label must contain spoken duration")
    }
    
    func test_episodeLabel_showsRemainingTime_whenPartiallyListened() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: "My Podcast",
            pubDate: nil,
            durationSeconds: 3600, // 60 min total
            listenedSeconds: 1800, // 30 min listened
            isPlayed: false,
            isPlaying: false,
            isDownloaded: false
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("remaining") || label.localizedCaseInsensitiveContains("left"),
                       "Label must indicate remaining time for in-progress episodes")
        XCTAssertTrue(label.contains("30 minute"), "Label should show 30 minutes remaining")
    }
    
    func test_episodeLabel_indicatesPlayingState() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: "My Podcast",
            pubDate: nil,
            durationSeconds: 3600,
            listenedSeconds: 0,
            isPlayed: false,
            isPlaying: true,
            isDownloaded: false
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("currently playing"),
                       "Label must indicate currently playing state")
    }
    
    func test_episodeLabel_indicatesPlayedState() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: "My Podcast",
            pubDate: nil,
            durationSeconds: 3600,
            listenedSeconds: 3600,
            isPlayed: true,
            isPlaying: false,
            isDownloaded: false
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("played"),
                       "Label must indicate played state")
    }
    
    func test_episodeLabel_indicatesDownloadedState() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: "My Podcast",
            pubDate: nil,
            durationSeconds: 3600,
            listenedSeconds: 0,
            isPlayed: false,
            isPlaying: false,
            isDownloaded: true
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("downloaded"),
                       "Label must indicate downloaded state")
    }
    
    func test_episodeLabel_handlesNilDuration() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: "My Podcast",
            pubDate: nil,
            durationSeconds: nil,
            listenedSeconds: 0,
            isPlayed: false,
            isPlaying: false,
            isDownloaded: false
        )
        // Should still work, just without duration info
        XCTAssertTrue(label.contains("Episode 1"), "Label must contain title even without duration")
        XCTAssertFalse(label.contains("minute"), "Label should not mention duration when nil")
    }
    
    func test_episodeLabel_handlesNilPodcastTitle() {
        let label = EpisodeAccessibility.episodeLabel(
            title: "Episode 1",
            podcastTitle: nil,
            pubDate: nil,
            durationSeconds: 600,
            listenedSeconds: 0,
            isPlayed: false,
            isPlaying: false,
            isDownloaded: false
        )
        XCTAssertTrue(label.contains("Episode 1"), "Label must contain title")
        // Should not crash or include "nil"
        XCTAssertFalse(label.contains("nil"), "Label must not contain the word 'nil'")
    }
    
    // MARK: - Episode Hint Tests
    
    func test_episodeHint_isNotEmpty() {
        let hint = EpisodeAccessibility.episodeHint()
        XCTAssertFalse(hint.isEmpty, "Hint must not be empty")
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("double tap"),
                       "Hint should mention double tap")
    }
    
    // MARK: - Episode Action Names Tests
    
    func test_episodeActionNames_containsRequiredActions() {
        let actions = EpisodeAccessibility.episodeActionNames(
            isPlaying: false,
            isPlayed: false,
            isDownloaded: false
        )
        XCTAssertTrue(actions.contains("Play"), "Actions must include Play")
        XCTAssertTrue(actions.contains("Play Next"), "Actions must include Play Next")
        XCTAssertTrue(actions.contains("Add to Queue"), "Actions must include Add to Queue")
        XCTAssertTrue(actions.contains("Mark as Played"), "Actions must include Mark as Played")
        XCTAssertTrue(actions.contains("Download"), "Actions must include Download")
    }
    
    func test_episodeActionNames_showsMarkAsUnplayed_whenPlayed() {
        let actions = EpisodeAccessibility.episodeActionNames(
            isPlaying: false,
            isPlayed: true,
            isDownloaded: false
        )
        XCTAssertTrue(actions.contains("Mark as Unplayed"), "Should show 'Mark as Unplayed' for played episodes")
        XCTAssertFalse(actions.contains("Mark as Played"), "Should not show 'Mark as Played' for played episodes")
    }
    
    func test_episodeActionNames_showsRemoveDownload_whenDownloaded() {
        let actions = EpisodeAccessibility.episodeActionNames(
            isPlaying: false,
            isPlayed: false,
            isDownloaded: true
        )
        XCTAssertTrue(actions.contains("Remove Download"), "Should show 'Remove Download' for downloaded episodes")
        XCTAssertFalse(actions.contains("Download"), "Should not show 'Download' for downloaded episodes")
    }
    
    // MARK: - Queue Item Label Tests
    
    func test_queueItemLabel_includesTitleAndPodcast() {
        let label = EpisodeAccessibility.queueItemLabel(
            title: "Queue Episode",
            podcastTitle: "Queue Podcast",
            durationSeconds: 1800,
            positionSeconds: 0,
            isNowPlaying: false,
            progress: 0
        )
        XCTAssertTrue(label.contains("Queue Episode"), "Label must contain title")
        XCTAssertTrue(label.contains("Queue Podcast"), "Label must contain podcast title")
    }
    
    func test_queueItemLabel_indicatesNowPlaying() {
        let label = EpisodeAccessibility.queueItemLabel(
            title: "Queue Episode",
            podcastTitle: "Queue Podcast",
            durationSeconds: 1800,
            positionSeconds: 0,
            isNowPlaying: true,
            progress: 0.5
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("now playing") ||
                       label.localizedCaseInsensitiveContains("currently playing"),
                       "Label must indicate now playing state")
    }
    
    func test_queueItemLabel_showsRemainingTime() {
        let label = EpisodeAccessibility.queueItemLabel(
            title: "Queue Episode",
            podcastTitle: "Queue Podcast",
            durationSeconds: 3600,
            positionSeconds: 1800,
            isNowPlaying: false,
            progress: 0
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("remaining") ||
                       label.localizedCaseInsensitiveContains("left"),
                       "Label must show remaining time")
    }
    
    // MARK: - Queue Item Action Names Tests
    
    func test_queueItemActionNames_forUpcoming() {
        let actions = EpisodeAccessibility.queueItemActionNames(isNowPlaying: false)
        XCTAssertTrue(actions.contains("Play"), "Queue actions must include Play")
        XCTAssertTrue(actions.contains("Play Next"), "Queue actions must include Play Next")
        XCTAssertTrue(actions.contains("Remove from Queue"), "Queue actions must include Remove")
        XCTAssertTrue(actions.contains("Mark as Played"), "Queue actions must include Mark as Played")
    }
    
    func test_queueItemActionNames_forNowPlaying() {
        let actions = EpisodeAccessibility.queueItemActionNames(isNowPlaying: true)
        XCTAssertTrue(actions.contains("Mark as Played"), "Now playing actions must include Mark as Played")
        XCTAssertTrue(actions.contains("Details"), "Now playing actions must include Details")
        // Should NOT have Play/Play Next/Remove for the now-playing item
        XCTAssertFalse(actions.contains("Play"), "Now playing should not have Play action")
        XCTAssertFalse(actions.contains("Remove from Queue"), "Now playing should not have Remove action")
    }
    
    // MARK: - Now Playing Label Tests
    
    func test_nowPlayingLabel_includesAllInfo() {
        let label = EpisodeAccessibility.nowPlayingLabel(
            title: "Current Episode",
            podcastTitle: "Current Podcast",
            isPlaying: true
        )
        XCTAssertTrue(label.contains("Current Episode"), "Label must contain title")
        XCTAssertTrue(label.contains("Current Podcast"), "Label must contain podcast")
        XCTAssertTrue(label.localizedCaseInsensitiveContains("playing"),
                       "Label must indicate playing state")
    }
    
    func test_nowPlayingLabel_showsPaused() {
        let label = EpisodeAccessibility.nowPlayingLabel(
            title: "Current Episode",
            podcastTitle: "Current Podcast",
            isPlaying: false
        )
        XCTAssertTrue(label.localizedCaseInsensitiveContains("paused"),
                       "Label must indicate paused state")
    }
    
    // MARK: - Spoken Duration Tests
    
    func test_spokenDuration_minutesOnly() {
        let spoken = EpisodeAccessibility.spokenDuration(2700) // 45 minutes
        XCTAssertEqual(spoken, "45 minutes")
    }
    
    func test_spokenDuration_hoursAndMinutes() {
        let spoken = EpisodeAccessibility.spokenDuration(5580) // 1 hour 33 minutes
        XCTAssertEqual(spoken, "1 hour 33 minutes")
    }
    
    func test_spokenDuration_multipleHours() {
        let spoken = EpisodeAccessibility.spokenDuration(7200) // 2 hours
        XCTAssertEqual(spoken, "2 hours")
    }
    
    func test_spokenDuration_secondsOnly() {
        let spoken = EpisodeAccessibility.spokenDuration(45)
        XCTAssertEqual(spoken, "45 seconds")
    }
    
    func test_spokenDuration_zero() {
        let spoken = EpisodeAccessibility.spokenDuration(0)
        XCTAssertEqual(spoken, "0 seconds")
    }
    
    func test_spokenDuration_oneMinute() {
        let spoken = EpisodeAccessibility.spokenDuration(60)
        XCTAssertEqual(spoken, "1 minute")
    }
    
    func test_spokenDuration_oneHour() {
        let spoken = EpisodeAccessibility.spokenDuration(3600)
        XCTAssertEqual(spoken, "1 hour")
    }

    // MARK: - Localization: no bare English literals

    /// Every user-facing string this helper emits is read aloud by VoiceOver.
    /// A bare Swift literal here never reaches a String Catalog, so it stays
    /// English in every language — and unlike a visible label, nobody
    /// screenshotting the app will ever notice.
    ///
    /// The rule: a line carrying a string literal must be part of a
    /// `String(localized:)` expression — the call itself, or one of its
    /// `defaultValue:` / `comment:` continuation lines.
    func test_episodeAccessibility_hasNoUnlocalizedUserFacingLiterals() throws {
        let url = Self.sourceURL()
        let contents = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
            "could not read EpisodeAccessibility.swift — did it move?")
        XCTAssertGreaterThan(contents.count, 500,
            "EpisodeAccessibility.swift is implausibly small — wrong path?")

        let offenders = Self.unlocalizedLiteralLines(in: contents)
        XCTAssertTrue(offenders.isEmpty, """
        Bare string literal in EpisodeAccessibility.swift:

          \(offenders.joined(separator: "\n  "))

        These are VoiceOver labels and rotor action names. A bare literal is
        never extracted, so it is read in English under every language. Wrap it
        in String(localized:) with an explicit a11y.* key.
        """)
    }

    /// A guard whose scanner cannot fire is not evidence.
    func test_unlocalizedLiteralScanner_decidesCorrectly() {
        let cases: [(String, Bool, String)] = [
            (#"        parts.append("Currently playing")"#, true, "bare literal is the defect"),
            (#"        actions.append(isPlayed ? "Mark as Unplayed" : "Mark as Played")"#, true, "literal ternary is still unextracted here — this is a String helper, not a LocalizedStringKey position"),
            (#"        String(localized: "a11y.episode.state.played","#, false, "the localized call itself"),
            (#"               defaultValue: "Played","#, false, "continuation line carrying the English"),
            (#"               comment: "VoiceOver: marked as played.")"#, false, "continuation line carrying the comment"),
            (#"        // parts.append("Currently playing")"#, false, "comments are exempt"),
            (#"        guard duration > 0 else { return "" }"#, false, "an empty literal is not untranslated English — it is 'say nothing'"),
            (#"        guard duration > 0 else { return "" + "Played" }"#, true, "an empty literal does not launder the one beside it"),
            (#"        let total = max(0, seconds)"#, false, "no literal at all"),
            (#"        return parts.joined(separator: separator)"#, false, "no literal"),
        ]
        for (source, expected, why) in cases {
            let hit = !Self.unlocalizedLiteralLines(in: source).isEmpty
            XCTAssertEqual(hit, expected, "scanner disagreed on: \(source)\n  because \(why)")
        }
    }

    // MARK: - Scanner (shared by the real scan and its self-check)

    private static func sourceURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)  // …/YourPodsTests/ThisFile.swift
        root.deleteLastPathComponent()              // …/YourPodsTests
        root.deleteLastPathComponent()              // repo root
        return root.appendingPathComponent("YourPods/YourPods/Utils/EpisodeAccessibility.swift")
    }

    private static func unlocalizedLiteralLines(in contents: String) -> [String] {
        var out: [String] = []
        for (i, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
            // An empty literal carries no English, so it cannot be
            // untranslated English. `progressValue` returns one deliberately:
            // a duration of zero means "say nothing", and VoiceOver then reads
            // the label alone. Removed before the check rather than exempted
            // by line, so `"" + "Played"` is still caught.
            let withoutEmpty = line.replacingOccurrences(of: "\"\"", with: "")
            guard withoutEmpty.contains("\"") else { continue }
            // Legal homes for an English literal: the localized call and its
            // continuation lines.
            if line.contains("String(localized:")
                || trimmed.hasPrefix("defaultValue:")
                || trimmed.hasPrefix("comment:") { continue }
            out.append("\(i + 1): \(trimmed)")
        }
        return out
    }
}

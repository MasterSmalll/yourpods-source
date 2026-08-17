import Foundation

// MARK: - Episode Accessibility Helper

/// Pure-logic helper that computes VoiceOver labels, hints, and custom action names
/// for episode items across the app. Extracted from view code for testability.
///
/// ## Everything here is read aloud
///
/// These strings never appear on screen, so a missed translation is invisible
/// to anyone reviewing screenshots — it only shows up to a VoiceOver user in
/// German hearing "Currently playing". Every user-facing literal in this file
/// therefore goes through `String(localized:)` with an explicit `a11y.` key,
/// and `EpisodeAccessibilityTests` scans the source to enforce it.
///
/// ## Why the separator is a catalog key, not `ListFormatter`
///
/// These labels are *attribute sequences* — title, show, state, duration — not
/// enumerations. The comma is a prosodic pause marker for the speech
/// synthesiser, not list punctuation, so `ListFormatter` is wrong here: it
/// would render "1 hour, and Downloaded" and make the last attribute sound
/// special. The separator is still a language convention, so it lives in the
/// catalog (`a11y.list.separator`) where a locale that pauses differently can
/// change it.
enum EpisodeAccessibility {

    // MARK: - Fragments
    //
    // Each fragment is its own catalog key so a translator sees one complete
    // idea at a time, with a comment saying where it is spoken.

    /// The pause marker between spoken attributes. See the type doc.
    static var listSeparator: String {
        String(localized: "a11y.list.separator",
               defaultValue: ", ",
               comment: "Separator spoken between attributes in a VoiceOver label. A pause marker, not list punctuation — do not translate to 'and'.")
    }

    private static func join(_ parts: [String]) -> String {
        parts.joined(separator: listSeparator)
    }

    private static func stateFragment(isPlaying: Bool, isHidden: Bool, isPlayed: Bool) -> String? {
        if isPlaying {
            return String(localized: "a11y.episode.state.playing",
                          defaultValue: "Currently playing",
                          comment: "VoiceOver: this episode is the one playing now.")
        }
        if isHidden {
            return String(localized: "a11y.episode.state.hidden",
                          defaultValue: "Hidden",
                          comment: "VoiceOver: this episode is hidden from the list.")
        }
        if isPlayed {
            return String(localized: "a11y.episode.state.played",
                          defaultValue: "Played",
                          comment: "VoiceOver: this episode is marked as played.")
        }
        return nil
    }

    private static func remainingFragment(_ seconds: Int) -> String {
        String(localized: "a11y.episode.remaining",
               defaultValue: "\(DurationFormatting.spoken(seconds)) remaining",
               comment: "VoiceOver: time left in an episode. The argument is a spoken duration such as '5 minutes'.")
    }

    private static func downloadedFragment() -> String {
        String(localized: "a11y.episode.state.downloaded",
               defaultValue: "Downloaded",
               comment: "VoiceOver: this episode is downloaded for offline playback.")
    }

    private static func inQueueFragment() -> String {
        String(localized: "a11y.episode.state.inQueue",
               defaultValue: "In Up Next queue",
               comment: "VoiceOver: this episode is in the Up Next queue. 'Up Next' is a product term — keep it consistent with the queue's name elsewhere in the app.")
    }

    // MARK: - Episode Row (PodcastDetailView)

    /// Builds a descriptive VoiceOver label for an episode row.
    /// Includes: title, podcast name, pub date, duration/remaining, played/playing/downloaded status.
    static func episodeLabel(
        title: String,
        podcastTitle: String?,
        pubDate: Date?,
        durationSeconds: Int?,
        listenedSeconds: Int,
        isPlayed: Bool,
        isPlaying: Bool,
        isDownloaded: Bool,
        isHidden: Bool = false,
        isInQueue: Bool = false
    ) -> String {
        var parts: [String] = []

        // Title is always first
        parts.append(title)

        // Podcast name
        if let podcastTitle, !podcastTitle.isEmpty {
            parts.append(podcastTitle)
        }

        // State indicators (most important first)
        if let state = stateFragment(isPlaying: isPlaying, isHidden: isHidden, isPlayed: isPlayed) {
            parts.append(state)
        }

        // Duration or remaining time
        if let durationSeconds {
            if listenedSeconds > 0 && !isPlayed {
                let remaining = max(0, durationSeconds - listenedSeconds)
                parts.append(remainingFragment(remaining))
            } else if !isPlayed {
                parts.append(spokenDuration(durationSeconds))
            }
        }

        // Downloaded state
        if isDownloaded {
            parts.append(downloadedFragment())
        }

        // Queue state
        if isInQueue && !isPlaying {
            parts.append(inQueueFragment())
        }

        return join(parts)
    }

    /// Returns the VoiceOver hint for an episode row.
    static func episodeHint() -> String {
        String(localized: "a11y.episode.hint",
               defaultValue: "Double tap to show episode details",
               comment: "VoiceOver hint spoken after an episode row's label.")
    }

    /// Returns the list of custom rotor action names for an episode row.
    /// These map to VoiceOver's "Actions" rotor — flick up/down to browse, double-tap to activate.
    ///
    /// An untranslated rotor name is unusable, not merely ugly: it is the only
    /// way a VoiceOver user reaches these commands.
    static func episodeActionNames(isPlaying: Bool, isPlayed: Bool, isDownloaded: Bool, isHidden: Bool = false) -> [String] {
        var actions: [String] = []
        actions.append(Action.play)
        actions.append(Action.playNext)
        actions.append(Action.addToQueue)
        actions.append(isDownloaded ? Action.removeDownload : Action.download)
        actions.append(isPlayed ? Action.markUnplayed : Action.markPlayed)
        actions.append(isHidden ? Action.unhide : Action.hide)
        return actions
    }

    // MARK: - Queue Item Row (QueueView)

    /// Builds a descriptive VoiceOver label for a queue item row.
    static func queueItemLabel(
        title: String,
        podcastTitle: String,
        durationSeconds: Int?,
        positionSeconds: Int,
        isNowPlaying: Bool,
        progress: Double
    ) -> String {
        var parts: [String] = []

        parts.append(title)
        parts.append(podcastTitle)

        if isNowPlaying {
            // Two fragments, not one: the old single literal embedded its own
            // ", " separator, which hid a second sentence from the translator.
            if let state = stateFragment(isPlaying: true, isHidden: false, isPlayed: false) {
                parts.append(state)
            }
            parts.append(DurationFormatting.percentListened(Int(progress * 100)))
        } else if let durationSeconds, durationSeconds > 0 {
            if positionSeconds > 0 {
                let remaining = max(0, durationSeconds - positionSeconds)
                parts.append(remainingFragment(remaining))
            } else {
                parts.append(spokenDuration(durationSeconds))
            }
        }

        return join(parts)
    }

    /// Returns the list of custom rotor action names for a queue item row.
    static func queueItemActionNames(isNowPlaying: Bool) -> [String] {
        if isNowPlaying {
            return [Action.markPlayed, Action.details]
        } else {
            return [Action.play, Action.playNext, Action.removeFromQueue, Action.markPlayed]
        }
    }

    // MARK: - Rotor Action Names
    //
    // Shared between the episode row, the queue row, and
    // `EpisodeDownloadHelper` so one translation serves them all — these are
    // the same commands wherever they appear. Internal rather than private
    // for exactly that reason: a second copy of "Download" would be a second
    // catalog key and could drift to a different German word.

    enum Action {
        static var play: String {
            String(localized: "a11y.action.play", defaultValue: "Play",
                   comment: "VoiceOver rotor action: start playing this episode.")
        }
        static var playNext: String {
            String(localized: "a11y.action.playNext", defaultValue: "Play Next",
                   comment: "VoiceOver rotor action: put this episode next in the Up Next queue.")
        }
        static var addToQueue: String {
            String(localized: "a11y.action.addToQueue", defaultValue: "Add to Queue",
                   comment: "VoiceOver rotor action: append this episode to the Up Next queue.")
        }
        static var removeFromQueue: String {
            String(localized: "a11y.action.removeFromQueue", defaultValue: "Remove from Queue",
                   comment: "VoiceOver rotor action: take this episode out of the Up Next queue.")
        }
        static var download: String {
            String(localized: "a11y.action.download", defaultValue: "Download",
                   comment: "VoiceOver rotor action: download this episode for offline playback.")
        }
        static var removeDownload: String {
            String(localized: "a11y.action.removeDownload", defaultValue: "Remove Download",
                   comment: "VoiceOver rotor action: delete the downloaded file.")
        }
        static var markPlayed: String {
            String(localized: "a11y.action.markPlayed", defaultValue: "Mark as Played",
                   comment: "VoiceOver rotor action: mark this episode played.")
        }
        static var markUnplayed: String {
            String(localized: "a11y.action.markUnplayed", defaultValue: "Mark as Unplayed",
                   comment: "VoiceOver rotor action: mark this episode unplayed.")
        }
        static var hide: String {
            String(localized: "a11y.action.hide", defaultValue: "Hide",
                   comment: "VoiceOver rotor action: hide this episode from the list.")
        }
        static var unhide: String {
            String(localized: "a11y.action.unhide", defaultValue: "Unhide",
                   comment: "VoiceOver rotor action: show a previously hidden episode.")
        }
        static var details: String {
            String(localized: "a11y.action.details", defaultValue: "Details",
                   comment: "VoiceOver rotor action: open this episode's detail screen.")
        }
    }

    /// The spoken value of a seek bar — "12 minutes of 45 minutes".
    ///
    /// Returns empty for a duration of zero, which is what a stalled or
    /// not-yet-loaded stream reports; VoiceOver then reads only the label.
    ///
    /// Both scrubbers built this inline in a `{ … }()` closure, which returns
    /// `String` and so never extracted — neither the `of` nor the empty
    /// fallback. The empty string was the more interesting half: it is what
    /// put a `""` key in the catalog.
    static func progressValue(position: Int, duration: Int) -> String {
        guard duration > 0 else { return "" }
        return String(localized: "a11y.progress.positionOfDuration",
                      defaultValue: "\(spokenDuration(position)) of \(spokenDuration(duration))",
                      comment: "VoiceOver value for a seek bar. Argument 1 is how far in playback has reached, 2 the episode's total length — e.g. '12 minutes of 45 minutes'.")
    }

    /// "Hide" or "Unhide" for the toggle's rotor action.
    ///
    /// A named function rather than a ternary at the call site: the now
    /// playing bar reached for a `{ … }()` closure to resolve the optional
    /// episode first, and a closure returns `String`, which silently binds
    /// the `@_disfavoredOverload` and never extracts either word.
    static func hideActionName(isHidden: Bool) -> String {
        isHidden ? Action.unhide : Action.hide
    }

    /// Label for a compact episode card — title, show, and whether it is new.
    ///
    /// The card views built this with `label += ", \(podcastTitle)"`, which
    /// freezes both the separator and the clause order in Swift. Same
    /// fragments, same English, but each piece is now a catalog key.
    static func cardLabel(title: String, podcastTitle: String?, isNew: Bool) -> String {
        var parts = [title]
        if let podcastTitle { parts.append(podcastTitle) }
        if isNew {
            parts.append(String(localized: "a11y.episode.new",
                                defaultValue: "New episode",
                                comment: "VoiceOver: this episode was published recently and has not been played."))
        }
        return join(parts)
    }

    // MARK: - Now Playing Bar

    /// Builds a VoiceOver label for the now playing bar's title area.
    ///
    /// One template per state rather than `"\(state): \(title), \(podcastTitle)"`.
    /// The old form gave the translator a bare `"Playing"` and a punctuation
    /// skeleton assembled in Swift; neither the colon nor the word order was
    /// theirs to change.
    static func nowPlayingLabel(
        title: String,
        podcastTitle: String,
        isPlaying: Bool
    ) -> String {
        isPlaying
            ? String(localized: "a11y.nowPlaying.playing",
                     defaultValue: "Playing: \(title), \(podcastTitle)",
                     comment: "VoiceOver label for the mini player while playing. First argument is the episode title, second the show name.")
            : String(localized: "a11y.nowPlaying.paused",
                     defaultValue: "Paused: \(title), \(podcastTitle)",
                     comment: "VoiceOver label for the mini player while paused. First argument is the episode title, second the show name.")
    }

    // MARK: - Duration Formatting (Spoken)

    /// Formats seconds as a spoken-friendly duration string for VoiceOver.
    ///
    /// Retained as a forwarding shim — called from this file and from existing
    /// tests. Plural handling lives in `DurationFormatting.spoken(_:)` and its
    /// catalog variations, which express plural rules the old `== 1` ternaries
    /// could not (French singular zero, Slavic three/four forms).
    static func spokenDuration(_ seconds: Int) -> String {
        DurationFormatting.spoken(seconds)
    }
}

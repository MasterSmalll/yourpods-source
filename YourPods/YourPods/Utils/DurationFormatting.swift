import Foundation

/// The single owner of duration, relative-time and playback-rate rendering.
///
/// Thirteen files each carried a private copy of the clock formatter and four
/// more carried a private `"Xh Ym"`. Duplication is the smaller problem: the
/// copies encode English grammar — a bare `"m"` suffix, an `== 1` plural, an
/// `"ago"` appended after a system-rendered offset — in files a translator
/// will never see. Centralizing them is what makes them translatable at all.
///
/// ## Two different jobs
///
/// `timestamp(_:)` is a **clock**, not prose: a scrubber position, a chapter
/// offset, a note's timecode. It is deliberately locale-independent —
/// `String(format:)` emits Western digits under every locale, and all five
/// target languages read `h:mm:ss`. Do not "localize" it.
///
/// Everything else is prose and goes through the catalog.
enum DurationFormatting {

    /// Clock position as `m:ss`, or `h:mm:ss` past an hour.
    ///
    /// Non-finite and negative inputs collapse to `0:00`. `AVPlayer` hands out
    /// `.nan` durations on a stalled stream and `Int(TimeInterval.nan)` traps,
    /// so the guard lives here rather than at 13 call sites.
    nonisolated static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// A minutes:seconds countdown that **never rolls over to hours** —
    /// `61:01`, not `1:01:01`.
    ///
    /// This is not the same formatter as `timestamp(_:)`, which is why the
    /// sleep timer kept its own copy. A sleep-timer countdown reads its total
    /// as minutes remaining, and `SleepTimerManagerTests.test_extend_largeAmount`
    /// extends past an hour and pins `61:01`. Rolling to `h:mm:ss` there would
    /// be a behaviour change, not a cleanup. Also locale-independent.
    nonisolated static func countdown(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Approximate duration in the compact form used on episode rows and
    /// stats — `2h 2m`, `47m`, `9s`.
    ///
    /// Every unit is a separate catalog key with **positional** specifiers.
    /// German reads `2 Std. 2 Min.`, Dutch `2 u 2 min`; the abbreviation, the
    /// spacing, and in some registers the order all differ. A single
    /// `"\(h)h \(m)m"` cannot express any of that, which is why four copies of
    /// it existed and none of them could ship in a second language.
    ///
    /// Rounding is truncation at every boundary, reproducing the four
    /// formatters this replaces: 119s is `1m`, not `2m`.
    nonisolated static func compact(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return compactSeconds(0) }
        let total = Int(max(0, seconds))
        if total >= 3600 {
            return String(localized: "format.duration.hoursMinutes",
                          defaultValue: "\(total / 3600)h \((total % 3600) / 60)m",
                          comment: "Compact duration, hours and minutes, e.g. '2h 5m'. Both arguments are positional so word order can change.")
        }
        if total >= 60 {
            return String(localized: "format.duration.minutes",
                          defaultValue: "\(total / 60)m",
                          comment: "Compact duration under an hour, e.g. '47m'.")
        }
        return compactSeconds(total)
    }

    private nonisolated static func compactSeconds(_ seconds: Int) -> String {
        String(localized: "format.duration.seconds",
               defaultValue: "\(seconds)s",
               comment: "Compact duration under a minute, e.g. '9s'.")
    }

    /// Spoken-friendly duration for VoiceOver — `2 hours 2 minutes`.
    ///
    /// Each unit is its own catalog key so the catalog can carry real plural
    /// **variations**. The `== 1 ? "hour" : "hours"` ternaries this replaces
    /// encode English's two-form rule in Swift, where no translator can reach
    /// them; French pluralizes zero as singular and Slavic languages have
    /// three or four forms. The catalog is the only place that can express it.
    nonisolated static func spoken(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 && minutes > 0 {
            return String(localized: "a11y.duration.hoursMinutes",
                          defaultValue: "\(hoursPhrase(hours)) \(minutesPhrase(minutes))",
                          comment: "Spoken duration combining hours and minutes for VoiceOver, e.g. '2 hours 5 minutes'.")
        }
        if hours > 0 { return hoursPhrase(hours) }
        if minutes > 0 { return minutesPhrase(minutes) }
        return secondsPhrase(secs)
    }

    private nonisolated static func hoursPhrase(_ hours: Int) -> String {
        String(localized: "a11y.duration.hours",
               defaultValue: "\(hours) hours",
               comment: "Spoken hour count for VoiceOver. Plural variations live in the catalog.")
    }

    private nonisolated static func minutesPhrase(_ minutes: Int) -> String {
        String(localized: "a11y.duration.minutes",
               defaultValue: "\(minutes) minutes",
               comment: "Spoken minute count for VoiceOver. Plural variations live in the catalog.")
    }

    private nonisolated static func secondsPhrase(_ secs: Int) -> String {
        String(localized: "a11y.duration.seconds",
               defaultValue: "\(secs) seconds",
               comment: "Spoken second count for VoiceOver. Plural variations live in the catalog.")
    }

    /// A signed, localized relative-time phrase — `5 minutes ago`,
    /// `in 2 hours`, and in German `vor 5 Minuten` / `in 2 Stunden`.
    ///
    /// Generalizes the one already-correct call site in the app
    /// (`EpisodeActivityView`'s VoiceOver label). Two things a call site must
    /// never do again: append `" ago"` to a system-rendered offset — German
    /// puts that word in front, and no catalog entry can move it once the
    /// number is rendered outside the string — or use SwiftUI's
    /// `style: .relative`, which is **unsigned** and renders a future date
    /// identically to a past one.
    nonisolated static func relative(_ date: Date, to reference: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// "1h 1m left" as one template.
    ///
    /// Four call sites wrote `"\(formatDuration(x)) left"`. Splitting a
    /// sentence at the placeholder is the single most common way a UI becomes
    /// untranslatable: the fragment order is fixed by the Swift source, where
    /// no translator can reach it.
    nonisolated static func remaining(_ seconds: TimeInterval) -> String {
        String(localized: "format.duration.remaining",
               defaultValue: "\(compact(seconds)) left",
               comment: "Time left in an episode. The argument is an already-formatted duration such as '1h 1m'.")
    }

    /// "50% listened" — the share of an episode already played.
    nonisolated static func percentListened(_ percent: Int) -> String {
        String(localized: "format.progress.listened",
               defaultValue: "\(percent)% listened",
               comment: "Share of an episode already played, e.g. '50% listened'.")
    }

    /// "50% left" — the share of an episode still unplayed.
    nonisolated static func percentLeft(_ percent: Int) -> String {
        String(localized: "format.progress.left",
               defaultValue: "\(percent)% left",
               comment: "Share of an episode still unplayed, e.g. '50% left'.")
    }

    /// A count-down clock shown beside the elapsed time — `-12:34`.
    ///
    /// Five call sites wrote `"-\(formatTimestamp(x))"`, which the extractor
    /// reduces to the key `-%@`: one catalog entry, no comment, shared by every
    /// screen with a scrubber. The minus is also not as fixed as it looks —
    /// it is U+2212 in typographic settings and moves to the other side of the
    /// digits under an RTL layout — so it belongs in the catalog next to the
    /// argument it modifies, not in Swift.
    nonisolated static func remainingTimestamp(_ seconds: TimeInterval) -> String {
        String(localized: "format.duration.remainingTimestamp",
               defaultValue: "-\(timestamp(seconds))",
               comment: "Time left in the episode, shown opposite the elapsed time on a scrubber — e.g. '-12:34'. The argument is an already-formatted clock time; the leading minus means 'remaining'.")
    }

    /// A playback-rate readout — `1×`, `1.25×`, `1.5×`.
    ///
    /// Replaces `String(format:)` with `%.1f` and `%.2g`, which were wrong in
    /// two separate ways.
    ///
    /// **They lied about the rate.** Both round to two digits, so three of the
    /// nine presets rendered as a rate the app was not playing: `%.1f` showed
    /// 0.75 as `0.8`, 1.25 as `1.2`, 1.75 as `1.8`, and `%.2g` showed 1.25 as
    /// `1.2` and 1.75 as `1.8`. `fractionLength(0...2)` shows each preset
    /// exactly, and still writes 1.0 as `1` rather than `1.0`.
    ///
    /// **They hardcoded the English decimal point.** All five target languages
    /// write `1,5`. `.formatted` takes the separator from the locale;
    /// `String(format:)` never does.
    ///
    /// The `×` is U+00D7 MULTIPLICATION SIGN and lives in the catalog so a
    /// language that words its speed readout differently can move or replace
    /// it.
    ///
    /// `locale` exists so a test can pin the separator. Production always
    /// takes the default — a locale threaded through call sites is a locale
    /// someone eventually passes the wrong one to.
    nonisolated static func speed(_ rate: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = rate.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return String(localized: "format.speed.rate",
                      defaultValue: "\(number)×",
                      comment: "Playback speed readout, e.g. '1.5×'. The argument is an already-formatted number; '×' is U+00D7 MULTIPLICATION SIGN.")
    }

    /// The same rate spoken for VoiceOver — `1.5 times`.
    ///
    /// `×` is not read aloud usefully by the speech synthesiser, so the spoken
    /// form spells the word out and carries its own catalog entry.
    nonisolated static func spokenSpeed(_ rate: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = rate.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return String(localized: "a11y.speed.rate",
                      defaultValue: "\(number) times",
                      comment: "VoiceOver rendering of a playback speed, e.g. '1.5 times'. The argument is an already-formatted number.")
    }
}

import XCTest
@testable import YourPods

/// `DurationFormatting` replaces 13 private copies of the same clock
/// formatter. These tests pin the output byte-for-byte against what those
/// copies produced, because this refactor must not change a single character of
/// English UI — only where it lives.
final class DurationFormattingTests: XCTestCase {

    // MARK: - Clock (h:mm:ss / m:ss)

    func test_timestamp_matchesTheFormatterItReplaces() {
        let cases: [(TimeInterval, String)] = [
            (0, "0:00"),
            (5, "0:05"),
            (59, "0:59"),
            (60, "1:00"),
            (61, "1:01"),
            (599, "9:59"),
            (600, "10:00"),
            (3599, "59:59"),
            (3600, "1:00:00"),
            (3661, "1:01:01"),
            (36000, "10:00:00"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DurationFormatting.timestamp(input), expected,
                           "timestamp(\(input))")
        }
    }

    /// Every replaced copy clamped negatives to zero, or divided a negative
    /// into a nonsense string. Pin the clamp.
    func test_timestamp_clampsNegativeToZero() {
        XCTAssertEqual(DurationFormatting.timestamp(-1), "0:00")
        XCTAssertEqual(DurationFormatting.timestamp(-3600), "0:00")
    }

    /// EDGE: `.infinity` and `.nan` reach this from `AVPlayer` durations on a
    /// stalled stream. `Int(TimeInterval.nan)` traps, so the guard must be in
    /// the formatter, not at the call sites.
    func test_timestamp_survivesNonFiniteInput() {
        XCTAssertEqual(DurationFormatting.timestamp(.nan), "0:00")
        XCTAssertEqual(DurationFormatting.timestamp(.infinity), "0:00")
        XCTAssertEqual(DurationFormatting.timestamp(-.infinity), "0:00")
    }

    // MARK: - Callers that must not change output

    /// `NotesExportService.formatTime` writes into exported Markdown that
    /// lands on the user's disk and Nextcloud server. Its output is part of
    /// the file's content, not its identity, so a change is not data loss —
    /// but it is a silent diff in every note a user re-exports.
    func test_notesExportFormatTime_isIdenticalToSharedTimestamp() {
        for seconds in [0.0, 7.0, 59.0, 60.0, 3599.0, 3600.0, 7325.0] {
            XCTAssertEqual(NotesExportService.formatTime(seconds),
                           DurationFormatting.timestamp(seconds),
                           "notes export drifted from the shared formatter at \(seconds)s")
        }
    }

    /// `PlayerManager.formatTimestamp` is called from views and tests across
    /// the app. It stays as a forwarding shim; this pins that it forwards.
    func test_playerManagerFormatTimestamp_forwardsToSharedTimestamp() {
        for seconds in [0.0, 42.0, 3600.0, 7325.0] {
            XCTAssertEqual(PlayerManager.formatTimestamp(seconds),
                           DurationFormatting.timestamp(seconds))
        }
    }

    // MARK: - Countdown (minutes:seconds, no hour rollover)

    /// The sleep timer reads its total as minutes remaining and never rolls to
    /// hours — `SleepTimerManagerTests` pins `61:01` for 3661s. `countdown` is
    /// the shared home for that distinct formatter.
    func test_countdown_neverRollsOverToHours() {
        let cases: [(Int, String)] = [
            (0, "0:00"),
            (5, "0:05"),
            (60, "1:00"),
            (632, "10:32"),
            (3661, "61:01"),
            (7325, "122:05"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DurationFormatting.countdown(input), expected, "countdown(\(input))")
        }
    }

    func test_countdown_clampsNegativeToZero() {
        XCTAssertEqual(DurationFormatting.countdown(-1), "0:00")
    }

    // MARK: - Compact duration ("2h 5m")

    /// Pins the English rendering against `PlayerManager.formatDuration`, the
    /// one of the four copies with a test suite. Integer truncation at every
    /// boundary: 119s is `1m`, not `2m`.
    func test_compact_matchesTheFormattersItReplaces() {
        let cases: [(TimeInterval, String)] = [
            (0, "0s"),
            (59, "59s"),
            (60, "1m"),
            (119, "1m"),
            (3599, "59m"),
            (3600, "1h 0m"),
            (3660, "1h 1m"),
            (7325, "2h 2m"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DurationFormatting.compact(input), expected, "compact(\(input))")
        }
    }

    func test_compact_clampsNegativeAndNonFinite() {
        XCTAssertEqual(DurationFormatting.compact(-90), "0s")
        XCTAssertEqual(DurationFormatting.compact(.nan), "0s")
        XCTAssertEqual(DurationFormatting.compact(.infinity), "0s")
    }

    /// The hour form must carry both arguments, so a language that reorders
    /// them has something to reorder. Whether the catalog stores them
    /// positionally (`%1$lld`) is for the string-catalog parity guard to check — assert it
    /// here and you are asserting a Foundation implementation detail.
    func test_compact_hourForm_carriesBothArguments() {
        XCTAssertEqual(DurationFormatting.compact(7325), "2h 2m")
        XCTAssertEqual(DurationFormatting.compact(3600), "1h 0m",
                       "the zero-minute case must still render both units")
    }

    /// The shim in PlayerManager stays for its many callers.
    func test_playerManagerFormatDuration_forwardsToCompact() {
        for s in [0.0, 45.0, 300.0, 3600.0, 5400.0] {
            XCTAssertEqual(PlayerManager.formatDuration(s), DurationFormatting.compact(s))
        }
    }

    // MARK: - Spoken duration (VoiceOver)

    /// Pins the English rendering against `EpisodeAccessibility.spokenDuration`.
    /// The `== 1` singular forms must survive through catalog plural variations.
    func test_spoken_matchesTheFormatterItReplaces() {
        let cases: [(Int, String)] = [
            (0, "0 seconds"),
            (1, "1 second"),
            (2, "2 seconds"),
            (60, "1 minute"),
            (120, "2 minutes"),
            (3600, "1 hour"),
            (3660, "1 hour 1 minute"),
            (7320, "2 hours 2 minutes"),
            (7200, "2 hours"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DurationFormatting.spoken(input), expected, "spoken(\(input))")
        }
    }

    func test_spokenDuration_shimForwardsToShared() {
        for s in [0, 1, 59, 60, 3600, 7325] {
            XCTAssertEqual(EpisodeAccessibility.spokenDuration(s),
                           DurationFormatting.spoken(s))
        }
    }

    // MARK: - Relative time

    /// The bug this fixes: SwiftUI's `style: .relative` is unsigned, so a
    /// future timestamp reads exactly like a past one. `lastEpisodeActionSync`
    /// is a server epoch and clock skew is routine, so the UI asserted that a
    /// sync scheduled for the future had already happened.
    func test_relative_distinguishesPastFromFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-8000)
        let future = now.addingTimeInterval(8000)

        let pastText = DurationFormatting.relative(past, to: now)
        let futureText = DurationFormatting.relative(future, to: now)

        XCTAssertNotEqual(pastText, futureText,
            "past and future render identically — the unsigned .relative bug is back")
        XCTAssertTrue(pastText.contains("ago"), "expected a past-tense phrasing, got '\(pastText)'")
        XCTAssertFalse(futureText.contains("ago"), "future rendered as past: '\(futureText)'")
    }

    /// The suffix must come from the formatter, not be appended by a call
    /// site: German puts it in front ("vor 2 Stunden").
    func test_relative_producesACompletePhrase_notAFragment() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = DurationFormatting.relative(now.addingTimeInterval(-3600), to: now)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertFalse(text.hasSuffix(" "), "call sites must not need to append anything")
    }

    // MARK: - Progress phrasing

    func test_formatProgress_englishOutputIsUnchanged() {
        XCTAssertEqual(PlayerManager.formatProgress(position: 50, duration: 100), "50% listened")
        XCTAssertEqual(PlayerManager.formatProgress(position: 50, duration: 100, showPercent: false), "50% left")
        XCTAssertEqual(PlayerManager.formatProgress(position: 0, duration: 0), "0%")
    }

    /// "\(duration) left" appends an English word to a formatted number at
    /// four call sites. Splitting a sentence at the placeholder is the most
    /// common way a UI becomes untranslatable — the fragment order is fixed by
    /// the Swift source, where no translator can see it.
    func test_remainingPhrase_isASingleTemplate() {
        XCTAssertEqual(DurationFormatting.remaining(TimeInterval(3660)), "1h 1m left")
        XCTAssertEqual(DurationFormatting.remaining(TimeInterval(300)), "5m left")
    }

    // MARK: - Countdown timestamp

    /// Five scrubbers wrote `"-\(formatTimestamp(x))"`, which extracts as the
    /// key `-%@` — one catalog entry, no comment, shared by every screen.
    func test_remainingTimestamp_carriesTheSignAndTheClock() {
        XCTAssertEqual(DurationFormatting.remainingTimestamp(754), "-12:34")
        XCTAssertEqual(DurationFormatting.remainingTimestamp(3661), "-1:01:01")
        XCTAssertEqual(DurationFormatting.remainingTimestamp(0), "-0:00")
    }

    /// `AVPlayer` hands out `.nan` on a stalled stream, and `Int(.nan)` traps.
    func test_remainingTimestamp_survivesNonFiniteInput() {
        XCTAssertEqual(DurationFormatting.remainingTimestamp(.nan), "-0:00")
        XCTAssertEqual(DurationFormatting.remainingTimestamp(-5), "-0:00")
    }

    // MARK: - Playback speed

    /// The shipped bug this replaces: `%.1f` and `%.2g` both round to two
    /// digits, so three of the nine presets displayed a rate the app was not
    /// playing. `%.1f` rendered 0.75 as "0.8", 1.25 as "1.2", 1.75 as "1.8";
    /// `%.2g` rendered 1.25 as "1.2" and 1.75 as "1.8".
    func test_speed_showsEveryPresetExactly() {
        let en = Locale(identifier: "en_US")
        let presets: [(Double, String)] = [
            (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "1×"), (1.25, "1.25×"),
            (1.5, "1.5×"), (1.75, "1.75×"), (2.0, "2×"), (2.5, "2.5×"), (3.0, "3×"),
        ]
        for (rate, expected) in presets {
            XCTAssertEqual(DurationFormatting.speed(rate, locale: en), expected,
                           "\(rate)× must display as the rate actually in use")
        }
    }

    /// `String(format:)` writes the English decimal point under every locale.
    /// All five target languages write `1,5`.
    func test_speed_takesTheDecimalSeparatorFromTheLocale() {
        XCTAssertEqual(DurationFormatting.speed(1.25, locale: Locale(identifier: "de_DE")), "1,25×")
        XCTAssertEqual(DurationFormatting.speed(1.5, locale: Locale(identifier: "fr_FR")), "1,5×")
        XCTAssertEqual(DurationFormatting.speed(1.5, locale: Locale(identifier: "en_US")), "1.5×")
    }

    /// VoiceOver reads `×` as the character's Unicode name, so the spoken form
    /// spells the word and carries its own catalog entry.
    func test_spokenSpeed_saysTimesRatherThanTheGlyph() {
        let spoken = DurationFormatting.spokenSpeed(1.25, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(spoken, "1.25 times")
        XCTAssertFalse(spoken.contains("×"), "the multiplication sign does not belong in a spoken label")
    }
}

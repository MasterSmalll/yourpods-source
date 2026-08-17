import XCTest
@testable import YourPods

final class ChapterServiceTests: XCTestCase {
    
    func test_fetchAllChapters_returnsDescriptionChapters_whenUrlIsNil() async {
        let service = ChapterService.shared
        
        let chapters = await service.fetchAllChapters(
            chaptersUrl: nil,
            description: "(00:00) Chapter 1\n(05:00) Chapter 2"
        )
        
        XCTAssertEqual(chapters.count, 2, "Should fallback to description parsing and find 2 chapters")
    }
    
    func test_fetchAllChapters_returnsEmpty_whenBothNil() async {
        let service = ChapterService.shared

        let chapters = await service.fetchAllChapters(chaptersUrl: nil, description: nil)

        XCTAssertTrue(chapters.isEmpty, "Should return empty when both URL and description are nil")
    }

    // MARK: - Inline Podlove chaptersJSON
    //
    // Coverage gap this closes: every existing `fetchAllChapters` test above
    // omits `chaptersJSON` entirely, so the inline Podlove source — the only
    // source that carries `img` attributes for feeds using `psc:chapter`
    // instead of `podcast:chapters` — had zero coverage at this entry point.
    // CarPlayService and EpisodeDetailSheet route through this exact
    // method specifically to stop skipping this source, so it needs to be
    // pinned here independent of either call site.

    /// Two-chapter inline Podlove JSON, matching the wire shape
    /// `mapParsedEpisodeMetadata` persists (see `ChapterService
    /// .parseInlineChaptersJSON`'s doc comment): `[{"startTime", "title",
    /// "img", "url"}, ...]`.
    private static let inlineJSONFixture = #"""
        [
            {"startTime": 0.0, "title": "From JSON Intro", "img": "https://example.com/1.jpg", "url": null},
            {"startTime": 30.0, "title": "From JSON Segment", "img": null, "url": null}
        ]
        """#

    func test_fetchAllChapters_usesInlineJSON_whenChaptersUrlIsNil() async {
        let chapters = await ChapterService.shared.fetchAllChapters(
            chaptersUrl: nil,
            chaptersJSON: Self.inlineJSONFixture,
            description: nil
        )

        XCTAssertEqual(chapters.count, 2, "Should parse the inline Podlove JSON source")
        XCTAssertEqual(chapters[0].title, "From JSON Intro")
        XCTAssertEqual(chapters[0].img, "https://example.com/1.jpg",
                        "img must survive — it's the only source carrying Podlove chapter art")
    }

    func test_fetchAllChapters_usesInlineJSON_whenChaptersUrlIsEmptyString() async {
        let chapters = await ChapterService.shared.fetchAllChapters(
            chaptersUrl: "",
            chaptersJSON: Self.inlineJSONFixture,
            description: nil
        )

        XCTAssertEqual(chapters.count, 2, "An empty (not nil) chaptersUrl must still fall through to inline JSON")
    }

    func test_fetchAllChapters_prefersInlineJSON_overDescription_whenBothPresent() async {
        let chapters = await ChapterService.shared.fetchAllChapters(
            chaptersUrl: nil,
            chaptersJSON: Self.inlineJSONFixture,
            description: "(00:00) From Description A\n(10:00) From Description B"
        )

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "From JSON Intro",
                        "Inline JSON must win over description parsing when both are present")
        XCTAssertEqual(chapters[1].title, "From JSON Segment")
    }

    func test_fetchAllChapters_fallsBackToDescription_whenInlineJSONParsesToZeroChapters() async {
        let chapters = await ChapterService.shared.fetchAllChapters(
            chaptersUrl: nil,
            chaptersJSON: "[]",
            description: "(00:00) Chapter 1\n(05:00) Chapter 2"
        )

        XCTAssertEqual(chapters.count, 2, "An inline JSON source present but empty must still fall through to description")
        XCTAssertEqual(chapters[0].title, "Chapter 1")
    }

    // MARK: - Regression guard: CarPlayService / EpisodeDetailSheet
    // must not reintroduce the hand-rolled partial chain
    //
    // Both files used to call `ChapterService.shared.fetchChapters(url:)`
    // directly, then fall straight to description parsing — silently
    // skipping the inline `chaptersJSON` source above. That made
    // Podlove-only feeds (psc:chapter, no podcast:chapters) show no chapters
    // at all in CarPlay or the episode detail sheet. Both were fixed to
    // route through `fetchAllChapters(...)` (EpisodeDetailSheet) or
    // `ChapterCoordinator.visibleChapters` (CarPlayService), both of which
    // include the inline source. This is a source-scan guard test, following
    // the pattern established by `AVAssetSyncAccessGuardTests`
    // (`isViolation`/`violations(in:)` extracted into a static function the
    // test calls, rather than reimplementing the scan inline in the test).

    /// True iff `source` calls the partial `ChapterService.shared
    /// .fetchChapters(url:)` entry point directly — the exact hand-rolled
    /// chain that replaced it. Deliberately narrow: it matches only the
    /// `.shared.`-qualified external call. `ChapterService.swift`'s own
    /// `fetchAllChapters(...)` reaches `fetchChapters(url:)` as an UNqualified
    /// instance call, which this pattern does not match, so that file is
    /// scanned like any other with no risk of a false positive — no by-name
    /// exclusion needed.
    ///
    /// Drops any line whose TRIMMED PREFIX starts with `//` before matching
    /// — same rationale as `AVAssetSyncAccessGuardTests.isViolation`: a
    /// banned call named only in EXPLANATORY PROSE (e.g. this very file's
    /// own doc comments on `CarPlayService.swift`'s fix, which name the old
    /// bad call to explain what changed) must never be mistaken for the real
    /// thing. Caught in practice, not just in theory: an earlier version of
    /// this function had no comment-stripping and flagged CarPlayService.swift's
    /// own explanatory `// ... ChapterService.shared.fetchChapters(url:) ...`
    /// doc comment as a violation.
    ///
    /// Deliberately a line-PREFIX check, not the mid-line
    /// `components(separatedBy: "//").first` this function used before
    /// (review finding): splitting on the
    /// first `//` ANYWHERE in a line truncates at one inside a string
    /// literal too — a line like `let u = "https://e.g"; await
    /// ChapterService.shared.fetchChapters(url: u)` would have its real
    /// violation silently discarded along with everything after the `//` in
    /// `https://`, a false negative in a guard whose entire job is to not
    /// miss things. The prefix check never truncates mid-line, so that shape
    /// is now caught (see the scanner self-check below). Known, accepted
    /// gap in the other direction, same class `AVAssetSyncAccessGuardTests`
    /// already accepts for its own line scanner: a trailing `//` comment on
    /// an otherwise-real code line, and any `/* … */` block comment, are not
    /// specially handled — not worth a general-purpose parser for a guard
    /// that scans two source directories.
    static func reintroducesPartialChapterChain(_ source: String) -> Bool {
        let codeOnly = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return codeOnly.contains("ChapterService.shared.fetchChapters(url:")
    }

    func test_reintroducesPartialChapterChain_flagsKnownBadCall() {
        XCTAssertTrue(Self.reintroducesPartialChapterChain(
            "chapters = await ChapterService.shared.fetchChapters(url: chaptersUrl)"),
            "must flag the exact hand-rolled call that was removed")
    }

    func test_reintroducesPartialChapterChain_doesNotFlagFullChain() {
        XCTAssertFalse(Self.reintroducesPartialChapterChain(
            "chapters = await ChapterService.shared.fetchAllChapters(chaptersUrl: url, chaptersJSON: json, description: desc)"),
            "must not flag the full-chain call that replaced it")
    }

    func test_reintroducesPartialChapterChain_doesNotFlagExplanatoryComment() {
        XCTAssertFalse(Self.reintroducesPartialChapterChain(
            "    // the old chain called ChapterService.shared.fetchChapters(url:) then description parsing"),
            "a banned call named only in a prose comment explaining the fix must not be flagged")
    }

    func test_reintroducesPartialChapterChain_flagsBannedCallAfterURLLiteralOnSameLine() {
        // The exact false-negative shape from the review finding: a
        // "https://…" literal appears BEFORE the real violation on the same
        // line. The old `components(separatedBy: "//").first` implementation
        // found the "//" inside "https://" first and discarded everything
        // after it — including the genuine banned call — so this line
        // passed undetected. Verified red against that implementation and
        // green against this one.
        XCTAssertTrue(Self.reintroducesPartialChapterChain(
            #"let u = "https://example.com"; let c = await ChapterService.shared.fetchChapters(url: u)"#),
            "a // inside a string literal earlier on the line must not truncate away a real violation later on the line")
    }

    /// Roots to scan, each paired with a sanity floor for its real `.swift`
    /// file count — set well below the real count and well above "a few,"
    /// so a scanner silently misrooted to one leaf folder (or the wrong root
    /// entirely) can't pass by finding a handful of files instead of zero.
    /// Real counts at the time this test was written: 47 under
    /// YourPods/YourPods/Views, 65 under YourPods/YourPods/Services
    /// (ChapterService.swift is scanned like every other file — the
    /// `.shared.`-qualified pattern never matches its unqualified internal
    /// call, so it needs no exclusion). Widened from the
    /// original two-hard-coded-file list (review finding) because a
    /// reintroduction in any OTHER view or service —
    /// HomeView.swift, SiriIntentHandler.swift, a new file added later —
    /// was invisible to that list.
    private func chapterChainScanRoots() -> [(root: URL, floor: Int)] {
        var repoRoot = URL(fileURLWithPath: #filePath)  // …/YourPodsTests/ChapterServiceTests.swift
        repoRoot.deleteLastPathComponent()               // …/YourPodsTests
        repoRoot.deleteLastPathComponent()               // repo root
        return [
            (repoRoot.appendingPathComponent("YourPods/YourPods/Views"), 20),
            (repoRoot.appendingPathComponent("YourPods/YourPods/Services"), 30),
        ]
    }

    func test_noViewOrServiceReintroducesPartialChapterChain() throws {
        var violations: [String] = []

        for (root, floor) in chapterChainScanRoots() {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []

            XCTAssertFalse(files.isEmpty, "source scan found no files under \(root.path) — chapterChainScanRoots() is wrong")
            XCTAssertGreaterThan(files.count, floor,
                "found only \(files.count) .swift files under \(root.path) — implausibly low, chapterChainScanRoots() is likely misrooted")

            for file in files {
                // Non-optional `try`, not `try?`: a file enumerated from disk
                // that then fails to read as UTF-8 should error this test,
                // not be silently skipped.
                let contents = try String(contentsOf: file, encoding: .utf8)
                if Self.reintroducesPartialChapterChain(contents) {
                    violations.append(file.path)
                }
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            Reintroduced the hand-rolled ChapterService.shared.fetchChapters(url:) \
            chain, which skips inline Podlove chaptersJSON. Route through \
            fetchAllChapters(...) or ChapterCoordinator.visibleChapters instead.

            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - Regression guard (review finding): CarPlayService's connection
    // to ChapterCoordinator must stay wired in the composition root
    //
    // `CarPlayService.chapterCoordinator` is a `weak var ChapterCoordinator?`
    // (CarPlayService.swift) — CarPlayService is a singleton and can't take
    // constructor args, so property injection is the only option, same
    // pattern as its other weak-var dependencies. `YourPodsApp.swift`'s
    // `CarPlayService.shared.chapterCoordinator = chapterCoord` assignment is
    // the ONLY thing that connects the two. Because the property is
    // optional, nothing enforces the wiring at compile time: delete the
    // assignment or rename either side and `chapterCoordinator` stays nil.
    // (Reordering the assignment above `let chapterCoord = ...` is NOT in
    // this set — that one the compiler catches, "use of local variable
    // before its declaration"; the scan is only needed for the failures the
    // compiler can't see.) `seekToPreviousChapter`/`seekToNextChapter`
    // (CarPlayService.swift) then
    // hit their `guard let chapters = chapterCoordinator?.visibleChapters`
    // and return with only a `logger.debug` — CarPlay chapter navigation
    // dies silently, in the car, where nobody reads logs.
    //
    // This is a source-scan guard, not a runtime one: a `@MainActor` test
    // asserting `CarPlayService.shared.chapterCoordinator != nil` after
    // composition was considered, but there is no way to actually exercise
    // `YourPodsApp`'s composition root from a unit test without instantiating
    // the App scene, so such a test could only ever assert that the property
    // is settable (trivially true, already enforced by the type checker) —
    // it would not prove YourPodsApp.swift itself still performs the
    // assignment, and it would mutate `CarPlayService.shared` — a leaked
    // singleton write another test could observe. The source scan proves the
    // one thing that actually matters: the composition-root line still
    // exists in YourPodsApp.swift.

    /// True iff `source` contains the composition-root assignment that wires
    /// `CarPlayService.shared.chapterCoordinator`. See the MARK above for why
    /// this exists and why a runtime test was rejected.
    ///
    /// Drops any line whose trimmed prefix starts with `//` before matching,
    /// same as `reintroducesPartialChapterChain` above — found necessary
    /// empirically, not just for symmetry: a first version did a bare
    /// `.contains(...)` with no comment-stripping, and the red-proof for
    /// this guard commented the real
    /// assignment out rather than deleting it — the commented-out line
    /// still contained the exact substring, so the naive check stayed
    /// green on a config that wires nothing at runtime. Without stripping,
    /// a future edit that comments the assignment out (e.g. "temporarily
    /// disabling CarPlay chapters") would pass this guard while genuinely
    /// breaking CarPlay chapter navigation.
    static func wiresCarPlayChapterCoordinator(_ source: String) -> Bool {
        let codeOnly = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return codeOnly.contains("CarPlayService.shared.chapterCoordinator =")
    }

    func test_wiresCarPlayChapterCoordinator_flagsPresentAssignment() {
        XCTAssertTrue(Self.wiresCarPlayChapterCoordinator(
            "CarPlayService.shared.chapterCoordinator = chapterCoord"),
            "must flag the real composition-root assignment")
    }

    func test_wiresCarPlayChapterCoordinator_doesNotFlagOtherCarPlayWiring() {
        XCTAssertFalse(Self.wiresCarPlayChapterCoordinator(
            "CarPlayService.shared.podcastManager = podcast"),
            "must not flag unrelated CarPlayService property wiring")
    }

    func test_wiresCarPlayChapterCoordinator_doesNotFlagCommentedOutAssignment() {
        XCTAssertFalse(Self.wiresCarPlayChapterCoordinator(
            "        // CarPlayService.shared.chapterCoordinator = chapterCoord"),
            "a commented-out assignment wires nothing at runtime and must not be treated as present")
    }

    func test_carPlayServiceChapterCoordinatorWiring_isPresentInAppComposition() throws {
        var repoRoot = URL(fileURLWithPath: #filePath)  // …/YourPodsTests/ChapterServiceTests.swift
        repoRoot.deleteLastPathComponent()               // …/YourPodsTests
        repoRoot.deleteLastPathComponent()               // repo root

        let file = repoRoot.appendingPathComponent("YourPods/YourPods/YourPodsApp.swift")
        // Non-optional `try`, not `try?`: if this file is ever moved or
        // renamed, the test must error rather than silently pass with an
        // empty/missing contents string.
        let contents = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(Self.wiresCarPlayChapterCoordinator(contents), """
            YourPodsApp.swift no longer wires \
            CarPlayService.shared.chapterCoordinator. That property is a weak \
            var — without this composition-root assignment it stays nil and \
            seekToPreviousChapter/seekToNextChapter (CarPlayService.swift) \
            silently no-op (guard + logger.debug only). CarPlay chapter \
            navigation would die silently, in the car.
            """)
    }

    // MARK: - Parenthesized Timestamps (existing format)
    
    func test_parseChaptersFromDescription_supportsParenTimestamps() {
        let text = "(00:00) Introduction\n(05:48) Main Topic\n(12:00) Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[1].title, "Main Topic")
        XCTAssertEqual(chapters[1].startTime, 348)  // 5*60 + 48
        XCTAssertEqual(chapters[2].title, "Wrap Up")
        XCTAssertEqual(chapters[2].startTime, 720)
    }
    
    func test_parseChaptersFromDescription_supportsBareTimestamps() {
        let text = "00:00 Introduction\n05:30 Main Topic\n12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Main Topic")
        XCTAssertEqual(chapters[1].startTime, 330)
    }
    
    func test_parseChaptersFromDescription_supportsDashSeparator() {
        let text = "00:00 - Introduction\n05:30 - Main Topic\n12:00 - Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Main Topic")
    }
    
    func test_parseChaptersFromDescription_supportsHHMMSS() {
        let text = "(0:00:00) Start\n(1:02:30) Part Two\n(2:15:00) Finale"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[1].startTime, 3750)  // 1*3600 + 2*60 + 30
        XCTAssertEqual(chapters[2].startTime, 8100)  // 2*3600 + 15*60
    }
    
    // MARK: - Square Bracket Timestamps (Tim Ferriss format)
    
    func test_parseChaptersFromDescription_supportsBracketTimestamps() {
        // GIVEN: Episode description with [MM:SS] bracket format (Tim Ferriss Show)
        let text = "[00:00] Introduction\n[05:30] Main Topic\n[12:00] Wrap Up"
        
        // WHEN: Parsing chapters
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // THEN: All 3 chapters are found with clean titles (no bracket leakage)
        XCTAssertEqual(chapters.count, 3, "Should parse [MM:SS] bracket timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction",
                       "Title must not contain ] bracket prefix")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[1].title, "Main Topic")
        XCTAssertEqual(chapters[1].startTime, 330)  // 5:30
        XCTAssertEqual(chapters[2].title, "Wrap Up")
        XCTAssertEqual(chapters[2].startTime, 720)  // 12:00
        // Explicit check: no bracket contamination
        XCTAssertFalse(chapters[0].title.hasPrefix("]"),
                       "Closing bracket must not leak into chapter title")
    }
    
    func test_parseChaptersFromDescription_supportsMixedBracketAndParenTimestamps() {
        // GIVEN: Mix of bracket and paren formats
        let text = "[00:00] Intro\n(05:00) Middle\n[10:00] End"
        
        // WHEN: Parsing
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // THEN: All found
        XCTAssertEqual(chapters.count, 3, "Should handle mixed bracket and paren formats")
    }
    
    func test_parseChaptersFromDescription_supportsHHMMSSBrackets() {
        // GIVEN: Bracketed HH:MM:SS format
        let text = "[0:00:00] Start\n[1:02:30] Part Two\n[2:15:00] Finale"
        
        // WHEN: Parsing
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // THEN: Correct times
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[1].startTime, 3750)  // 1*3600 + 2*60 + 30
    }
    
    // MARK: - Bullet / List Prefix Timestamps
    
    func test_parseChaptersFromDescription_supportsBulletPrefix() {
        // GIVEN: Bullet-prefixed timestamps (common in show notes)
        let text = "• 00:00 Introduction\n• 05:30 Main Topic\n• 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse bullet-prefixed timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Main Topic")
    }
    
    func test_parseChaptersFromDescription_supportsDashPrefixedTimestamps() {
        // GIVEN: Dash used as a list marker before the timestamp
        let text = "- 00:00 Introduction\n- 05:30 Main Topic\n- 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse dash-prefixed list timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_supportsAsteriskPrefix() {
        // GIVEN: Markdown-style asterisk list
        let text = "* 00:00 Introduction\n* 05:30 Main Topic\n* 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse asterisk-prefixed timestamps")
    }
    
    func test_parseChaptersFromDescription_supportsNumberedList() {
        // GIVEN: Numbered list before timestamps
        let text = "1. 00:00 Introduction\n2. 05:30 Main Topic\n3. 12:00 Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse numbered list timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    // MARK: - Separator Variants
    
    func test_parseChaptersFromDescription_supportsColonSeparator() {
        // GIVEN: Colon between timestamp and title
        let text = "00:00: Introduction\n05:30: Main Topic\n12:00: Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse colon-separated timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_supportsEmDashSeparator() {
        // GIVEN: Em-dash separator
        let text = "00:00 — Introduction\n05:30 — Main Topic\n12:00 — Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse em-dash-separated timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_supportsPipeSeparator() {
        // GIVEN: Pipe separator
        let text = "00:00 | Introduction\n05:30 | Main Topic\n12:00 | Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse pipe-separated timestamps")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    // MARK: - Real-world Descriptions
    
    func test_parseChaptersFromDescription_timFerrissFormat() {
        // GIVEN: Real Tim Ferriss Show format with brackets and HH:MM:SS
        let text = """
        Please enjoy this conversation with Dr. Andrew Huberman.
        
        [00:00] Introduction
        [06:12] The Science of Sleep
        [18:45] Cold Exposure Protocols
        [35:20] Dopamine and Motivation
        [1:02:30] Morning Routine Optimization
        [1:25:00] Closing Thoughts
        """
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 6, "Should parse Tim Ferriss bracket format")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[4].title, "Morning Routine Optimization")
        XCTAssertEqual(chapters[4].startTime, 3750)  // 1*3600 + 2*60 + 30
        XCTAssertEqual(chapters[5].title, "Closing Thoughts")
        XCTAssertEqual(chapters[5].startTime, 5100)  // 1*3600 + 25*60
    }
    
    func test_parseChaptersFromDescription_lexFridmanFormat() {
        // GIVEN: Lex Fridman style — bare timestamps with dash separators
        let text = """
        0:00 - Introduction
        2:23 - What is consciousness?
        15:40 - The hard problem
        1:05:12 - AI and the future
        2:30:00 - Meaning of life
        """
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 5, "Should parse Lex Fridman format")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[3].title, "AI and the future")
        XCTAssertEqual(chapters[3].startTime, 3912)  // 1*3600 + 5*60 + 12
    }
    
    func test_parseChaptersFromDescription_htmlDescription() {
        // GIVEN: HTML-formatted description with timestamps
        let text = """
        <p>Show notes:</p>
        <p>[00:00] Introduction</p>
        <p>[05:30] Main Topic</p>
        <p>[12:00] Wrap Up</p>
        """
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should parse timestamps from HTML descriptions")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    func test_parseChaptersFromDescription_bracketTimestampWithDash() {
        // GIVEN: Brackets with dash separator (hybrid format)
        let text = "[00:00] - Introduction\n[05:30] - Main Topic\n[12:00] - Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
    
    // MARK: - Edge Cases
    
    func test_parseChaptersFromDescription_singleTimestamp_returnsEmpty() {
        // A single timestamp isn't useful as chapters
        let text = "[00:00] Introduction"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertTrue(chapters.isEmpty, "Single timestamp should return empty")
    }
    
    func test_parseChaptersFromDescription_noTimestamps_returnsEmpty() {
        let text = "This is a normal description without timestamps."
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertTrue(chapters.isEmpty)
    }
    
    func test_parseChaptersFromDescription_urlsNotTreatedAsChapters() {
        // URLs after timestamps should be filtered out
        let text = "00:00 Introduction\n05:00 http://example.com\n10:00 Conclusion"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        // Should skip the URL line
        XCTAssertEqual(chapters.count, 2, "URLs should be filtered out")
        XCTAssertEqual(chapters[0].title, "Introduction")
        XCTAssertEqual(chapters[1].title, "Conclusion")
    }
    
    func test_parseChaptersFromDescription_combinedPrefixAndBrackets() {
        // GIVEN: Bullet + bracket combo
        let text = "• [00:00] Introduction\n• [05:30] Main Topic\n• [12:00] Wrap Up"
        
        let chapters = ChapterService.parseChaptersFromDescription(text)
        
        XCTAssertEqual(chapters.count, 3, "Should handle bullet + bracket combination")
        XCTAssertEqual(chapters[0].title, "Introduction")
    }
}

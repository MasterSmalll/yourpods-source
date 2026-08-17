import XCTest

/// Guards against synchronous AVAsset property access.
///
/// On iOS 26 the synchronous getters (`duration`, `availableChapterLocales`,
/// `availableMetadataFormats`, `commonMetadata`, `tracks`) each perform an XPC
/// round-trip to mediaserverd that returns only after an internal ~20 second
/// timeout for indefinite-duration assets. Instruments records a single
/// "Severe Hang, 20.11 s"; backgrounding during the freeze gets the app
/// watchdog-killed with 0x8BADF00D.
///
/// THE SIMULATOR DOES NOT REPRODUCE THIS. /sim-verify shows green. A source
/// scan is the only enforcement that actually runs — same rationale as
/// `WidgetInteractivityGuardTests`.
///
/// Upstream: SwiftAudioEx #105, react-native-track-player #2665 (both opened
/// 2026-07-17).
///
/// Scope: `YourPods/YourPods` (the shipping app target) AND `YourPodsTests`.
/// The hang itself is a real-device, real-`mediaserverd` concern test code
/// never triggers, but a sync access written in a test is exactly the kind
/// of thing a future edit copies into product code, so it's worth catching
/// there too — the maintenance cost of doing so is zero: `isViolation` is
/// proven correct against the real `asset?.url` lines in
/// `EmbeddedChapterExtractorTests.swift` (`test_scannerCases`, the `.url`
/// rows), so that legitimate pattern is never a false positive. This test's
/// own file is excluded from the scan by name — see `sourceRoots()` — since
/// it necessarily embeds banned-accessor shapes as string-literal fixtures
/// for `isViolation`/`violations(in:)` to examine, and scanning those
/// fixtures would be a category error, not a real hit.
final class AVAssetSyncAccessGuardTests: XCTestCase {

    // MARK: - Scanner
    //
    // Extracted into static functions (rather than re-expressed inline in
    // each test) so the real file scan below and the scanner self-checks
    // exercise the exact same decision logic — a test that re-derives its own
    // copy of "what counts as a violation" can drift from the real scanner
    // and keep passing while the real one rots.

    /// Deprecated synchronous AVAsset properties. Each must be reached via
    /// `try await asset.load(.property)` instead.
    ///
    /// `.url` is deliberately NOT in this list: `AVURLAsset.url` is a stored
    /// property set at init — no XPC round-trip, no hang risk. Adding it
    /// "for completeness" would turn `asset?.url` (used throughout
    /// `EmbeddedChapterExtractorTests.swift`) into a false positive on
    /// correct code.
    private static let bannedAccessors = [
        ".duration",
        ".availableChapterLocales",
        ".availableMetadataFormats",
        ".commonMetadata",
        ".metadata",
        ".tracks",
        ".chapterMetadataGroups",
        // Subsumed by ".metadata" above (every line matching this also
        // matches that — "asset.metadata(forFormat" starts with
        // "asset.metadata"), kept anyway to name the real synchronous API
        // (`AVAsset.metadata(forFormat:)`) explicitly for readers.
        ".metadata(forFormat",
    ]

    /// True iff `rawLine` synchronously reads a banned accessor off (a) a
    /// value literally named `asset`/`Asset` (or an `...asset`/`...Asset`-
    /// suffixed compound name, e.g. `downloadedAsset`), reached directly,
    /// through `?.`, or through `!.`, or (b) the result of a call whose name
    /// ends in `Asset(...)` — a factory or initializer — chained off
    /// directly, through `?.`/`!.`, or bare `.`. Either shape is exempt when
    /// reached through the correct `.load(...)` async form instead.
    ///
    /// Pipeline, in order:
    /// 1. Strip a trailing `//` line comment, so a banned name mentioned
    ///    only in prose after real code (or a fully commented-out `//`/`///`
    ///    line) is never mistaken for a violation.
    /// 2. Strip every `.load(...)` call SPAN (balanced-paren aware, via
    ///    `stripLoadCallSpans`), not just exempt the whole line for
    ///    containing one. `let d = (try? await asset.load(.duration)) ??
    ///    asset.duration` — a plausible graceful-fallback shape under this
    ///    repo's "log and continue" convention — has both a correct async
    ///    load AND a genuine sync violation on the same line; a line-wide
    ///    `contains(".load(")` exemption couldn't tell those apart and would
    ///    wave the whole line through. Stripping the call's own span (not
    ///    just checking for the substring "load(", which `download(`/
    ///    `reload(`/`preload(` would also satisfy) removes exactly the
    ///    correct-form text and leaves any other access on the line to be
    ///    judged on its own.
    /// 3. Fold `asset?.` / `asset!.` / `Asset?.` / `Asset!.` (optional
    ///    chaining and force-unwrap) to a plain `asset.`/`Asset.` before
    ///    matching. Both are the same plausibility class and the same root
    ///    cause: `EmbeddedChapterExtractor.makeAsset(for:)` returns
    ///    `AVURLAsset?`; the real code unwraps with `guard let` first, but
    ///    nothing stops a future edit from reading straight off the
    ///    optional instead, either with `?.` or a force-unwrapping `!.`.
    ///    This is also what makes `asset?.url` a real (not just
    ///    theoretical) exercise of the `.url` exemption above.
    /// 4. Check the direct-value shape (`asset.<accessor>`/
    ///    `...Asset.<accessor>`), then the chained-off-a-call shape via
    ///    `hasChainedCallViolation` — `makeAsset(for: episode)?.duration`
    ///    never binds to a value named `asset` at all, and
    ///    `AVURLAsset(url: someURL).duration` chains directly off a type
    ///    initializer the same way `AudioManager.swift:710-711` constructs
    ///    one inline. Both shapes are how a factory/initializer returning
    ///    the asset is designed to be used, so both need their own check —
    ///    the direct-value substring check can't see either, since neither
    ///    line contains `asset.`/`Asset.` as literal adjacent text.
    ///
    /// Known limitations (line-based, substring-based scanning, same
    /// tradeoff class `WidgetInteractivityGuardTests` already accepts for
    /// its own brace/paren counters):
    /// - **Misses**, not string-literal-aware: a `/*`/`//` inside a string
    ///   literal earlier on a line is misread as real comment syntax,
    ///   hiding a genuine violation after it. None of the files this scan
    ///   currently covers hardcode a `://` or `/*` literal on a line with
    ///   `asset.`/`Asset.`.
    /// - **False flags**, same root cause in the other direction: a banned
    ///   name inside an unrelated STRING literal reads as a violation —
    ///   `Logger.audio.debug("never read asset.duration")` would be
    ///   flagged even though it names nothing at runtime.
    /// - Multi-line chains (`let d = asset\n    .duration`) and
    ///   whitespace-separated access (`asset .duration`) are invisible to a
    ///   line-based scanner entirely.
    /// None of these were judged worth real string-literal-aware lexing for
    /// a guard test that should stay simple enough to trust at a glance;
    /// each is a known, accepted gap, not an oversight.
    private static func isViolation(_ rawLine: String) -> Bool {
        let codeOnly = rawLine.components(separatedBy: "//").first ?? rawLine
        let withoutLoadCalls = stripLoadCallSpans(codeOnly)
        let trimmed = withoutLoadCalls
            .replacingOccurrences(of: "asset?.", with: "asset.")
            .replacingOccurrences(of: "asset!.", with: "asset.")
            .replacingOccurrences(of: "Asset?.", with: "Asset.")
            .replacingOccurrences(of: "Asset!.", with: "Asset.")
            .trimmingCharacters(in: .whitespaces)

        if trimmed.contains("asset.") || trimmed.contains("Asset.") {
            let directHit = bannedAccessors.contains {
                trimmed.contains("asset\($0)") || trimmed.contains("Asset\($0)")
            }
            if directHit { return true }
        }

        return hasChainedCallViolation(in: trimmed)
    }

    /// Character-exact match of `literal` in `chars` starting at `index`.
    /// Shared by `stripLoadCallSpans` and `hasChainedCallViolation`, both of
    /// which need to find a fixed marker and then walk its balanced parens.
    private static func matches(_ chars: [Character], at index: Int, _ literal: String) -> Bool {
        let lit = Array(literal)
        guard index + lit.count <= chars.count else { return false }
        for offset in 0..<lit.count where chars[index + offset] != lit[offset] { return false }
        return true
    }

    /// Removes every `.load( ... )` call span (balanced-paren aware) from
    /// `line` — see point 2 of `isViolation`'s doc comment for why this is a
    /// surgical strip rather than a line-wide exemption.
    private static func stripLoadCallSpans(_ line: String) -> String {
        var result = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if matches(chars, at: i, ".load(") {
                var j = i + ".load(".count
                var depth = 1
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                i = j
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// True iff `line` reads a banned member directly off the result of a
    /// call whose name ends in `Asset(` — see point 4 of `isViolation`'s doc
    /// comment. Walks each `Asset(` occurrence to its balanced closing
    /// paren, then checks whether what immediately follows (through an
    /// optional `?`/`!`) is a banned accessor.
    private static func hasChainedCallViolation(in line: String) -> Bool {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if matches(chars, at: i, "Asset(") {
                var j = i + "Asset(".count
                var depth = 1
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                var k = j
                if k < chars.count, chars[k] == "?" || chars[k] == "!" { k += 1 }
                if k < chars.count, chars[k] == "." {
                    let rest = String(chars[(k + 1)...])
                    if bannedAccessors.contains(where: { rest.hasPrefix(String($0.dropFirst())) }) {
                        return true
                    }
                }
                i = j
                continue
            }
            i += 1
        }
        return false
    }

    /// Removes `/* ... */` block comments from `source` (nesting-aware),
    /// preserving every newline — including ones inside a stripped comment —
    /// so line numbers computed from the result still line up with the
    /// original file. Without this, a banned accessor name used to explain
    /// the rule inside a block comment (a legitimate thing to write) would
    /// be indistinguishable from the violation it's describing.
    ///
    /// Known limitation, same class already accepted by
    /// `WidgetInteractivityGuardTests`'s own brace/paren counters: this does
    /// not understand string literals, so a `/*` inside a string would be
    /// misread as a comment start. None of the files this scan currently
    /// covers contain such a literal.
    private static func stripBlockComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var depth = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                depth += 1
                i += 2
                continue
            }
            if depth > 0, chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                depth -= 1
                i += 2
                continue
            }
            if depth > 0 {
                if chars[i] == "\n" { result.append("\n") }
                i += 1
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// One violation per matching line in `source`, 1-indexed to match how
    /// editors/Xcode report line numbers. A struct rather than a plain tuple
    /// so it's `Equatable` — `XCTAssertEqual` on a bare tuple array doesn't
    /// compile, Swift does not synthesize `Equatable` for tuples.
    struct Violation: Equatable {
        let line: Int
        let text: String
    }

    private static func violations(in source: String) -> [Violation] {
        stripBlockComments(source)
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, line in
                isViolation(line) ? Violation(line: index + 1, text: line.trimmingCharacters(in: .whitespaces)) : nil
            }
    }

    /// True iff a file's contents are worth line-scanning at all. `AVAsset`/
    /// `AVURLAsset` catches files that name the type; `AVFoundation` catches
    /// files that only get an asset from a call whose return type is
    /// inferred (`guard let asset = EmbeddedChapterExtractor.makeAsset(for:
    /// episode) else { ... }` never spells the type in its own text) — the
    /// import is mandatory either way, so this costs nothing.
    private static func isScannable(_ contents: String) -> Bool {
        contents.contains("AVAsset") || contents.contains("AVURLAsset") || contents.contains("AVFoundation")
    }

    // MARK: - Invariant: real app + test sources

    /// This file's own name — excluded from the scan below. It necessarily
    /// embeds banned-accessor shapes as string-literal fixtures (see
    /// `scannerCases` and the block-comment tests): a naive line scanner
    /// can't distinguish "this text is a Swift string literal representing
    /// a violation for a test" from "this text is a real violation," so
    /// scanning this file's own source would flag its own test fixtures.
    private static let excludedFileName = "AVAssetSyncAccessGuardTests.swift"

    /// Roots to scan, each paired with a sanity floor for its real `.swift`
    /// file count — set well below the real count and well above "a few,"
    /// so a scanner silently misrooted to one leaf folder (or the wrong root
    /// entirely) can't pass by finding a handful of files instead of zero.
    /// Real counts at the time this test was written: 171 under
    /// `YourPods/YourPods`, 259 under `YourPodsTests`.
    private func sourceRoots() throws -> [(root: URL, floor: Int)] {
        var repoRoot = URL(fileURLWithPath: #filePath)   // …/YourPodsTests/ThisFile.swift
        repoRoot.deleteLastPathComponent()               // …/YourPodsTests
        repoRoot.deleteLastPathComponent()               // repo root
        return [
            (repoRoot.appendingPathComponent("YourPods/YourPods"), 50),
            (repoRoot.appendingPathComponent("YourPodsTests"), 100),
        ]
    }

    func test_noSynchronousAVAssetPropertyAccess() throws {
        var violations: [String] = []

        for (root, floor) in try sourceRoots() {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != Self.excludedFileName } ?? []

            XCTAssertFalse(files.isEmpty, "source scan found no files under \(root.path) — sourceRoots() is wrong")
            XCTAssertGreaterThan(files.count, floor,
                "found only \(files.count) .swift files under \(root.path) — implausibly low, sourceRoots() is likely misrooted")

            for file in files {
                guard let contents = try? String(contentsOf: file, encoding: .utf8),
                      Self.isScannable(contents) else { continue }

                for violation in Self.violations(in: contents) {
                    violations.append("\(root.lastPathComponent)/\(file.lastPathComponent):\(violation.line): \(violation.text)")
                }
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            Synchronous AVAsset property access found. On iOS 26 these hang the \
            main thread ~20s and can be watchdog-killed (0x8BADF00D). The \
            Simulator does not reproduce it. Use `try await asset.load(.property)`.

            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - Scanner self-checks (prove the detector can fail)
    //
    // "A guard that cannot fail is not evidence" — these exercise the exact
    // `isViolation`/`violations(in:)` functions the real scan above calls,
    // not a re-expressed copy of the matching logic. Table-driven (one row
    // per shape) rather than one method per shape: every explanatory comment
    // lives in the `reason` column, and adding a new shape is a one-row edit.
    private struct ScannerCase {
        let line: String
        let expectViolation: Bool
        let reason: String
    }

    private static let scannerCases: [ScannerCase] = [
        ScannerCase(line: "let d = asset.duration",
                    expectViolation: true,
                    reason: "must flag a known-bad line"),
        ScannerCase(line: "let d = try await asset.load(.duration)",
                    expectViolation: false,
                    reason: "must not flag the correct async form"),
        ScannerCase(line: "let d = asset?.duration",
                    expectViolation: true,
                    reason: "optional-chained access (EmbeddedChapterExtractor.makeAsset(for:) returns AVURLAsset?) must still be caught"),
        ScannerCase(line: "let d = asset!.duration",
                    expectViolation: true,
                    reason: "Important 1 (review): force-unwrapped access is the same plausibility class as ?. and the same root cause — makeAsset(for:) returning AVURLAsset? — and must still be caught"),
        ScannerCase(line: "let d = makeAsset(for: episode)?.duration",
                    expectViolation: true,
                    reason: "Important 2a (review): chained directly off an optional-returning factory call, never binding to a value named asset/Asset at all, must still be caught"),
        ScannerCase(line: "let d = AVURLAsset(url: someURL).duration",
                    expectViolation: true,
                    reason: "Important 2b (review): chained directly off a type initializer call — AudioManager.swift:710-711 constructs AVURLAsset inline exactly like this — must still be caught"),
        ScannerCase(line: #"XCTAssertEqual(asset?.url, local, "downloaded episodes must parse from disk, not the network")"#,
                    expectViolation: false,
                    reason: "asset.url is a stored property (no XPC) — real line, EmbeddedChapterExtractorTests.swift:53"),
        ScannerCase(line: #"XCTAssertEqual(asset?.url.absoluteString, "https://e.g/ep.mp3")"#,
                    expectViolation: false,
                    reason: "same — EmbeddedChapterExtractorTests.swift:61"),
        ScannerCase(line: "processDownload(asset.duration)",
                    expectViolation: true,
                    reason: "a real violation must not be exempted just because the line also contains \"download(\" (a bare \"load(\" substring)"),
        ScannerCase(line: "let ok = 1 // not asset.duration, just a comment",
                    expectViolation: false,
                    reason: "a banned name mentioned only in a trailing line comment must not be flagged"),
        ScannerCase(line: "let g = asset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: keys)",
                    expectViolation: true,
                    reason: "Important 3a (review): the synchronous sibling of loadChapterMetadataGroups(...), the API EmbeddedChapterExtractor+Builders.swift actually calls, is the single most likely accessor a future edit swaps to"),
        ScannerCase(line: "let items = asset.metadata(forFormat: .id3Metadata)",
                    expectViolation: true,
                    reason: "Important 3b (review): named explicitly for readability even though already subsumed by the .metadata entry — every line matching \"asset.metadata(forFormat\" already contains \"asset.metadata\""),
        ScannerCase(line: "let d = (try? await asset.load(.duration)) ?? asset.duration",
                    expectViolation: true,
                    reason: "Important 4 (review): a graceful-fallback shape (this repo's \"log and continue\" convention) — a genuine sync access sharing a line with a correct async load must still be caught, not waved through by a line-wide load( exemption"),
    ]

    func test_scannerCases() {
        for scannerCase in Self.scannerCases {
            XCTAssertEqual(Self.isViolation(scannerCase.line), scannerCase.expectViolation,
                           "\(scannerCase.reason)\nline: \(scannerCase.line)")
        }
    }

    /// Important 5 (review): the file-level pre-filter required the file's
    /// text to literally name `AVAsset`/`AVURLAsset`, but type inference can
    /// hide that entirely — `guard let asset =
    /// EmbeddedChapterExtractor.makeAsset(for: episode) else { return }`
    /// never spells the type — while `import AVFoundation` is still
    /// mandatory. Without this, a file shaped exactly like that could carry
    /// a real `asset.duration` violation and never be scanned at all.
    func test_scannerConsidersFilesThatOnlyImportAVFoundation() {
        let source = """
        import AVFoundation
        func f(episode: QueueItem) {
            guard let asset = EmbeddedChapterExtractor.makeAsset(for: episode) else { return }
            let d = asset.duration
        }
        """
        XCTAssertTrue(Self.isScannable(source),
                      "a file that only imports AVFoundation, without literally naming AVAsset/AVURLAsset, must still be scanned")
    }

    func test_scannerIgnoresAccessorMentionedInsideBlockComment() {
        let source = """
        /* avoid asset.duration — use asset.load(.duration) instead */
        let ok = 1
        """
        XCTAssertEqual(Self.violations(in: source), [])
    }

    func test_scannerIgnoresAccessorAfterTrailingLineComment() {
        XCTAssertFalse(Self.isViolation("let ok = 1 // not asset.duration, just a comment"))
    }

    func test_scannerLineNumbersSurviveBlockCommentStripping() {
        let source = """
        let a = 1
        /*
        multi
        line
        comment
        */
        let d = asset.duration
        """
        let found = Self.violations(in: source)
        XCTAssertEqual(found.map(\.line), [7], "violation must be reported on its real line number, not shifted by the stripped comment")
    }
}

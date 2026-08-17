import XCTest

/// Guards `.accessibilityLabel`, `.accessibilityAction(named:)`,
/// `.accessibilityValue` and `.accessibilityHint` against non-literal
/// `String` arguments in allowlisted files.
///
/// All four mark their `StringProtocol` overload `@_disfavoredOverload`, so a
/// literal — or an interpolated literal, or an all-literal ternary — binds
/// `LocalizedStringKey` and lands in the catalog. A computed property, a
/// helper call, a `{…}()` closure, or a ternary mixing a literal with a
/// `String` variable silently binds `String` instead: it compiles, it renders,
/// VoiceOver reads it, and it is never translated in any language.
///
/// A helper that itself returns `String(localized:)` is fine — the string is
/// extracted at the helper. `approvedProducers` lists those, scoped per
/// repo-relative path so a generic name like `accessibilityLabel` cannot wave
/// through an unrelated variable in another view.
///
/// Adding a name to `approvedProducers` is a promise that its body goes
/// through `String(localized:)`. That promise is the guard's whole weak point,
/// so keep the list short and read the body before adding to it.
final class LocalizationAccessibilityGuardTests: XCTestCase {

    /// Expressions known to return an already-localized `String`.
    ///
    /// `"*"` applies everywhere; every other key is a **repo-relative path**,
    /// not a file name. `YourPodsWatch/PlayerView.swift` and
    /// `YourPods/YourPods/Views/PlayerView.swift` are different files with
    /// the same name, and scoping by name would let an approval granted to
    /// one silently cover the other.
    private static let approvedProducers: [String: [String]] = [
        "*": [
            "EpisodeAccessibility.",
            "DurationFormatting.",
            "PlayerManager.formatProgress",
            "EpisodeDownloadHelper.accessibilityActionName",
            "String(localized:",
        ],
        "YourPods/YourPods/Views/Components/AddEditNoteSheet.swift": ["Self.colorLabel("],
        "YourPods/YourPods/Views/EpisodeActivityView.swift": ["rowAccessibilityLabel"],
        "YourPods/YourPods/Views/DownloadsView.swift": ["Self.rowAccessibilityLabel("],
        "YourPods/YourPods/Views/HomeView.swift": ["Self.actionCardLabel("],
        "YourPods/YourPods/Views/LibraryView.swift": ["searchResultAccessibilityLabel"],
        "YourPods/YourPods/Views/NotesView.swift": ["message"],
        "YourPods/YourPods/Views/ProPaywallView.swift": ["Self.featureRowLabel(", "Self.subscribeHint("],
        "YourPods/YourPods/Views/ProStatsView.swift": ["dailyTrendAccessibilityLabel"],
        // Extensions on SyncConflict in the same file. Each body is a switch over
        // ConflictSideDisplay whose every arm returns String(localized:) — the sentence
        // has to change shape when the server side is "played" rather than a timestamp,
        // which an interpolated literal cannot express.
        "YourPods/YourPods/Views/SyncConflictSheet.swift": [
            "conflict.positionsAccessibilityLabel",
            "conflict.useDeviceAccessibilityLabel",
            "conflict.useServerAccessibilityLabel",
            "conflict.useServerAccessibilityHint",
        ],
        "YourPodsWatch/PlayerView.swift": ["sleepTimerLabel"],
        "YourPodsWatch/WatchRecentlyUpdatedView.swift": ["accessibilityLabel(for:"],
    ]

    /// Every SwiftUI modifier whose `StringProtocol` overload is
    /// `@_disfavoredOverload`, and which therefore silently stops translating
    /// when handed a non-literal.
    ///
    /// The first two are the obvious ones. `.accessibilityValue` and
    /// `.accessibilityHint` were missing from the original list and are
    /// exactly as dangerous — VoiceOver reads a value and a hint aloud just
    /// as it reads a label. Their absence hid six live violations in files
    /// this guard already scanned, including the two `{ … }()` closures on
    /// the scrubbers that were putting an empty key into the catalog.
    ///
    /// A modifier missing from this list is a hole the guard cannot see.
    /// `test_everyAccessibilityModifierInUse_isClassified` pins it.
    static let markers = [
        ".accessibilityLabel(",
        ".accessibilityAction(named: ",
        ".accessibilityValue(",
        ".accessibilityHint(",
    ]

    private static let excludedFileName = "LocalizationAccessibilityGuardTests.swift"

    /// Roots and their floors, measured when this guard was written. A floor catches the
    /// failure mode where a root stops resolving and the scan reports clean —
    /// the trap this catches: the precedent scanner walks only two of the five
    /// roots, so a copy of it passes while every widget and watch string
    /// stays English.
    private static let roots: [(path: String, floor: Int)] = [
        ("YourPods/YourPods", 150),
        ("YourPodsWidgets", 5),
        ("YourPodsWatch", 10),
        ("YourPodsComplication", 2),
    ]

    /// Not `private`: `violations(in:path:)` is shared between the real
    /// file scan and the scanner self-checks, so both exercise the same
    /// decision logic. A test that re-derives its own copy of "what counts as
    /// a violation" drifts from the real scanner and keeps passing while the
    /// real one rots.
    struct Violation { let line: Int; let text: String }

    /// True when every branch of a ternary is a string literal.
    ///
    /// The binding rule: literals, interpolated literals, and **all-literal
    /// ternaries** bind `LocalizedStringKey` and extract correctly. Only a
    /// branch that is a `String` *variable* drops the whole expression onto
    /// the `@_disfavoredOverload` path. A scanner that flags every ternary
    /// reports a dozen false positives and gets switched off.
    static func isAllLiteralTernary(_ expr: String) -> Bool {
        var branches: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        var seenQuestion = false

        for ch in expr {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "\"" { inString.toggle(); current.append(ch); continue }
            if !inString && ch == "?" {
                // Everything before a '?' is a condition, never a branch.
                // Resetting also discards a nested ternary's condition.
                seenQuestion = true
                current = ""
                continue
            }
            // A ':' before any '?' is a call label — isHidden(guid: x) — not
            // a branch separator.
            if !inString && ch == ":" && seenQuestion {
                branches.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        branches.append(current.trimmingCharacters(in: .whitespaces))

        guard seenQuestion else { return false }
        return branches.allSatisfy { branch in
            var s = branch
            while s.hasPrefix("(") { s.removeFirst() }
            return s.hasPrefix("\"")
        }
    }

    /// The argument text after `marker`, joined across lines until its
    /// parentheses balance.
    ///
    /// SwiftUI modifiers wrap. `.accessibilityLabel(` routinely ends a line
    /// with its ternary on the next three, and a scanner reading one line at
    /// a time sees an empty argument, calls it non-literal, and reports a
    /// false positive on the most carefully formatted code in the file. That
    /// is how a guard gets switched off.
    static func argument(after marker: String, atLine index: Int, in lines: [String]) -> String? {
        guard let r = lines[index].range(of: marker) else { return nil }
        var arg = ""
        var depth = 1          // the marker itself contains the opening paren
        var inString = false
        var escaped = false
        var line = index

        while line < lines.count, line < index + 8 {
            let text = line == index ? String(lines[index][r.upperBound...]) : lines[line]
            for ch in text {
                if escaped { arg.append(ch); escaped = false; continue }
                if ch == "\\" { arg.append(ch); escaped = true; continue }
                if ch == "\"" { inString.toggle(); arg.append(ch); continue }
                if !inString, ch == "(" { depth += 1 }
                if !inString, ch == ")" {
                    depth -= 1
                    if depth == 0 { return arg.trimmingCharacters(in: .whitespaces) }
                }
                arg.append(ch)
            }
            arg.append(" ")    // the newline is a token separator
            line += 1
        }
        return arg.trimmingCharacters(in: .whitespaces)
    }

    /// A finding is an `.accessibilityLabel(` / `.accessibilityAction(named:`
    /// whose argument is neither a literal, an all-literal ternary, nor an
    /// approved localized producer.
    static func violations(in contents: String, path: String = "") -> [Violation] {
        var approved = approvedProducers["*"] ?? []
        approved += approvedProducers[path] ?? []

        var out: [Violation] = []
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
            for marker in Self.markers {
                guard let arg = argument(after: marker, atLine: i, in: lines) else { continue }
                if arg.hasPrefix("\"") { continue }        // literal / interpolated literal
                if arg.hasPrefix("Text(\"") { continue }   // Text literal
                // An immediately-applied closure is never a literal, however
                // its last expression reads. `isAllLiteralTernary` discards
                // everything before each '?', so `{ let x = …; return x ? "A"
                // : "B" }()` looked like a two-literal ternary and was waved
                // through — which is how two live violations sat unreported.
                if arg.hasPrefix("{") { out.append(Violation(line: i + 1, text: trimmed)); continue }
                if isAllLiteralTernary(arg) { continue }   // every branch a literal
                if approved.contains(where: { arg.hasPrefix($0) }) { continue }
                out.append(Violation(line: i + 1, text: trimmed))
            }
        }
        return out
    }

    private func repoRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        root.deleteLastPathComponent()   // …/YourPodsTests
        root.deleteLastPathComponent()   // repo root
        return root
    }

    /// Allowlist: only migrated files are scanned.
    private func allowlist() throws -> [String] {
        let url = repoRoot().appendingPathComponent("Translations/localized-files.txt")
        let text = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
            "Translations/localized-files.txt is missing — every localization guard reads it")
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Invariant: the allowlist covers every file with accessibility copy

    /// The guard scans only allowlisted files, so a file left off the list is
    /// not "clean" — it is unexamined, and reports zero violations either way.
    ///
    /// Measured once: 27 files emitting catalog strings were never on
    /// the list, among them `DownloadsView.swift`, whose VoiceOver label was
    /// assembled in a closure with the English word "Downloaded" hardcoded
    /// into it. The file scan had been passing the whole time.
    func test_everyFileWithAccessibilityCopy_isAllowlisted() throws {
        let allowed = Set(try allowlist())
        var unguarded: [String] = []
        var examined = 0

        for root in Self.roots {
            let url = repoRoot().appendingPathComponent(root.path)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
                examined += 1
                guard Self.markers.contains(where: contents.contains) else { continue }
                let relative = file.path.replacingOccurrences(
                    of: repoRoot().path + "/", with: "")
                if !allowed.contains(relative) { unguarded.append(relative) }
            }
        }

        XCTAssertGreaterThan(examined, 150, "only \(examined) Swift files examined — the walk is broken")
        XCTAssertTrue(unguarded.isEmpty, """
        These files use accessibility modifiers but are not on
        Translations/localized-files.txt, so the guard never opens them:

          \(unguarded.sorted().joined(separator: "\n  "))

        Add them. A guard that does not scan a file is not guarding it.
        """)
    }

    // MARK: - Invariant: no non-literal a11y strings in migrated files

    func test_allowlistedFiles_haveNoNonLiteralAccessibilityStrings() throws {
        let allowed = try allowlist()
        XCTAssertFalse(allowed.isEmpty, "allowlist is empty — the guard would enforce nothing")

        var findings: [String] = []
        var scanned = 0
        for relative in allowed.sorted() where relative.hasSuffix(".swift") {
            let url = repoRoot().appendingPathComponent(relative)
            guard url.lastPathComponent != Self.excludedFileName else { continue }
            let contents = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                "allowlisted file cannot be read: \(relative) — it moved, was renamed, or was deleted")
            scanned += 1
            for v in Self.violations(in: contents, path: relative) {
                findings.append("\(relative):\(v.line): \(v.text)")
            }
        }

        XCTAssertGreaterThan(scanned, 0, "no allowlisted Swift file was scanned")
        XCTAssertTrue(findings.isEmpty, """
        Non-literal accessibility string in an allowlisted file:

          \(findings.joined(separator: "\n  "))

        .accessibilityLabel and .accessibilityAction(named:) mark their
        StringProtocol overload @_disfavoredOverload, so these bind String and
        never reach a String Catalog — VoiceOver reads them in English in every
        language, and nothing on screen looks wrong.

        Fix: use a literal, an interpolated literal, or a named helper whose
        body goes through String(localized:) — then add that helper to
        approvedProducers under this file's name.
        """)
    }

    // MARK: - Trap 1: every root must resolve

    func test_everyScanRoot_resolvesAndIsPopulated() throws {
        for root in Self.roots {
            let url = repoRoot().appendingPathComponent(root.path)
            let found = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .count ?? 0
            XCTAssertGreaterThanOrEqual(found, root.floor,
                "\(root.path) resolved to \(found) Swift files, below its floor of \(root.floor) — the root moved or the walk is broken, and a broken walk reports zero violations")
        }
    }

    // MARK: - Self-check: the scanner can actually fail

    /// A guard whose scanner cannot fire is not evidence.
    func test_scannerCases() {
        let cases: [(String, String, Bool, String)] = [
            (#".accessibilityLabel("Play")"#, "", false,
             "plain literal binds LocalizedStringKey"),
            (#".accessibilityLabel("\(title), loading")"#, "", false,
             "interpolated literal still extracts"),
            (#".accessibilityAction(named: isHidden ? "Unhide" : "Hide") {"#, "", false,
             "all-literal ternary extracts both arms"),
            (#".accessibilityLabel(playerManager.isBuffering ? "Loading" : (playerManager.isPlaying ? "Pause" : "Play"))"#, "", false,
             "NESTED all-literal ternary — every branch is still a literal"),
            (#".accessibilityAction(named: sync.isHidden(guid: item.id) ? "Unhide" : "Hide") {"#, "", false,
             "a ':' inside a call label before the '?' is not a branch separator"),
            (#".accessibilityLabel((a && b) ? "Pause" : "Play \(episode.title)")"#, "", false,
             "an interpolated literal branch still extracts"),
            (#".accessibilityLabel(isLoading ? "\(title), loading" : title)"#, "", true,
             "THE hazard: a ternary mixing a literal with a String variable"),
            ("""
             .accessibilityLabel(
                 state == .waiting
                     ? "Waiting for browser login"
                     : "Sign in with Nextcloud"
             )
             """, "", false,
             "a wrapped all-literal ternary still extracts — reading one line at a time would call this a violation"),
            ("""
             .accessibilityLabel(
                 someComputedLabel
             )
             """, "", true,
             "wrapping does not make a variable a literal"),
            ("""
             .accessibilityAction(named: EpisodeAccessibility.hideActionName(
                 isHidden: sync.isHidden(guid: ep.guid)
             )) {
             """, "", false,
             "an approved producer whose own arguments wrap"),
            (#".accessibilityLabel(rowAccessibilityLabel)"#, "", true,
             "computed property binds String, and is not approved in an unnamed file"),
            (#".accessibilityLabel(rowAccessibilityLabel)"#, "YourPods/YourPods/Views/EpisodeActivityView.swift", false,
             "approved in the file that defines it, whose body now goes through String(localized:)"),
            (#".accessibilityLabel(rowAccessibilityLabel)"#, "YourPods/YourPods/Views/QueueView.swift", true,
             "path-scoping means the approval does not leak to a view that never defined it"),
            (#".accessibilityValue(sleepTimerLabel)"#, "YourPodsWatch/PlayerView.swift", false,
             "approved on the watch player, whose sleepTimerLabel is localized"),
            (#".accessibilityValue(sleepTimerLabel)"#, "YourPods/YourPods/Views/PlayerView.swift", true,
             "SAME FILE NAME, different target: scoping by basename would have let this through"),
            (#".accessibilityHint(someHint)"#, "", true,
             ".accessibilityHint was unguarded until it was added to markers"),
            (#".accessibilityValue({"#, "", true,
             ".accessibilityValue closure \u{2014} the shape that put an empty key in the catalog"),
            (#".accessibilityLabel(message)"#, "", true,
             "bare variable binds String"),
            (#".accessibilityLabel({"#, "", true,
             "closure literal binds String"),
            (#".accessibilityLabel(EpisodeAccessibility.episodeLabel("#, "", false,
             "approved localized producer"),
            (#".accessibilityLabel(DurationFormatting.spoken(90))"#, "", false,
             "approved localized producer"),
            (#".accessibilityLabel(String(localized: "a11y.x", defaultValue: "X"))"#, "", false,
             "an explicit localized call is always fine"),
            (#".accessibilityAction(named: actionName) {"#, "", true,
             "variable action name binds String"),
            (#"// .accessibilityLabel(someVariable) — explained here"#, "", false,
             "comments are exempt"),
            // An immediately-applied closure is never a literal, whatever its
            // last expression looks like. Both shapes below shipped unreported
            // because isAllLiteralTernary discards everything before each '?'
            // and then saw only two quoted branches.
            (#".accessibilityAction(named: { let h = isHidden(x); return h ? "Unhide" : "Hide" }()) {"#, "", true,
             "a closure whose last expression is a literal ternary still returns String"),
            (#".accessibilityLabel({ var s = title; s += ", Downloaded"; return s }())"#, "", true,
             "a closure assembling a String is the original hazard this guard exists for"),
            (#"     * .accessibilityLabel(someVariable) in a doc comment"#, "", false,
             "doc-comment continuation is exempt"),
        ]
        for (source, file, expected, why) in cases {
            let hit = !Self.violations(in: source, path: file).isEmpty
            XCTAssertEqual(hit, expected,
                "scanner disagreed on: \(source)\n  file=\(file.isEmpty ? "(none)" : file)\n  because \(why)")
        }
    }

    /// The scanner must report the right line number, or its failure output
    /// sends a reader to the wrong place.
    func test_violations_reportCorrectLineNumbers() {
        let source = """
        import SwiftUI
        // .accessibilityLabel(ignored) in a comment
        struct V: View {
            var body: some View {
                Text("hi")
                    .accessibilityLabel(someComputedThing)
            }
        }
        """
        let found = Self.violations(in: source)
        XCTAssertEqual(found.count, 1, "expected exactly one violation, got \(found.count)")
        XCTAssertEqual(found.first?.line, 6, "violation reported on the wrong line")
    }

    /// Trap 2: self-exclusion is by filename, matching the precedent's
    /// mechanism. This file embeds violating shapes as fixtures.
    /// A modifier absent from `markers` is a hole the guard cannot see, and
    /// nothing else in the suite would notice: `.accessibilityValue` and
    /// `.accessibilityHint` were missing from the original list and hid six
    /// live violations in files this guard was already scanning.
    ///
    /// So rather than trust the list, enumerate every `.accessibilityX(`
    /// spelling the allowlisted sources actually use and require each one to
    /// be classified — either scanned, or explicitly recorded as taking
    /// something other than a `LocalizedStringKey`. A newly-adopted modifier
    /// fails here until someone decides which it is.
    func test_everyAccessibilityModifierInUse_isClassified() throws {
        /// Modifiers whose argument is not user-facing text.
        let nonLocalizing: Set<String> = [
            ".accessibilityAction(",       // an action kind or a closure; the named: form is scanned
            ".accessibilityActionName(",   // our own helper, not the SwiftUI modifier
            ".accessibilityAddTraits(",    // AccessibilityTraits
            ".accessibilityElement(",      // a children behaviour
            ".accessibilityHidden(",       // Bool
        ]

        let pattern = try NSRegularExpression(pattern: #"\.accessibility[A-Za-z]+\("#)
        var seen: Set<String> = []
        var filesScanned = 0

        for relative in try allowlist() where relative.hasSuffix(".swift") {
            let url = repoRoot().appendingPathComponent(relative)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            filesScanned += 1
            let range = NSRange(contents.startIndex..., in: contents)
            for match in pattern.matches(in: contents, range: range) {
                if let r = Range(match.range, in: contents) { seen.insert(String(contents[r])) }
            }
        }

        XCTAssertGreaterThan(filesScanned, 30, "only \(filesScanned) allowlisted files were scanned")
        XCTAssertTrue(seen.contains(".accessibilityValue("),
                      "the scan found no .accessibilityValue( at all — it is not reading the sources")

        let scanned = Set(Self.markers.map { $0.hasSuffix(" ") ? String($0.dropLast()) : $0 })
            .union([".accessibilityAction(named:"])
        let unclassified = seen.subtracting(nonLocalizing).filter { marker in
            !scanned.contains(where: { marker.hasPrefix($0) || $0.hasPrefix(marker) })
        }

        XCTAssertTrue(unclassified.isEmpty, """
        Accessibility modifier in use but not classified: \(unclassified.sorted())

        Decide which it is and say so:
          - it takes a LocalizedStringKey → add it to `markers` and fix
            whatever the guard then reports;
          - it takes a Bool, a trait, or a closure → add it to
            `nonLocalizing` in this test.

        Leaving it out is the third option, and it is the one that let
        .accessibilityValue and .accessibilityHint ship unguarded.
        """)
    }

    func test_selfExclusionConstant_matchesThisFile() {
        XCTAssertEqual(URL(fileURLWithPath: #filePath).lastPathComponent,
                       Self.excludedFileName,
                       "excludedFileName drifted from this file's real name")
    }
}

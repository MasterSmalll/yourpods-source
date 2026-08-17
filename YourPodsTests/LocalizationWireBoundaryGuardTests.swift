import XCTest
@testable import YourPods

/// Guards the wire/disk boundary against localization.
///
/// These four files use display-derived English literals as durable
/// identifiers: `NextcloudNotesAPIService` matches `title` + `category` by
/// string equality to decide PUT-update vs POST-create against a live server;
/// `NotesExportService` builds Obsidian vault paths written with
/// `overwrite=true`; `NextcloudNotesService` builds WebDAV filenames.
///
/// Localize any of those literals and a German device stops matching the notes
/// a user's English device created — silently duplicating, or overwriting, the
/// user's entire note corpus. There is no error, no log, and no crash.
///
/// A source scan is the only enforcement that runs: the failure needs a real
/// Nextcloud server and a non-English device to reproduce, so no unit or
/// simulator test will ever catch it. Same rationale as
/// `AVAssetSyncAccessGuardTests` and `WidgetInteractivityGuardTests`.
final class LocalizationWireBoundaryGuardTests: XCTestCase {

    // MARK: - Scanner
    //
    // Extracted into statics so the real file scan and the scanner
    // self-checks exercise the same decision logic — a test that re-derives
    // its own copy of "what counts as a violation" drifts from the real
    // scanner and keeps passing while the real one rots.

    /// Localization APIs. Any of these in a wire-critical file means a
    /// durable identifier is about to become locale-dependent.
    private static let bannedTokens = [
        "String(localized:",
        "NSLocalizedString",
        "LocalizedStringResource",
        "LocalizedStringKey",
        "String.LocalizationValue",
    ]

    /// Files whose string literals cross to disk, wire, or a remote identity
    /// key. Paths are relative to `YourPods/YourPods`.
    private static let wireCriticalFiles = [
        "Services/NextcloudNotesAPIService.swift",
        "Services/NextcloudNotesService.swift",
        "Services/NotesExportService.swift",
        "Services/WatchWireFormat.swift",
    ]

    /// This file's own name — excluded from the scan. It necessarily embeds
    /// the banned tokens as string-literal fixtures for the self-checks
    /// below, and a line scanner cannot tell "this text is a fixture" from
    /// "this text is a real violation."
    private static let excludedFileName = "LocalizationWireBoundaryGuardTests.swift"

    private struct Violation { let line: Int; let text: String }

    /// Violations in `contents`, ignoring comment lines — a `//` mention of
    /// `String(localized:)` explaining *why it must not be used here* is
    /// exactly what these files should contain.
    private static func violations(in contents: String) -> [Violation] {
        var out: [Violation] = []
        for (i, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
            for token in bannedTokens where line.contains(token) {
                out.append(Violation(line: i + 1, text: trimmed))
            }
        }
        return out
    }

    private func appRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)   // …/YourPodsTests/ThisFile.swift
        root.deleteLastPathComponent()               // …/YourPodsTests
        root.deleteLastPathComponent()               // repo root
        return root.appendingPathComponent("YourPods/YourPods")
    }

    // MARK: - Invariant: no localization in wire-critical files

    func test_wireCriticalFiles_containNoLocalizationAPIs() throws {
        var violations: [String] = []
        var scanned = 0

        for relative in Self.wireCriticalFiles {
            let url = appRoot().appendingPathComponent(relative)
            let contents = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                "could not read \(relative) — the file moved or was renamed; update wireCriticalFiles")
            XCTAssertGreaterThan(contents.count, 200,
                "\(relative) is implausibly small (\(contents.count) bytes) — wrong path?")
            scanned += 1
            for v in Self.violations(in: contents) {
                violations.append("\(relative):\(v.line): \(v.text)")
            }
        }

        XCTAssertEqual(scanned, Self.wireCriticalFiles.count,
            "not every wire-critical file was scanned")

        XCTAssertTrue(violations.isEmpty, """
        Localization API used in a wire-critical file:

          \(violations.joined(separator: "\n  "))

        These files build durable identifiers — remote note titles and
        categories matched by string equality, Obsidian vault paths written
        with overwrite=true, WebDAV filenames. A localized literal means a
        non-English device stops matching what an English device wrote, and
        silently duplicates or overwrites the user's notes.

        Use WireString for the fallback, or prefer a stable identifier such as
        episodeUrl. If a string here is genuinely user-facing, it belongs in a
        different file.
        """)
    }

    // MARK: - Invariant: WireString constants are stable

    /// These exact values are the on-disk and on-server identity of existing
    /// user data. Changing one orphans every note or file already written
    /// under the old value. This test is a tripwire, not a style check —
    /// if it fails, a data migration is required, not a test update.
    func test_wireStringConstants_haveNotChanged() {
        XCTAssertEqual(WireString.untitledEpisode, "Untitled")
        XCTAssertEqual(WireString.unknownPodcast, "Unknown Podcast")
        XCTAssertEqual(WireString.unknownEpisode, "Unknown Episode")
        XCTAssertEqual(WireString.unknownTitle, "Unknown")
        XCTAssertEqual(WireString.notesCategoryRoot, "YourPods")
        XCTAssertEqual(WireString.obsidianVaultRoot, "YourPods Notes")
    }

    // MARK: - Self-check: the scanner can actually fail

    private struct ScannerCase {
        let source: String
        let isViolation: Bool
        let why: String
    }

    /// A guard whose scanner cannot fire is not evidence. Each row proves the
    /// scanner's decision on a shape it will really meet.
    func test_scannerCases() {
        let cases: [ScannerCase] = [
            .init(source: #"let t = String(localized: "notes.untitled")"#,
                  isViolation: true, why: "String(localized:) is the primary risk"),
            .init(source: #"let t = NSLocalizedString("notes.untitled", comment: "")"#,
                  isViolation: true, why: "legacy API, same effect"),
            .init(source: #"let r: LocalizedStringResource = "Untitled""#,
                  isViolation: true, why: "resource type is equally locale-dependent"),
            .init(source: #"var k: LocalizedStringKey = "Untitled""#,
                  isViolation: true, why: "SwiftUI key type"),
            .init(source: #"let v = String.LocalizationValue("Untitled")"#,
                  isViolation: true, why: "underlying value type"),
            .init(source: #"    let t = first.episodeTitle ?? WireString.untitledEpisode"#,
                  isViolation: false, why: "the correct pattern this guard protects"),
            .init(source: #"let f = first.episodeTitle ?? first.episodeUrl"#,
                  isViolation: false, why: "stable-identifier fallback, already used at NextcloudNotesService:69"),
            .init(source: #"// never use String(localized:) here — see the type doc"#,
                  isViolation: false, why: "comment lines are exempt; explaining the ban is desirable"),
            .init(source: #"    // NSLocalizedString would break note identity"#,
                  isViolation: false, why: "indented comment is still a comment"),
            .init(source: #"     * LocalizedStringResource must not appear below"#,
                  isViolation: false, why: "doc-comment continuation line"),
            .init(source: #"let title = "Untitled""#,
                  isViolation: false, why: "a bare literal is not itself a violation — WireString is the fix, not the rule"),
        ]

        for c in cases {
            let hit = !Self.violations(in: c.source).isEmpty
            XCTAssertEqual(hit, c.isViolation,
                "scanner disagreed on: \(c.source)\n  expected violation=\(c.isViolation) because \(c.why)")
        }
    }

    /// The scanner must report the right line number in a multi-line file,
    /// or its failure output sends a reader to the wrong place.
    func test_violations_reportCorrectLineNumbers() {
        let source = """
        import Foundation
        // String(localized:) is banned here
        struct S {
            let a = "fine"
            let b = String(localized: "bad.key")
        }
        """
        let found = Self.violations(in: source)
        XCTAssertEqual(found.count, 1, "expected exactly one violation, got \(found.count)")
        XCTAssertEqual(found.first?.line, 5, "violation reported on the wrong line")
    }

    /// The exclusion is by filename, matching the precedent's mechanism.
    /// If this file were ever scanned, its own fixtures would flag it.
    func test_selfExclusionConstant_matchesThisFile() {
        XCTAssertEqual(URL(fileURLWithPath: #filePath).lastPathComponent,
                       Self.excludedFileName,
                       "excludedFileName drifted from this file's real name")
    }
}
